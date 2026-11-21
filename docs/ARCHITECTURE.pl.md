# Architektura Ripplo

[🇬🇧 English](ARCHITECTURE.md) | 🇵🇱 Polski

Ripplo to komunikator mesh typu offline-first, z szyfrowaniem end-to-end.
Interfejs Vue 3 (JS) działa w WebView Capacitor 8. Kryptografia Signal (oficjalna `libsignal`), transporty i router
przekaźnikowy są natywne (Java / Swift), więc klucze prywatne nigdy nie trafiają do WebView, a telefony przekazują
wiadomości także przy wyłączonym ekranie.

```
┌──────────────── WebView (JS) ────────────────┐      ┌──────── native (Java / Swift) ──────────┐
│ Vue UI ── core/api.js ── core/messenger.js   │      │ SignalCore (libsignal 0.108.5: PQXDH +   │
│   (cards, chats, attachments, at-rest DB)    │ base64│   SPQR triple ratchet, sealed, proofs)  │
│            mesh/bridge.js ───────────────────┼──────►│ MeshEngine: Router + Links + Transports │
│  web dev fallback: devSignal.js (NO crypto)  │◄──────┤  BLE GATT, L2CAP, LAN, Wi-Fi Direct*,   │
│   + mesh/router.js over BroadcastChannel     │events │  Wi-Fi Aware*, Multipeer**              │
└──────────────────────────────────────────────┘      └──────────────────────────────────────────┘
                                                        * Android only   ** iOS only
```

Przekaźniki nigdy nie widzą treści, nigdy nie odszyfrowują i nigdy nie powiadamiają swojego użytkownika.

## 1. Tożsamość

- Para kluczy tożsamości Signal z `IdentityKeyPair.generate()` (Curve25519; klucz publiczny 33 bajty, prefiks `0x05`).
- `tag` = `SHA-256(identityPub33)[0..16]` — 16-bajtowy adres routingu używany w polu `dest` pakietu.
- `ripploId` = Crockford base32 z `tag[0..10]` → 16 znaków, wyświetlane jako `XXXX-XXXX-XXXX-XXXX`.
- Adres Signal = `SignalProtocolAddress(hex(tag), 1)` (małe litery hex, jedno urządzenie na tożsamość).
- `IdentityKeyStore.isTrustedIdentity` / `saveIdentity` odrzucają każdą tożsamość, której `SHA-256(ik)[0..16]`
  różni się od tagu adresu. Poza tym trust-on-first-use; zmiana klucza dla znanego tagu jest niemożliwa
  z konstrukcji (tag jest skrótem klucza).
- Tworzone raz przy pierwszym uruchomieniu: registration id (14-bitowy losowy), signed prekey o id 1 (EC),
  ostatniej szansy (last-resort) prekey Kyber-1024 o id 1 (`KEMKeyPair.generate(KYBER_1024)`, podpis =
  `identityPriv.calculateSignature(kyberPub.serialize())`). Brak jednorazowych prekeyów: nie ma serwera,
  który by je wydawał. `markKyberPreKeyUsed` nic nie robi (klucz last-resort jest wielokrotnego użytku, jak w Signal).

### Pakiet kluczy (bundle; natywny, binarny, big-endian) — 1776 bajtów

| size | field |
|------|-------|
| 1    | version `0x02` |
| 4    | registrationId u32 |
| 33   | identity public key |
| 4    | signedPreKeyId u32 |
| 33   | signedPreKey public |
| 64   | signedPreKey signature |
| 4    | kyberPreKeyId u32 |
| 1569 | kyber public key (`KEMPublicKey.serialize()`, type byte `0x08` + 1568) |
| 64   | kyber signature |

### Wizytówka kontaktu (JS) i link zaproszenia / QR

`card = 0x02 | nameLen u8 | name UTF-8 (≤ 120 bytes, ≤ 40 chars) | bundle(1776)`

`ripplo://add/<base64url(card)>.<base64url(SHA-256(card)[0..6])>` — około 2,4 KB. Pojedynczy QR dla niego miałby wersję 40
(177 × 177 modułów), której żaden aparat telefonu nie czyta niezawodnie, więc QR to animowana sekwencja klatek (korekcja błędów **L**):
link jest cięty na kawałki po 420 znaków, każdy pokazywany jako `ripplo://p/<zestaw>.<i>.<n>.<kawałek>` (`zestaw` = base64url z
SHA-256(link)[0..6]; około 6 klatek, QR wersja 13, 69 × 69 modułów), a klatki powtarzają się co 700 ms. Skaner zbiera kawałki
w dowolnej kolejności (do 20 na zestaw, 4 zestawy naraz, powtórzenia ignorowane), skleja je, gdy są wszystkie, sprawdza id zestawu względem
SHA-256 wyniku i dopiero wtedy obsługuje link tak, jakby został wklejony. Niezgodny zestaw jest odrzucany z błędem sumy kontrolnej.
QR weryfikacji (60 cyfr) zostaje pojedynczym, małym kodem.

Przyrostek to suma kontrolna integralności (wychwytuje obcięcie / uszkodzenie). NIE jest to uwierzytelnienie —
każdy może ją przeliczyć. Autentyczność zapewnia weryfikacja (sekcja 5). Żaden serwer nigdy nie widzi
linku.

### Zaproszenia jednorazowe

Za każdym razem, gdy pokazuje się zakładka „Mój kod” (i przy każdym wywołaniu `myInviteLink()`), powstaje nowy losowy 8-bajtowy token, a link
ma postać `ripplo://add/<karta>.<suma>.<token>` (token = 11 znaków base64url; link bez tokenu nadal się parsuje). Wystawca trzyma do 30
niewykorzystanych tokenów (`kv/tokens`, najstarszy odpada). Osoba, która skanuje link, zapamiętuje token na nowym kontakcie, a pierwsze
wiadomości do wystawcy niosą go jako `tk` obok karty, dopóki wystawca raz nie odpowie. Wystawca realizuje token raz: nadawca jest wtedy
zaufany jako ktoś, komu wystawca dał link (`addedVia: "link"`, więc połączenia i multimedia są przyjmowane, §6.1). Token nieznany lub już użyty
przez kogoś innego nic nie daje, a taki nadawca zostaje obcym, który napisał pierwszy. Powtórzenie tego samego tokenu przez tego samego
nadawcę jest nieszkodliwe. Link to więc klucz jednorazowy, a nie lista dostępu: przekazanie go dalej nie daje drugiej osobie zaufania, tylko
pierwszej, która go użyła.

## 2. Warstwy szyfrowania

1. **Protokół Signal — oficjalna `libsignal` 0.108.5** (AGPL-3.0, autorstwa Signal). PQXDH (X25519 +
   Kyber-1024 / ML-KEM) do nawiązywania sesji oraz potrójny ratchet SPQR (Double Ratchet + rzadki ratchet
   postkwantowy), zawsze włączone. Każda wiadomość aplikacji (tekst, wskaźnik załącznika, aktualizacja grupy)
   to obiekt JSON szyfrowany przez `SessionCipher` dla odbiorcy. Grupy = fan-out po stronie klienta
   (szyfrowanie parami dla każdego członka). Wiadomości głosowe, zdjęcia i filmy są załącznikami.
2. **Sealed sender** (ukrywa nadawcę przed przekaźnikami), realizowany natywnie:
   `sealed = 0x01 | ephPub(32) | nonce(12) | AES-256-GCM(key, inner)`
   `key = HKDF-SHA256(ikm = X25519(ephPriv, recipientIdentityPub32), salt = recipientTag, info = "ripplo-sealed-v2", 32)`
   `inner = 0x02 | senderTag(16) | msgType u8 (2 = SignalMessage, 3 = PreKeySignalMessage) | body`
   `ephPub` = 32 bajty klucza bez prefiksu `0x05` (X25519 przez `ECPrivateKey.calculateAgreement` z libsignal).
   Odbiorca odszyfrowuje swoim kluczem prywatnym tożsamości, a następnie uruchamia deszyfrowanie Signal dla
   adresu `hex(senderTag)`. Wiadomość PreKey, której klucz tożsamości nie daje skrótu równego `senderTag`,
   jest odrzucana przed deszyfrowaniem.
3. **Załączniki** (w stylu Signal, w JS): plik jest szyfrowany raz losowym kluczem AES-256-GCM
   (`ct = nonce(12) | GCM(file)`). `ct` jest dzielony na fragmenty po 32 KiB wysyłane jako osobne pakiety DATA.
   Klucz, `SHA-256(ct)`, typ mime, rozmiar i liczba fragmentów podróżują w wiadomości-wskaźniku zaszyfrowanej
   protokołem Signal, wysyłanej **po** potwierdzeniu (ACK) każdego fragmentu. Odbiorca weryfikuje skrót przed odszyfrowaniem.
4. **Dane w spoczynku**: stan Signal (tożsamość, prekeye, sesje, tożsamości) jest przechowywany natywnie jako pliki,
   każdy zaszyfrowany AES-256-GCM kluczem trzymanym w Android Keystore / iOS Keychain
   (`AfterFirstUnlockThisDeviceOnly`). IndexedDB w JS (wiadomości, kontakty, czaty) jest szyfrowane AES-GCM
   kluczem bazy danych z `RipploMesh.getDbKey()`.
5. **Wersja webowa do developmentu**: `src/mesh/devSignal.js` zastępuje natywne wywołania Signal jawnym
   zamiennikiem, aby dwie karty przeglądarki mogły ćwiczyć interfejs. NIE zapewnia żadnego bezpieczeństwa,
   a interfejs to komunikuje.

Numer bezpieczeństwa (safety number): `NumericFingerprintGenerator(5200).createFor(1, myTag, myIk, theirTag, theirIk)`,
wyświetlane 60 cyfr (identyczne po obu stronach, na obu platformach).

Klucz dowodu bliskości: `K = HKDF-SHA256(X25519(myIdentityPriv, otherIk32), salt = n, info = "ripplo-proof-v1", 32)`,
`mac = HMAC-SHA256(K, "ripplo-proof-v1" | n | challengerTag | proverTag)` (natywnie, zob. §5).

Limity: tekst ≤ 1000 znaków, załącznik ≤ 20 MiB (przed szyfrowaniem).

## 3. Pakiet mesh (binarny, big-endian)

| off | size | field |
|-----|------|-------|
| 0   | 1    | version = `1` |
| 1   | 1    | type |
| 2   | 1    | ttl  (reserved, ignored; send 8) |
| 3   | 1    | hops (hops taken so far) |
| 4   | 16   | id   (random per packet) |
| 20  | 16   | dest |
| 36  | n    | payload |

Maksymalny pakiet to 65 536 bajtów. Typy:

| type | name        | dest                        | routing |
|------|-------------|-----------------------------|---------|
| 1    | LINK_HELLO  | zeros                       | link-local; payload = nodeTag(16) |
| 2    | PING        | zeros                       | link-local; payload = nonce(8) sendMs(8) filler |
| 3    | PONG        | zeros                       | link-local; payload = first 16 bytes of PING payload |
| 10   | DATA        | recipient tag               | forward (route or flood) |
| 11   | ACK         | id of the DATA being acked  | backward (reverse path) |
| 12   | DEAD_END    | id of the DATA/DISCOVER     | backward, aggregated |
| 13   | DISCOVER    | zeros (broadcast)           | flood |
| 14   | REPLY       | id of the DISCOVER          | backward (reverse path) |
| 20   | APP         | zeros                       | link-local, handed to JS |

Pierwszy bajt payloadu DATA: `0x01` wiadomość sealed, `0x02` fragment załącznika
(`0x02 | attId(16) | index u32 | total u32 | bytes`).

Brak limitu przeskoków. Wartości domyślne: wpisy seen/reverse/route wygasają po 10 min, limit pamięci podręcznej seen to 20 000.

### 3.1 Router (identyczny w `src/mesh/router.js`, Kotlin i Swift)

Stan: zbiór `seen` par `(type,id)`, `reverse[id] = {prev, dest, pending, done}`,
`routes[destTag] = neighbor`, tag `self`. `prev = SELF` dla pakietów, które pochodzą z lokalnego JS.

```
onPacket(p, from):                       # from = neighbor nodeTag, or SELF for JS-originated
  APP                -> deliver to JS (from)
  DATA | DISCOVER:
    if seen(p): if from != SELF: send DEAD_END(dest=p.id) to from;  return
    mark seen; reverse[p.id] = {prev: from, dest: p.dest, pending: 0, done: false}
    if DATA and p.dest == self: persist to inbox; send ACK(dest=p.id, hops=0) to from; deliver; return
    if DISCOVER and from != SELF: deliver to JS          # JS may answer with REPLY
    q = copy(p); if from != SELF: q.hops = min(p.hops+1, 255)
    targets = DATA and routes[p.dest] alive and != from ? [routes[p.dest]] : neighbors - from
    if targets empty: deadEnd(p.id); return
    reverse[p.id].pending = len(targets); send q to each
  ACK | REPLY:
    if seen(p): return; mark seen
    r = reverse[p.dest]; if !r: return
    if ACK: routes[r.dest] = from (unless from == SELF); r.done = true
    q = copy(p) with hops+1          # hops = links traversed; a direct neighbor gives 1
    if r.prev == SELF: deliver q to JS  else: send q to r.prev
  DEAD_END:
    if seen(p): return; mark seen
    r = reverse[p.dest]; if !r or r.done: return
    r.pending -= 1; if r.pending <= 0: deadEnd(p.dest)

deadEnd(id):  r = reverse[id]; r.done = true
              if r.prev == SELF: deliver DEAD_END(dest=id) to JS   # JS deliveries for own traffic use from = 'self'
              else send DEAD_END(new id, dest=id) to r.prev
```

Dlaczego wiadomości nie mogą krążyć w pętli: każdy węzeł przekazuje dany `id` najwyżej raz (zbiór seen), więc pakiet nigdy nie przejdzie dwa razy przez ten sam telefon, a duplikaty dostają w odpowiedzi DEAD_END zamiast być przekazywane dalej.
Gdy wszystkie gałęzie wygasną, DEAD_END-y agregują się z powrotem do nadawcy, który pokazuje *„Kontakt jest poza zasięgiem sieci mesh”*.
Nie ma limitu przeskoków, więc wiadomość przejdzie przez dowolnie długi łańcuch telefonów. JS rezygnuje też po 5 min bez ACK/DEAD_END (łącza mogą zniknąć w trakcie przesyłu).

ACK wracający trasą uczy każdy przekaźnik `routes[dest] = neighbor`, więc kolejne pakiety (np. fragmenty
multimediów) idą unicastem wyuczoną ścieżką zamiast być zalewane (flood).

Przekaźniki nigdy nie przekazują przekazywanych pakietów DATA do JS i nigdy nie powiadamiają użytkownika (wymaganie: żadnego spamu
„wiadomość przeszła przez twój telefon”).

Limity nadużyć (native): maks. 200 pakietów/s na sąsiada, maks. 32 MiB w kolejce na łącze, odrzucanie nadmiaru.

## 4. Łącza i wybór prędkości

Każdy transport dostarcza strumień bajtów; ramki mają postać `u32 length | packet`. Pierwszą ramką na nowym
łączu jest LINK_HELLO z losowym, per proces `nodeTag`. Łącza są grupowane według `nodeTag`, więc jeden
sąsiad może mieć kilka łączy (np. BLE + LAN). Po nawiązaniu łącza i co 60 s silnik wysyła
PING z wypełnieniem (16 KiB dla mediów Wi-Fi/L2CAP, 2 KiB dla BLE GATT) i mierzy
`kbps = bits / rttMs`. Router zawsze wysyła przez najszybsze działające łącze sąsiada i w razie awarii
przełącza się na następne. Przed pierwszym pomiarem nominalne kbps: lan 20000,
wifi-aware 20000, wifi-direct 20000, multipeer 10000, l2cap 300, ble 50.

Łącze jest zamykane dopiero, gdy dwa razy z rzędu okazało się ciche: nasz PING jest bez odpowiedzi dłużej niż 90 s i przez ponad 90 s nie dotarł żaden bajt, w dwóch
kolejnych kontrolach co 60 s (pierwsze uderzenie zostawia ping jako niepotwierdzony zamiast wysyłać nowy). Liczy się każdy odebrany bajt, więc długi transfer go nie
wyzwoli, a telefon, który tylko przysnął (bez niepotwierdzonego pinga), nie jest odcinany. Bez tego łącze, którego druga strona zniknęła bez zamknięcia gniazda, zostawało na liście
sąsiadów, router dalej wysyłał jednoadresowo trasą nauczoną z wcześniejszego ACK, a wiadomości kończyły jako „poza zasięgiem” przy telefonach obok siebie.
Zamknięcie czyści trasy przez nie, więc następny DATA znów zalewa sieć.

Zduplikowane łącza tego samego medium do tego samego węzła: zostaw to zainicjowane przez niższy nodeTag.

| medium       | Android | iOS | interop | discovery |
|--------------|---------|-----|---------|-----------|
| `ble`        | ✓ | ✓ | ✓ | GATT service `6f2a0001-5c3e-4b7a-9d1e-2b9c6e1a0f01`; RX char `…0002` (write), TX char `…0003` (notify), PSM char `…0004` (read, u16) |
| `l2cap`      | ✓ (10+) | ✓ | ✓ | BLE L2CAP CoC, PSM read from `…0004` after GATT connect |
| `lan`        | ✓ | ✓ | ✓ | DNS-SD `_ripplo._tcp` on the current Wi-Fi/hotspot, TCP |
| `wifi-direct`| ✓ | – | – | Wi-Fi P2P DNS-SD `_ripplo._tcp`, group owner listens on TCP 47321 |
| `wifi-aware` | ✓ (8+, if hardware) | – | – | NAN service `ripplo`, TCP 47322 over the NAN data path |
| `multipeer`  | – | ✓ | – | MultipeerConnectivity service type `ripplo-mesh` |

BLE GATT to strumień bajtów w każdym kierunku: central zapisuje fragmenty o rozmiarze `mtu-3` do RX (zapis z
odpowiedzią, uporządkowany); peripheral wysyła fragmenty powiadomieniami na TX. Żądaj MTU 517.

Klasyczny Bluetooth RFCOMM nie jest używany: aplikacje iOS nie mogą z niego korzystać bez MFi; L2CAP CoC to
wieloplatformowa szybka ścieżka Bluetooth. Wi-Fi Aware na iOS 26 wymaga uprawnienia (entitlement) dla płatnego konta deweloperskiego;
dodaj je, gdy projekt będzie je miał.

## 5. Kontakty i weryfikacja kluczy

`verification`: `none` | `nearby` (udowodniona przez bezpośrednie łącze) | `qr` (porównanie QR osobiście) |
`manual` (użytkownik poręczył, np. porównał numer bezpieczeństwa w innym komunikatorze).

Dowód bliskości (pakiety APP link-local, nigdy nieprzekazywane):
```
A → B  { "t": "challenge", "n": <b64 32 random>, "from": A.ripploId }
B → A  { "t": "proof", "n": ..., "mac": HMAC-SHA256(K, "ripplo-proof-v1" | n | A.tag | B.tag) }
K = HKDF-SHA256(X25519(B.priv, A.pub), salt = n, info = "ripplo-proof-v1", 32)
```
Tylko posiadacz klucza prywatnego B (lub A) może obliczyć K, więc podmieniony klucz nie przejdzie.

Przebieg po dodaniu kontaktu przez link, zakładkę Ludzie lub QR:
1. Szukaj bezpośredniego sąsiada, którego wizytówka w pakiecie APP hello ma `ripploId` kontaktu; przeprowadź challenge.
   Próbuj przez 60 s.
2. Sukces → `nearby` (albo `qr`, jeśli kontakt dodano przez skanowanie).
3. Porażka → ostrzeżenie: *„Nie udało się zweryfikować tego klucza publicznego. Nie masz pewności, że osoba po drugiej
   stronie to ta, którą dodałeś/aś.”* z trzema akcjami: **Zweryfikuj kodem QR** (zeskanuj osobiście jej QR
   bezpieczeństwa), **Ponów przez sieć**, **Jestem pewien, że to ta osoba** (→ `manual`, okno potwierdzenia).
4. Sąsiad lub wpis w Ludziach ogłaszający tę samą nazwę wyświetlaną z innym kluczem wywołuje czerwone
   ostrzeżenie *możliwa podmiana klucza*.

Ograniczenie (opisane w aplikacji): dowód bliskości pokazuje, że właściciel klucza jest fizycznie w zasięgu,
a nie kim jest. Atakujący, który podmienił link i stoi w pobliżu, go przejdzie; porównanie QR / numeru bezpieczeństwa
z prawdziwą osobą to mocna weryfikacja.

Numer bezpieczeństwa (safety number): w stylu Signal, 60 cyfr z obu kluczy tożsamości (SHA-512 iterowany 5200×,
`fingerprint version 0 | key | ripploId`), wyświetlany w 12 grupach po 5 oraz jako QR.

### Zmiana nazwy wyświetlanej

Ustawienia → Profil → Zmień nazwę. Karta (a więc link zaproszenia, QR, `hello` i `REPLY`) jest budowana od nowa
z nową nazwą, a `hello` wysyłane ponownie do obecnych sąsiadów. Kontakty poznają nazwę tylko z uwierzytelnionej,
zaszyfrowanej Signalem wiadomości: pole `nm` jest dołączane do wiadomości, gdy `contact.nameSent != mojaNazwa`,
a `{ "t": "profile" }` (sam nośnik) idzie od razu do każdego kontaktu; nieudane wysłanie zeruje `nameSent`.
Odbiorca stosuje `nm` po `cleanName` (≤ 40 znaków) i ponownie sprawdza konflikt tej samej nazwy. Nazwy w kartach
NIE są podpisane, więc nazwa z karty, `hello` lub `REPLY` nigdy nie nadpisuje nazwy istniejącego kontaktu.
`ripploId` i klucze się nie zmieniają.

### Pamięć weryfikacji, stałe próby i podpowiedzi

- Każdy zweryfikowany klucz (nearby, qr, manual) jest pamiętany po `ripploId` i kluczu w `kv/verified`, także po usunięciu kontaktu. Ponowne
  dodanie tego samego klucza od razu przywraca weryfikację; inny klucz pod tym samym id nie.
- Dowód bliskości jest próbowany dla każdego nowego kontaktu (także tego, który napisał pierwszy) i ponownie, gdy pojawia się sąsiad,
  którego karta pasuje do niezweryfikowanego kontaktu (najwyżej co 30 s), o ile kontakt nie jest oczekującą prośbą.
- Gdy kogoś zweryfikujesz, dostaje `vf` (nearby / qr / manual) w następnej wiadomości oraz od razu `{ "t": "profile" }`. Odbiorca zapisuje to
  jako `peerVerified` i pokazuje „X już zweryfikował(a) twój klucz” tylko jako podpowiedź: twierdzenie od klucza, który jest sprawdzany, nic
  nie dowodzi, więc nigdy nie zmienia własnego stanu weryfikacji odbiorcy. Jeśli kontakt, którego kartę już masz, przysyła kartę ponownie po tym,
  jak cię potwierdził, to znaczy, że cię zgubił (usunął i dodał na nowo); `avSent`, `nameSent` i `vfSent` są zerowane i profil idzie jeszcze raz.
  Obcy, którzy tylko napisali pierwsi (`incoming`, bez twojej odpowiedzi), nie dostają nic z tego.

### Cofanie wysłania wiadomości

Przytrzymaj (albo kliknij prawym, albo „Cofnij wysłanie” po stuknięciu w dymek) własną wiadomość. `{ "t": "unsend", "id": <id w sieci>, "g"? }` idzie
do każdego odbiorcy, a wiadomość znika lokalnie od razu, razem z blobem zdjęcia. Odbiorca przyjmuje to tylko dla własnych wiadomości nadawcy
(lokalne id to `idNadawcy.idWSieci`, nadawca jest uwierzytelniony przez Signal), usuwa wiadomość i jej blob, czyści cytowany fragment w widocznych
odpowiedziach i zapamiętuje id w `kv/unsent` (1000 wpisów), żeby wiadomość, która dojdzie po cofnięciu, została odrzucona. Niedoręczone cofnięcia
zostają w `kv/unsends` i są ponawiane przy starcie i gdy pojawia się sąsiad. Powiadomień już pokazanych nie da się wycofać.

### Odpowiedzi i podpisy

Wiadomość `msg` lub `att` może nieść `re = { id, who, text?, kind? }`: `id` to identyfikator w sieci cytowanej wiadomości, `who`
to ripploId jej autora, `text` fragment do 120 znaków, `kind` image / video / voice dla multimediów. Odbiorca waliduje wszystkie
cztery pola i odrzuca zniekształcone `re`, zachowując wiadomość. Mapuje odwołanie na lokalny identyfikator wiadomości (`id` dla
własnych, `who.id` dla cudzych), więc stuknięcie w cytat przewija do oryginału. Fragment to to, co zadeklaruje nadawca, jak w
każdym komunikatorze. Wskaźnik `att` może też nieść `text`, podpis do 1000 znaków, pokazywany pod multimediami. Podpis ani odpowiedź
niczego nie zmieniają w uprawnieniach: bramkowanie multimediów z sekcji 6.1 nadal obowiązuje.

### Wiadomości głosowe

Nagrywane przez `MediaRecorder` (`audio/webm;codecs=opus`, w razie braku `audio/mp4`, `audio/ogg`), paczki co 250 ms.
Pasek poziomu na żywo (analizator WebAudio) zasila kreski podczas nagrywania oraz `wave`, do 64 bajtów (40 używanych),
każdy 0-255 względem najgłośniejszej próbki. Prawdziwy czas jest mierzony, a nie czytany z Blob. Wiadomość-wskaźnik niesie
`duration` (s, ≤ 3600) i `wave` (base64, ≤ 96 znaków); odbiorca waliduje oba i rysuje kreski z `wave`. Nagranie krótsze niż
~800 bajtów lub ze szczytem < 0.02 nie jest wysyłane („Nie nagrano dźwięku”).

### Zdjęcie profilowe

Opcjonalne, ustawiane w Ustawienia → Profil: kadrowane do JPEG 160×160, ≤ 16 KiB, zapisane w `kv/profile.avatar`
(base64). Nigdy nie trafia do karty, QR, linku, `hello` ani `REPLY` (muszą być małe i docierają do obcych).
Podróżuje tylko jako pole `av` w wiadomości szyfrowanej Signalem, więc przekaźnik go nie widzi:
- `av` jest dołączane do wiadomości do kontaktu, gdy `contact.avSent != wersjaMojegoZdjęcia`
  (`SHA-256(avatar)[0..4]`, puste gdy brak). Pierwsza wiadomość do nowego kontaktu zawsze je niesie, więc odbiorca
  widzi zdjęcie osoby, która go dodała lub chce dodać.
- Zmiana lub usunięcie zdjęcia wysyła `{ "t": "profile" }` (sam nośnik) do każdego kontaktu; nieudane wysłanie
  zeruje `avSent`, więc następna wiadomość ponawia. `av: ""` usuwa zdjęcie u odbiorcy.
- Odbiorca przyjmuje `av` tylko jeśli to base64, ≤ 16 KiB i zaczyna się od magicznych bajtów JPEG `FF D8 FF`,
  po czym zapisuje `contact.avatar`; w przeciwnym razie ignoruje.

## 6. Wiadomości APP link-local (JSON)

- `{ "t": "hello", "card": "<b64 card bytes>", "r": 1? }` — wysyłana do każdego nowego sąsiada; wypełnia sekcję „W pobliżu”
  w zakładce Ludzie i umożliwia dowód bliskości. `r` = „nie mam jeszcze twojej karty, odpowiedz”: odbiorca odsyła hello
  bez `r`. Nadawca, który nadal nie ma karty sąsiada, ponawia z `r` po 3, 6, 12 … aż do co 60 s, dopóki sąsiad nie ma karty, a hello, które przyjdzie przed
  zdarzeniem sąsiada, jest buforowane per węzeł, więc wykrywanie jest symetryczne. Gdy użytkownik jest ukryty (niżej),
  hello idzie tylko do sąsiadów, których karta należy do kontaktu (jedna odpowiedź na łącze, więc dwa ukryte kontakty
  nie odbijają się w nieskończoność).
- `{ "t": "challenge" ... }`, `{ "t": "proof" ... }` — sekcja 5.

## 6.1 Zaproszenia (zakładka Ludzie)

Zamiast dodawać obcego od razu, „Zaproś” wysyła prośbę, którą druga osoba przyjmuje lub odrzuca. Wszystko jest
szyfrowane Signalem; karta jedzie jak zwykle jako piggyback `c`.
- Nadawca: zapisuje kontakt z `request: "out"` (jeszcze bez czatu) i wysyła `{ "t": "invite" }`. Nieudane doręczenie
  ustawia `inviteFailed`, a wiersz oferuje Ponów.
- Odbiorca: `invite` od nieznanego nadawcy tworzy kontakt z `request: "in"` bez czatu oraz powiadomienie. Liczba
  oczekujących próśb jest nieograniczona (limit 20 osób dotyczy tylko wyszukiwania). Od kontaktu z `request: "in"` każda wiadomość poza `invite` jest odrzucana. Czaty → „Zaproszenia”
  (pod polem szukaj) pokazuje Akceptuj / Odrzuć.
- Akceptacja: flaga prośby jest zdejmowana, powstaje czat, startuje weryfikacja nearby, wysyłane jest `{ "t": "accept" }`.
  Odrzucenie: wysyłane jest `{ "t": "decline" }`, potem kontakt i sesja są usuwane; nadawca usuwa oczekujący kontakt.
  Każda inna wiadomość od kontaktu z `request: "out"` albo wzajemne `invite` liczy się jako akceptacja.
- Kontakty z flagą prośby są ukryte w Nowym czacie, nie można ich dodać do grup, nigdy nie dostają wysyłek profilu
  (`profile`, ponowne `hello`) i dostają goły `{ "t": "decline" }` bez karty, nazwy i zdjęcia. Pisanie do kogoś, kogo tylko
  zaprosiłeś/aś, jest odrzucane, a zeskanowanie QR lub otwarcie linku osoby, która cię zaprosiła, akceptuje prośbę.
  Ktoś spoza kontaktów nadal może otworzyć zwykły czat, pisząc pierwszy (QR/link); mogą pisać tekst, ale
  żadne połączenie nie zadzwoni (§13) i żaden wskaźnik multimediów nie jest przyjmowany, dopóki im nie odpiszesz. Lustrzana reguła
  dla nadawcy: `sendAttachment` w czacie bezpośrednim rzuca `media_locked`, dopóki druga osoba nie odpowie (`cardAck`), chyba że
  napisała pierwsza (`addedVia: "incoming"`); tekst jest zawsze dozwolony. Grupy nie są bramkowane.

## 7. Zakładka Ludzie (wykrywanie w całej sieci mesh)

Payload DISCOVER = `{ "t": "who" }`; każdy węzeł odpowiada payloadem REPLY = bajty swojej wizytówki (§1).
Ustawienia → Profil → „Widoczność w Znajdź osoby” (domyślnie włączona). Wyłączenie wysyła też link-lokalne `{ "t": "bye" }` do sąsiadów, którzy nie są
kontaktami; porzucają oni kartę, którą o tobie trzymają (kontakty ją zachowują), a `invite` od obcego jest ignorowane, gdy jesteś ukryty/a. Wyłączona: DISCOVER nie dostaje odpowiedzi
(węzeł nadal go przekazuje), a hello idzie tylko do zaakceptowanych kontaktów (§6). Ograniczenia: sąsiad, który powtórzy publiczną
kartę kontaktu, dostanie twoje hello, więc obecność nie jest ukryta przed aktywnym atakującym, a dwa ukryte kontakty nie znajdą się
w pobliżu (żaden nie wysyła pierwszy), więc nie zweryfikują się w pobliżu ani nie zadzwonią.

Ładunek DISCOVER: `{ "t": "who", "h"?: n, "lo"?: n, "q"?: hash }`. `h` / `lo` = odpowiedz tylko, gdy odległość `d`
(liczba łączy od pytającego, `packet.hops + 1`) spełnia `lo < d <= h`; `q` = `b64url(SHA-256("ripplo-find-v1\0" | norm)[0..8])`,
gdzie `norm` to nazwa po NFKC, małymi literami, ze zwiniętymi odstępami, albo ripploId bez myślników wielkimi literami;
węzeł odpowiada tylko, gdy `q` równa się skrótowi jego nazwy lub id. Szukanie wymaga więc dokładnej pełnej nazwy lub id. Skrót jest krótki i bez soli, więc ukrywa nazwę tylko przed
przypadkowymi obserwatorami: kto zgadnie nazwę (albo ma już kartę z wcześniejszego REPLY, w przypadku id), dopasuje go.
To nie jest gwarancja prywatności. Pytający sprawdza też każdą odpowiedź względem zapytania.
Lista odświeżenia (automatycznego i ręcznego) ma najwyżej 20 osób i jest przeszukiwana pierścieniami (h = 1, 3, 8,
potem bez limitu; każdy pierścień to osobny DISCOVER, następny tylko gdy znaleziono mniej niż 20). W liście wygrywają
najbliżsi: gdy jest pełna, odpowiedź z mniejszą liczbą przeskoków zastępuje najdalszą osobę, a lista jest posortowana
po przeskokach. Szukanie po nazwie trzyma najwyżej 50 trafień, pokazuje je zamiast listy, a wyczyszczenie przywraca
poprzednią listę.

Odświeżane automatycznie raz w nocy albo gdy użytkownik stuknie odśwież. DISCOVER zalewa całą sieć mesh, stąd
harmonogram: okno 02:00-05:00 czasu lokalnego jest pocięte na 720 slotów po 15 s, a każdy telefon ma swój slot
`parseInt(tag[0..4 bajty]) mod 720` (stały, więc telefony skanują jeden po drugim, a nie wszystkie naraz). Telefon,
który spał w swoim slocie, skanuje, gdy tylko aplikacja obudzi się w oknie, najwyżej raz na 20 h.
Wyszukiwanie kończy się po 30 s albo wcześniej, gdy przyszedł zagregowany DEAD_END i przez 10 s nie dotarła żadna
odpowiedź REPLY (telefon na końcu łańcucha od razu odsyła ślepy zaułek, ale jego REPLY buduje JS chwilę później, więc
sam ślepy zaułek nie może kończyć wyszukiwania), albo od razu, gdy DISCOVER nie dotarł do żadnego sąsiada. Osoba dodana stąd jest
niezweryfikowana (przekaźnik mógł podmienić wizytówkę) i dostaje to samo ostrzeżenie co przy linku zaproszenia.

## 8. Cykl życia wiadomości (co widzi nadawca)

`encrypting` → `sending` (przekazano N sąsiadom; załączniki pokazują postęp fragmentów w %) →
`delivered` (ACK, „przez k telefonów”) lub `out_of_range` (wszystkie gałęzie zakończyły się dead-endem albo upłynął
limit 5 min, z przyciskiem **Ponów**). `failed` = błąd lokalny. Wiadomości przychodzące: wyświetlane i zgłaszane powiadomieniem dopiero
po otrzymaniu w całości (w przypadku załączników wskaźnik przychodzi po wszystkich fragmentach). Warstwa natywna wysyła ACK dla DATA zaraz po
zapisaniu do skrzynki (inbox), więc dostarczanie działa przy wyłączonym ekranie i zamkniętej aplikacji.

## 9. Kontrakt wtyczki natywnej — `RipploMesh` (Capacitor)

Wartości binarne to ciągi base64 (standardowego); tagi węzłów to małe litery hex.

| method | args → result |
|--------|---------------|
| `start` | `{ selfTag }` → `{ nodeTag }` — starts transports + background service |
| `stop` | – |
| `send` | `{ packet }` → `{ neighbors }` — JS-originated DATA/DISCOVER/REPLY (`from = SELF`) |
| `sendApp` | `{ node, payload }` — link-local APP packet to one neighbor |
| `getNeighbors` | → `{ neighbors: [{ node, medium, kbps, rttMs, links: [{medium,kbps}] }] }` |
| `drainInbox` | → `{ packets: [{ packet, from }] }` — packets received while JS was not attached |
| `getDbKey` | → `{ key }` 32 bytes, created once, stored with Keystore / Keychain |
| `selfHash` | → `{ sha256 }` hex of the installed APK (Android only) |
| `installUpdate` | `{ url, sha256, prompt? }` → `{ status }` — pobranie, weryfikacja SHA-256 i certyfikatu, instalacja. Odrzuca `install_permission` (przed pobraniem), gdy Ripplo nie ma zgody „instaluj nieznane aplikacje”; z `prompt` otwiera ten ekran ustawień |
| `requestBatteryExemption` | – (Android) |
| `startRing` / `stopRing` | – (Android) — dzwoni i wibruje przy połączeniu przychodzącym zgodnie z systemowymi ustawieniami dźwięku (§13) |
| `takeShare` | → `{ share? }` — oczekująca zawartość z menu udostępniania Androida, czyszczona po odczycie |
| `setAutoUpdate` | `{ enabled }` — Android: zapisuje ustawienie i planuje / anuluje zadanie aktualizacji w tle (§10) |
| `checkPermissions` / `requestPermissions` | aliasy `bluetooth`, `wifi`, `notifications`, `microphone` (Android `RECORD_AUDIO`, pytane jawnie razem z pozostałymi i jeszcze raz przed połączeniem, niewymagane do wejścia do aplikacji); wynik zawiera też `battery` (`granted`, gdy aplikacja jest zwolniona z optymalizacji baterii, tylko Android; nie blokuje przejścia dalej) |
| `signalInit` | → `{ bundle, ik }` — creates the identity on first call, then returns the same bundle (§1) |
| `signalAddContact` | `{ bundle }` → `{ tag }` — verifies both prekey signatures, runs `processPreKeyBundle` (PQXDH), saves the identity |
| `signalSeal` | `{ tag, plaintext }` → `{ payload }` — Signal-encrypt for `hex(tag)` then seal (§2); `payload` is the sealed bytes, used directly as the DATA payload (its leading `0x01` is the DATA kind) |
| `signalOpen` | `{ payload }` → `{ tag, ik, plaintext }` — unseal + Signal-decrypt; rejects on any mismatch |
| `signalProof` | `{ ik, n, challengerTag, proverTag }` → `{ mac }` — §2 nearby proof MAC with the own identity key |
| `signalSafetyNumber` | `{ ik }` → `{ digits }` — 60 digits (§2) |
| `signalForget` | `{ tag }` — delete the session and stored identity for that contact |

Wszystkie wywołania `signal*` działają na jednej kolejce szeregowej w natywnym `SignalCore`. Błędy odrzucają z kodem:
`bad_bundle`, `no_session`, `bad_message`, `untrusted_identity`.

Zdarzenia (`addListener`): `packet` `{ packet, from }` (from = węzeł w hex, `"self"` dla dostarczeń
ruchu pochodzącego z JS), `neighbor` `{ node, up, medium, kbps }`, `updateProgress` `{ progress }`, `share` `{}` (nadeszło udostępnienie, wywołaj `takeShare`).

Cel udostępniania (Android): `MainActivity` przyjmuje `ACTION_SEND` dla `text/plain`, `image/*`, `video/*`, `audio/*`. Plugin
czyta go przy starcie i w `onNewIntent`, przyjmuje tylko URI `content://` innych aplikacji (nigdy `file://` ani własnego
providera Ripplo), kopiuje strumień (≤ 20 MiB) do `cache/share` i trzyma jedno oczekujące udostępnienie;
`takeShare` → `{ share?: { kind: text|image|video|voice, text | mime + path } }` zwraca je i czyści. JS pokazuje
„Wyślij do…” (czaty i grupy, bez oczekujących próśb) po odblokowaniu aplikacji; wybór czatu od razu wysyła tekst lub
załącznik i otwiera ten czat. Bez tego wyboru nic nie jest wysyłane. iOS nie ma jeszcze rozszerzenia udostępniania.

Gdy nie ma podłączonego listenera JS, silnik trzyma pakiety dla siebie w trwałej skrzynce (inbox, maks. 2000)
i pokazuje pozbawione treści powiadomienie *„Nowa wiadomość”* dla payloadów `0x01`.

## 10. Aktualizacje i integralność

- CI (`.github/workflows/build.yml`) buduje na tagach `v*` i publikuje `Ripplo-vX.Y.Z.apk`,
  `Ripplo-vX.Y.Z-unsigned.ipa` oraz `SHA256SUMS` w wydaniu na GitHubie.
- Aplikacja (gdy jest internet) odczytuje `api.github.com/repos/Nahida4479/Ripplo/releases/latest`; nowszy
  semver pokazuje plakietkę aktualizacji. Android z włączoną automatyczną aktualizacją: warstwa natywna pobiera APK, sprawdza jego
  SHA-256 względem skrótu wydania oraz jego certyfikat podpisu względem zainstalowanego, a następnie instaluje
  przez `PackageInstaller` (po cichu od drugiej samoaktualizacji, Android 12+).
- Skróty wydania pochodzą z pola `digest` zasobu w odpowiedzi API (zapasowo: blok `SHA256SUMS` w opisie wydania);
  `SHA256SUMS` nie jest pobierany z WebView, bo przekierowania pobierania z github.com nie mają nagłówków CORS.
  Obecna wersja to natywne `versionName` (`App.getInfo()`), a nie wersja z `package.json`.
- Aktualizacje w tle (Android, ustawienie „Aktualizuj automatycznie”, domyślnie włączone): `UpdateJobService`
  (`JobScheduler`, co 6 h, sieć bez limitu, bateria nie niska, przetrwa restart; ponownie planowany przez
  `UpdatedReceiver`) uruchamia `UpdateEngine.background` w kodzie natywnym także przy zamkniętej aplikacji. Pomija
  uruchomienie, gdy aplikacja jest na pierwszym planie, czyta najnowsze wydanie i gdy jest nowsze niż zainstalowane
  `versionName`, pobiera APK, weryfikuje SHA-256 i certyfikat podpisu i instaluje przez `PackageInstaller`, raz na
  wersję (`attempted`) i rezygnuje z wersji po 3 nieudanych próbach. Tuż przed instalacją ponownie sprawdza, czy
  aplikacja nadal jest w tle. Powiadomienia mają własny kanał „Aktualizacje”. Bez zgody „instaluj nieznane aplikacje” tylko pokazuje powiadomienie „Dostępne Ripplo X.
  Otwórz aplikację, aby zaktualizować.” (raz na wersję). Jeśli system prosi o potwierdzenie
  (`STATUS_PENDING_USER_ACTION`), a nie ma UI, `InstallReceiver` pokazuje „Aktualizacja gotowa. Dotknij, aby
  zainstalować.”, którego dotknięcie otwiera systemowe potwierdzenie.
- W aplikacji: przy starcie i wznowieniu (najwyżej co 10 min) JS sprawdza wydanie; gdy jest nowsze, pokazuje okno
  „Dostępna aktualizacja X. Zaktualizować teraz? / Później” (najwyżej raz na 6 h), niezależnie od ustawienia
  automatycznej aktualizacji. Android instaluje z okna; pozostałe platformy otwierają stronę wydania.
- Po samoaktualizacji system zamyka aplikację. `UpdatedReceiver` (`MY_PACKAGE_REPLACED`) uruchamia ponownie
  `MainActivity` po każdej aktualizacji pakietu. Android 10+ może zablokować
  start aktywności z tła, więc dodatkowo pokazuje powiadomienie „Ripplo zostało zaktualizowane. Dotknij, aby otworzyć.”,
  usuwane przy następnym wznowieniu.
- Naraz działa tylko jedna instalacja: warstwa natywna odrzuca drugie `installUpdate` jako `busy`, a UI blokuje
  Zainstaluj podczas sprawdzania i instalacji (dwa równoległe pobrania współdzieliły `update.apk` i skakał pasek).
- API GitHuba pozwala tylko na 60 niezalogowanych zapytań na godzinę z jednego IP, wspólnych dla wszystkich telefonów w tej samej sieci, więc aplikacja
  trzyma każdą odpowiedź w `localStorage` (`gh:<url>`, świeża przez 30 min; „Sprawdź teraz” akceptuje odpowiedź sprzed minuty; sprawdzenie integralności jest
  świeże przez dobę) i odświeża nieświeże przez `If-None-Match` (304 nie liczy się do limitu). Przy 403 lub 429 zapisuje przerwę do `x-ratelimit-reset` (co najmniej
  minutę), w międzyczasie podaje odpowiedź z pamięci, a gdy jej nie ma, pokazuje „GitHub ogranicza liczbę zapytań z tej sieci. Spróbuj ponownie po GG:MM.” zamiast
  samego kodu.
- Błędy natywnej instalacji niosą komunikat statusu `PackageInstaller`, widoczny w Ustawienia → Aktualizacje.
- Autokontrola: na Androidzie aplikacja liczy skrót własnego zainstalowanego APK i porównuje go z `SHA256SUMS`
  wydania odpowiadającego jej wersji — więc kopie udostępnione przez Nearby Share / Quick Share są również weryfikowane.
  Wynik widoczny w Ustawienia → Bezpieczeństwo.

## 11. Moduły JS

```
src/lib/bytes.js            b64/b64url/hex/utf8/concat/random/base32
src/crypto/vault.js         DB key + record seal/open
src/crypto/db.js            IndexedDB (idb) with encrypted values
src/crypto/signalStore.js   libsignal StorageType backed by db
src/crypto/identity.js      identity, card, tag/ripploId, invite link encode/decode
src/crypto/sealed.js        sealed-sender layer
src/crypto/safety.js        safety number, nearby proof (challenge/answer/check)
src/crypto/attachment.js    file encrypt/decrypt + chunk split
src/mesh/packet.js          encode/decode packets, constants
src/mesh/router.js          reference router (web fallback + tests)
src/mesh/bridge.js          RipploMesh plugin, or web fallback over BroadcastChannel
src/core/state.js           reactive app state
src/core/api.js             facade used by the UI (see below)
src/services/*              updater, notifications, permissions, scheduler, theme
```

`core/api.js` (kontrakt UI):
`init()`, `createProfile(name)`, `myInviteLink()`, `addContactFromLink(text, via)`,
`addPerson(person)`, `verifyNearby(id)`, `verifyByQr(id, scanned)`, `markVerified(id)`,
`safetyNumber(id)`, `sendText(chatId, text)`, `sendAttachment(chatId, file, kind)`,
`retry(msgId)`, `loadMessages(chatId)`, `markRead(chatId)`, `createGroup(name, memberIds)`,
`refreshPeople()`, `deleteChat(chatId)`, `deleteContact(id)`.


## 13. Połączenia głosowe (tylko łącza bezpośrednie, najpierw Android)

Sygnalizacja to wiadomość szyfrowana Signalem (zwykła ścieżka DATA, od kontaktu, który nie jest oczekującą prośbą):
`{ "t": "call", "k": "offer"|"accept"|"decline"|"end", "id": <b64 8 bajtów>, "key"?: <b64 32 bajty>, "r"?: "busy" }`.
Tylko `offer` niesie `key`, losowy 32-bajtowy klucz rozmowy, więc przekaźniki go nie widzą. Odbiorca dzwoni 45 s
(potem `missed`); `decline` z `r: "busy"` odpowiada na ofertę, gdy już trwa rozmowa (dwa telefony dzwoniące do siebie
naraz dostają „Zajęty”). Oferta niesie `ts`; starsza niż 120 s jest ignorowana (oferta, która leżała w skrzynce, nie dzwoni z opóźnieniem). Połączenia są
przyjmowane tylko od kontaktów, które dodałeś/aś, zaakceptowałeś/aś lub do których pisałeś/aś; obcy, który tylko napisał pierwszy, nie
zadzwoni. Obie strony zapisują w czacie linię systemową (nieodebrane, odrzucone, czas trwania).

Dźwięk idzie jako pakiety APP link-local do sąsiada, którego karta z hello to kontakt, więc połączenie wymaga łącza
bezpośredniego (LAN, Wi-Fi Direct/Aware, L2CAP, BLE); w przeciwnym razie przycisk Zadzwoń to mówi. Ładunek (pierwszy bajt
`0x01`, JSON-owe ładunki APP zaczynają się od `{`):
`0x01 | callId(8) | seq u32 | AES-256-GCM(callKey, nonce = role(1) 0 0 0 | seq u32 | 0 0 0 0, AAD = callId | seq, frames)`
gdzie `role` 0 = dzwoniący, 1 = odbierający (więc dwa kierunki nigdy nie używają tego samego nonce) oraz
`frames = count u8 | (len u16 | opus)*`, najwyżej 8 ramek po najwyżej 1275 bajtów. Odbiorca odszyfrowuje rolą
partnera, potem przyjmuje każde `seq` raz w oknie 64 pakietów; wszystko nieuwierzytelnione, z innej rozmowy, powtórzone lub
zniekształcone jest po cichu odrzucane.

Audio (JS, WebCodecs): mikrofon z usuwaniem echa, redukcją szumu i AGC przy 48 kHz, `AudioWorklet`
(`public/call-worklet.js`) tnie 20 ms ramki, `AudioEncoder` Opus 16 kb/s, trzy ramki na pakiet (około 17
pakietów i 4,5 kB/s w każdą stronę), `AudioDecoder` i bufor jitter 100 ms po stronie odtwarzania; ramki, które
stałyby w kolejce dalej niż 400 ms, są porzucane. Raz na sekundę silnik połączenia raportuje szczytowy poziom nagranego i zdekodowanego dźwięku. Przy 4 s ciszy na lokalnym mikrofonie
(gdy nie jest wyciszony) ekran ostrzega „twój mikrofon wydaje się milczeć”; ramki, które przychodzą, ale dekodują się do ciszy, dają „dźwięk
dochodzi, ale jest cichy”; brak jakiejkolwiek ramki przez 4 s po uruchomieniu rozmowy daje „nie dotarł jeszcze żaden dźwięk”. Rozpoczęcie
lub odebranie połączenia najpierw sprawdza uprawnienie do mikrofonu i prosi o nie natywnie, bo WebView może inaczej oddać cichy strumień.
Koder i dekoder są odbudowywane po błędzie, a format PCM jest czytany tak, jak przyszedł, więc jedna zła ramka nie wycisza rozmowy na stałe; ekran połączenia pokazuje
liczby ramek wysłanych / odebranych / odtworzonych / błędów do diagnozy. Jeśli mikrofon milczy przez 4 s, silnik najpierw raz ponawia próbę bez przetwarzania głosu (bez usuwania echa, redukcji szumu i automatycznego
wzmocnienia), częstej przyczyny cichego nagrywania na niektórych telefonach, i dopiero potem pokazuje ostrzeżenie. Wiersz statystyk pokazuje też stan ścieżki,
stan kontekstu audio i liczbę przechwyconych ramek. Wyciszenie wyłącza ścieżkę, więc cisza jest nadal wysyłana i podtrzymuje łącze.
Rozmowa kończy się `lost` po 6 s bez uwierzytelnionej ramki (30 s przed pierwszą, gdy u rozmówcy może być otwarte pytanie o
mikrofon) albo gdy przez 8 s nie ma żadnego sąsiada dla połączenia. Sąsiad jest znajdowany po karcie z hello, po węźle, z którego przyszły
uwierzytelnione ramki połączenia (wiązanym przy pierwszej ramce), albo po węźle zapamiętanym przy kontakcie (`contact.node`, zapisywanym, gdy dochodzi karta hello),
więc połączenie odebrane tuż po ponownym otwarciu aplikacji, zanim wymieniono jakiekolwiek hello, nie jest przerywane.

Dzwonienie (Android, `Ringer`) idzie za ustawieniami samego telefonu, a nie za głośnością aplikacji: tryb dzwonka normalny = domyślny
dzwonek na strumieniu dzwonka (`USAGE_NOTIFICATION_RINGTONE`, w pętli) plus wibracja; tryb wibracji = tylko wibracja; tryb cichy albo Nie
przeszkadzać / każdy filtr przerw inny niż „wszystko” = ani dźwięku, ani wibracji, tylko ekran połączenia. Inne platformy używają zapasowo
tonu WebAudio.

Jeszcze nie: dzwonienie przy zamkniętej aplikacji, rozmowy przez kilka telefonów, iOS (ścieżka WebCodecs nietestowana).
iOS nigdy nie zadzwoni do zamkniętej aplikacji bez pusha od Apple, a on wymaga serwera.


## 14. Powiadomienia i połączenia przy zamkniętej aplikacji (Android)

Pakiet DATA dla tego telefonu, który dochodzi, gdy JS nie jest podpięty (aplikacja zamknięta lub ekran zgaszony), był dotąd zapisywany surowy
i pokazywany jako ogólne „Nowa wiadomość”. Teraz silnik sam go otwiera (`Opener`, wspólny dla procesu `SignalCore` z `Shared`, te same klucze
w Keystore co w aplikacji), więc może pokazać, kto i co napisał, albo zadzwonić przy połączeniu. Odszyfrowana wiadomość jest zużyta z ratchetu,
więc trafia do skrzynki jako rekord zaszyfrowany kluczem bazy (AES-GCM, AAD `inbox`), element `~<callId>`; aplikacja dostaje go jako `{ opened }`
(`drainInbox` albo zdarzenie `opened`) i pomija odszyfrowanie. Jeśli natywne otwarcie lub klucz bazy zawiedzie, zapisywany jest surowy pakiet
i pokazywane ogólne powiadomienie, dokładnie jak wcześniej. Awaria między odszyfrowaniem a zapisem do skrzynki gubi tę jedną wiadomość.

Treść powiadomienia pochodzi z magazynu kontaktów czytanego natywnie (format skarbca z sekcji 12.1) albo, dla obcego, z nazwy w karcie, która
jedzie z wiadomością: wiadomość tekstowa pokazuje `nazwa` / fragment (200 znaków; grupy `grupa: nazwa`, tylko gdy nadawca jest członkiem zapisanej
grupy), zdjęcie „Wysłano zdjęcie”, inny załącznik „Wysłano załącznik”, zaproszenie „Masz zaproszenie do kontaktów od użytkownika nazwa”. Wiadomości
od oczekującej prośby, zaproszenia od obcych w trybie ukrytym oraz wszystko, co nie jest wiadomością, zaproszeniem ani połączeniem, są ciche. Gdy
blokada aplikacji jest włączona, tekst to ogólne „Nowa wiadomość”; na ekranie blokady wersja publiczna jest zawsze ogólna. Rekord niesie `notified`,
więc aplikacja nie pokazuje drugiego powiadomienia. Stuknięcie powiadomienia otwiera ten czat.

Połączenia: oferta od kontaktu, którego dodałeś/aś, zaakceptowałeś/aś lub do którego pisałeś/aś, nie starsza niż 120 s, z poprawnym id i kluczem, gdy nie dzwoni
inne natywne połączenie (stan dzwonienia wygasa po 45 s, nawet jeśli `end` dzwoniącego nigdy nie dojdzie), wywołuje pełnoekranowe powiadomienie na kanale
`calls` i dzwoni przez `Ringer` przez 45 s zgodnie z systemowymi trybami dźwięku; wersja powiadomienia na ekranie blokady jest ogólna („Połączenie
przychodzące”), a przy włączonej blokadzie aplikacji nazwa jest wszędzie zastąpiona przez „Ripplo”. Celem pełnego ekranu jest `CallActivity`, mały natywny
ekran (dzwoniący, Odbierz, Odrzuć), który może pokazać się nad blokadą; `MainActivity` nigdy, więc czaty zostają za blokadą. Odbierz nie prosi o odblokowanie: uruchamia
`MainActivity` z `ripplo.chat` i losowym jednorazowym tokenem utworzonym natywnie dla tego dzwonka (`ripplo.answer`), a `MainActivity` pokazuje się nad blokadą tylko
wtedy, gdy ten token jest w tej chwili ważny (`Opener.peek`; akcja Odbierz w powiadomieniu ma `setAuthenticationRequired(false)`). Aplikacja wchodzi wtedy w tryb
rozmowy na blokadzie (`state.lockedCall`, włączany, gdy w tym momencie `isLocked()` jest prawdą): renderowany jest tylko ekran rozmowy, bez czatów, zakładek,
okien, komunikatów i nakładki blokady aplikacji, ekran zostaje włączony na czas rozmowy (`keepAwake`), a po jej końcu aktywność jest zamykana i usuwana
(`endLockedCall`, także `setShowWhenLocked(false)`), co wraca do ekranu blokady. Jeśli użytkownik odblokuje telefon w trakcie rozmowy, aplikacja po prostu działa
dalej normalnie; połączenie, które się nie pojawi, zamyka ten tryb po 25 s.
Wtyczka zamienia token na id połączenia tylko wtedy, gdy zgadza się z bieżącym dzwonkiem (`Opener.redeem`); aplikacja odbiera automatycznie tylko wtedy, gdy id
połączenia równa się tej wartości, a połączenie dzwoni w ciągu 20 s, więc inna aplikacja, która wywoła wyeksportowaną aktywność, nie wymusi odebrania.
`ripplo.chat` jest przyjmowane tylko, gdy wygląda jak ripploId lub id grupy. Odrzuć wycisza dzwonek i usuwa ofertę ze skrzynki, więc dzwoniący po prostu nie
dostaje odpowiedzi. `end` dla tego samego połączenia anuluje dzwonek i pokazuje „Nieodebrane połączenie”. Wymaga powiadomień i, na Androidzie 14+, specjalnego
dostępu do powiadomień pełnoekranowych, o który prosi ekran uprawnień; bez niego pojawia się baner z tymi samymi akcjami. Otwarcie aplikacji przejmuje sprawę:
wycisza natywny dzwonek, a aplikacja dzwoni sama, dopóki połączenie trwa. Silnik sprawdza miejsce w skrzynce, zanim cokolwiek odszyfruje (200 miejsc jest
zarezerwowanych dla otwartych rekordów, żeby fragmenty załączników ich nie zagłodziły), zapisuje skrzynkę przez plik tymczasowy i zmianę nazwy, trzyma klucz
bazy w pamięci, dostarcza rekordy do aplikacji poza głównym wątkiem (rekord wraca do skrzynki, gdy klucz jest chwilowo niedostępny) i opróżnia skrzynkę jeszcze raz
1,5 s po podpięciu aplikacji. Otwieranie nadal odbywa się wewnątrz blokady routera, więc wolne otwarcie na chwilę opóźnia inny ruch. Natywne powiadomienia powtarzają
własne reguły aplikacji (brak multimediów od obcych, kontrole id i długości, usuwanie znaków sterujących i dwukierunkowych, nazwa z karty nadawcy tylko gdy jego
klucz daje skrót nadawcy, jedno powiadomienie o zaproszeniu od nadawcy na dobę), więc nie pokazuje się nic, co aplikacja by odrzuciła. iOS nie ma odpowiednika:
bez pusha od Apple, który wymaga serwera, zamknięta aplikacja na iOS nie może zadzwonić.
