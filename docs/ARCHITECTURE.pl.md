# Architektura Ripplo

[🇬🇧 English](ARCHITECTURE.md) | 🇵🇱 Polski

Ripplo to komunikator mesh typu offline-first, z szyfrowaniem end-to-end.
Interfejs i rdzeń aplikacji to Flutter 3.50 (Dart). Kryptografia Signal (oficjalna `libsignal`), transporty i router
przekaźnikowy są natywne (Kotlin / Swift), więc prywatne klucze Signal nigdy nie opuszczają kodu natywnego, a telefony przekazują
wiadomości także przy wyłączonym ekranie. Aplikacja Dart i kod natywny rozmawiają przez MethodChannel (§9).

```
┌─────────────── Flutter (Dart) ───────────────┐      ┌─────── native (Kotlin / Swift) ─────────┐
│ Widgets ── core/api.dart ── core/messenger   │      │ SignalCore (libsignal 0.108.5: PQXDH +   │
│   (cards, chats, attachments, at-rest DB)    │ base64│   SPQR triple ratchet, sealed, proofs)  │
│   mesh/bridge.dart (MethodChannel) ──────────┼──────►│ MeshEngine: Router + Links + Transports │
│  desktop dev: dev_mesh.dart (NO crypto)      │◄──────┤  BLE GATT, L2CAP, LAN, Wi-Fi Direct*,   │
│   + mesh/router.dart over UDP loopback       │events │  Wi-Fi Aware*, Multipeer**              │
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

### Wizytówka kontaktu (Dart) i link zaproszenia / QR

`card = 0x02 | nameLen u8 | name UTF-8 (≤ 120 bytes, ≤ 40 chars) | bundle(1776)`

`ripplo://add/<base64url(card)>.<base64url(SHA-256(card)[0..6])>` — około 2,4 KB. Pojedynczy QR dla niego miałby wersję 40
(177 × 177 modułów), której żaden aparat telefonu nie czyta niezawodnie, więc QR to animowana sekwencja klatek (korekcja błędów **L**):
link jest cięty na kawałki po 420 znaków, każdy pokazywany jako `ripplo://p/<zestaw>.<i>.<n>.<kawałek>` (`zestaw` = base64url z
SHA-256(link)[0..6]; około 6 klatek, QR wersja 13, 69 × 69 modułów), a klatki powtarzają się co 700 ms. Skaner zbiera kawałki
w dowolnej kolejności (do 20 na zestaw, 4 zestawy naraz, powtórzenia ignorowane), skleja je, gdy są wszystkie, sprawdza id zestawu względem
SHA-256 wyniku i dopiero wtedy obsługuje link tak, jakby został wklejony. Niezgodny zestaw jest odrzucany z błędem sumy kontrolnej.

**Zaproszenie do udostępniania („Zaproś znajomego”).** Przycisk udostępniania wysyła tekst i ten sam link w postaci webowej,
`https://nahida4479.github.io/Ripplo/add/#<ten sam ładunek>` (`/pl/add/#…` po polsku), za każdym razem z nowym jednorazowym tokenem. Ładunek jest we
fragmencie, którego przeglądarka nigdy nie wysyła do strony, więc GitHub Pages niczego się nie dowiaduje. Strona sprawdza kształt, nie pokazuje imienia z
karty (to nieuwierzytelniony tekst) i oferuje *Otwórz w Ripplo* (`ripplo://add/…`), *Skopiuj zaproszenie* oraz przewodnik pobierania/SideStore. Budowy z sideloadu
nie mają referrera instalacji ani linków uniwersalnych (te wymagają katalogu głównego domeny i płatnego konta Apple), więc po instalacji osoba otwiera
ten sam link jeszcze raz albo wkleja go w *Dodaj kontakt → Wklej link*. `parseLink` przyjmuje obie postaci, tylko dla tej dokładnej strony. Link otwarty
przed utworzeniem profilu jest zapamiętany i proponowany po zakończeniu powitania. Dodanie to zwykły niezweryfikowany kontakt (dowód bliskości, QR lub ręczna weryfikacja później).
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

Zeskanowanie albo otwarcie linku (`qr`, `link`) od razu wysyła też do wystawcy jedną małą zaszyfrowaną wiadomość profilu z kartą i tokenem, więc wystawca widzi skanującego w kontaktach od razu, a nie dopiero po pierwszej wiadomości. Gdy wystawca jest poza zasięgiem, nie jest to ponawiane; karta jedzie wtedy z pierwszą prawdziwą wiadomością jak dotąd.

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
3. **Załączniki** (w stylu Signal, w Dart, `lib/crypto/attachment.dart`): plik jest szyfrowany raz losowym kluczem AES-256-GCM
   (`ct = nonce(12) | GCM(file)`). `ct` jest dzielony na fragmenty po 32 KiB wysyłane jako osobne pakiety DATA.
   Klucz, `SHA-256(ct)`, typ mime, rozmiar i liczba fragmentów podróżują w wiadomości-wskaźniku zaszyfrowanej
   protokołem Signal, wysyłanej **po** potwierdzeniu (ACK) każdego fragmentu. Odbiorca weryfikuje skrót przed odszyfrowaniem.
4. **Dane w spoczynku**: stan Signal (tożsamość, prekeye, sesje, tożsamości) jest przechowywany natywnie jako pliki,
   każdy zaszyfrowany AES-256-GCM kluczem trzymanym w Android Keystore / iOS Keychain
   (`AfterFirstUnlockThisDeviceOnly`). Rekordy po stronie Dart (wiadomości, kontakty, czaty) są zaszyfrowane AES-GCM
   przez `lib/crypto/vault.dart` kluczem bazy danych z `getDbKey` i zapisywane w natywnym magazynie SQLite (§12.1).
5. **Wersja desktopowa do developmentu**: `lib/mesh/dev_signal.dart` (używany przez `lib/mesh/dev_mesh.dart`) zastępuje natywne wywołania Signal jawnym
   zamiennikiem, aby dwie instancje na pulpicie mogły ćwiczyć interfejs. NIE zapewnia żadnego bezpieczeństwa (klucz bazy leży w zwykłym pliku),
   a interfejs to komunikuje. Wersje release nigdy go nie używają: `DevMesh` rzuca wyjątek w trybie release, a `main.dart` wybiera `MeshBridge` na Androidzie, iOS i w każdej wersji release.

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
| 20   | APP         | zeros                       | link-local, handed to the app |

Pierwszy bajt payloadu DATA: `0x01` wiadomość sealed, `0x02` fragment załącznika
(`0x02 | attId(16) | index u32 | total u32 | bytes`).

**Zgodność między wersjami.** Telefony z różnymi wersjami muszą się nadal widzieć. Zasady: zmiany protokołu są addytywne; nieznane
tagi ładunku DATA/APP, typy wiadomości, pola JSON i typy pakietów są ignorowane, nigdy krytyczne; ramka z nieznaną wersją pakietu jest
pomijana bez zamykania łącza (zamyka je tylko błędna długość); `LINK_HELLO` niesie tag węzła w pierwszych 16 bajtach, a wszystko po nich jest ignorowane;
identyfikatory wykrywania (UUID BLE, `_ripplo._tcp`, typ Multipeer) nigdy się nie zmieniają. Sąsiad, którego karty z `hello` ta wersja nie
potrafi odczytać, zostaje sąsiadem i jest pokazany w Ustawieniach jako „Wymaga aktualizacji”, więc różnica wersji jest widoczna, a nie cicha.

Brak limitu przeskoków. Wartości domyślne: wpisy seen/reverse/route wygasają po 10 min, limit pamięci podręcznej seen to 20 000.

### 3.1 Router (identyczny w `lib/mesh/router.dart`, `Router.kt` i `Router.swift`)

Stan: zbiór `seen` par `(type,id)`, `reverse[id] = {prev, dest, pending, done}`,
`routes[destTag] = neighbor`, tag `self`. `prev = SELF` dla pakietów, które pochodzą z lokalnej aplikacji (Dart).

```
onPacket(p, from):                       # from = neighbor nodeTag, or SELF for app-originated
  APP                -> deliver to the app (from)
  DATA | DISCOVER:
    if seen(p): if from != SELF: send DEAD_END(dest=p.id) to from;  return
    mark seen; reverse[p.id] = {prev: from, dest: p.dest, pending: 0, done: false}
    if DATA and p.dest == self: persist to inbox; send ACK(dest=p.id, hops=0) to from; deliver; return
    if DISCOVER and from != SELF: deliver to the app     # the app may answer with REPLY
    q = copy(p); if from != SELF: q.hops = min(p.hops+1, 255)
    targets = DATA and routes[p.dest] alive and != from ? [routes[p.dest]] : neighbors - from
    if targets empty: deadEnd(p.id); return
    reverse[p.id].pending = len(targets); send q to each
  ACK | REPLY:
    if seen(p): return; mark seen
    r = reverse[p.dest]; if !r: return
    if ACK: routes[r.dest] = from (unless from == SELF); r.done = true
    q = copy(p) with hops+1          # hops = links traversed; a direct neighbor gives 1
    if r.prev == SELF: deliver q to the app  else: send q to r.prev
  DEAD_END:
    if seen(p): return; mark seen
    r = reverse[p.dest]; if !r or r.done: return
    r.pending -= 1; if r.pending <= 0: deadEnd(p.dest)

deadEnd(id):  r = reverse[id]; r.done = true
              if r.prev == SELF: deliver DEAD_END(dest=id) to the app   # deliveries for own traffic use from = 'self'
              else send DEAD_END(new id, dest=id) to r.prev
```

Dlaczego wiadomości nie mogą krążyć w pętli: każdy węzeł przekazuje dany `id` najwyżej raz (zbiór seen), więc pakiet nigdy nie przejdzie dwa razy przez ten sam telefon, a duplikaty dostają w odpowiedzi DEAD_END zamiast być przekazywane dalej.
Gdy wszystkie gałęzie wygasną, DEAD_END-y agregują się z powrotem do nadawcy, który pokazuje *„Kontakt jest poza zasięgiem sieci mesh”*.
Nie ma limitu przeskoków, więc wiadomość przejdzie przez dowolnie długi łańcuch telefonów. Aplikacja rezygnuje też po 60 s bez ACK/DEAD_END (łącza mogą zniknąć w trakcie przesyłu); fragmenty załączników czekają 20 s i są wysyłane ponownie do 4 razy ze świeżymi identyfikatorami pakietów.

ACK wracający trasą uczy każdy przekaźnik `routes[dest] = neighbor`, więc kolejne pakiety (np. fragmenty
multimediów) idą unicastem wyuczoną ścieżką zamiast być zalewane (flood).

Przekaźniki nigdy nie przekazują przekazywanych pakietów DATA do aplikacji i nigdy nie powiadamiają użytkownika (wymaganie: żadnego spamu
„wiadomość przeszła przez twój telefon”).

Limity nadużyć (native): maks. 200 pakietów/s na sąsiada, maks. 32 MiB w kolejce na łącze, odrzucanie nadmiaru.

Implementacje. `lib/mesh/router.dart` to router w Dart: uruchamiają go desktopowa sieć deweloperska (`lib/mesh/dev_mesh.dart`) i testy, a na telefonach
aplikacja używa routera natywnego przez most. Musi zachowywać się dokładnie jak `Router.kt` i `Router.swift`; zmiana routera trafia do
wszystkich trzech w tym samym commicie. Różnice znalezione przy portowaniu, istniejące już przed portem i jeszcze nieujednolicone:
- hak zapisu do skrzynki (`host.persist`, DATA dla tego węzła jest zapisywane przed ACK) istnieje tylko w Kotlinie; Dart i Swift nie mają takiego haka;
- Swift najpierw dostarcza DATA dla tego węzła do aplikacji, a dopiero potem wysyła ACK, czyli odwrotnie niż w opisie powyżej (Kotlin i Dart najpierw ACK);
- Kotlin i Swift inaczej niż wzorzec (`router.dart`, port dawnego routera JS) traktują nieudane wysłanie do wybranego celu (rozliczanie `DEAD_END`) oraz wygasanie
  i usuwanie nadmiaru `seen`: wzorzec wygasza wpisy `seen`, `reverse` i `routes` po 10 min, a po przekroczeniu limitu 20 000 usuwa najstarsze wpisy `seen`.

## 4. Łącza i wybór prędkości

Każdy transport dostarcza strumień bajtów; ramki mają postać `u32 length | packet`. Pierwszą ramką na nowym
łączu jest LINK_HELLO z losowym, per proces `nodeTag`. Łącza są grupowane według `nodeTag`, więc jeden
sąsiad może mieć kilka łączy (np. BLE + LAN). Po nawiązaniu łącza i co 5 s (co 15 s w BLE) silnik wysyła
PING z wypełnieniem (16 KiB dla mediów Wi-Fi/L2CAP, 2 KiB dla BLE GATT) i mierzy
`kbps = bits / rttMs`. Router zawsze wysyła przez najszybsze działające łącze sąsiada i w razie awarii
przełącza się na następne. Przed pierwszym pomiarem nominalne kbps: lan 20000,
wifi-aware 20000, wifi-direct 20000, multipeer 10000, l2cap 300, ble 50.

Łącze jest zamykane, gdy przez ponad 30 s nie dotarł żaden bajt, w dwóch kolejnych kontrolach co 5 s. Liczy się każdy odebrany bajt, więc długi transfer go nie
wyzwoli. Łącze ciche dłużej niż 12 s jest próbowane dopiero po pozostałych łączach sąsiada, więc martwe łącze Wi-Fi nie połyka już pakietów, gdy BLE nadal działa. Bez tego łącze, którego druga strona zniknęła bez zamknięcia gniazda, zostawało na liście
sąsiadów, router dalej wysyłał jednoadresowo trasą nauczoną z wcześniejszego ACK, a wiadomości kończyły jako „poza zasięgiem” przy telefonach obok siebie.
Zamknięcie czyści trasy przez nie, więc następny DATA znów zalewa sieć.
LAN na Androidzie ponawia znanego sąsiada co 4 s, a nieudane rozpoznanie usługi do 5 razy, więc szybkie łącze powstaje w kilka sekund zamiast po minucie.

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

**BLE Coded PHY (tylko Android, zawsze włączone).** Gdy telefon zgłasza
`isLeCodedPhySupported()` i `isLeExtendedAdvertisingSupported()`, węzeł dodatkowo uruchamia rozszerzony zestaw ogłoszeń na Coded PHY
(z możliwością połączenia, ten sam UUID usługi, wysoka moc nadawania) i uruchamia dwa równoległe skany: 1M oraz osobny skan wyłącznie Coded (`setLegacy(false)`), dzięki czemu Coded dostaje całe okno skanowania zamiast dzielić je z 1M i jest wykrywany na granicy zasięgu, zanim 1M w ogóle słychać. Trafienie skanu zawiera główny PHY; trafienie coded łączy się z
`PHY_LE_CODED_MASK` (duży zasięg, 125 / 500 kbit/s), trafienie 1M z `PHY_LE_1M_MASK`. Jeśli w ciągu ostatnich 20 s widziano trafienie 1M tego samego adresu,
trafienie coded jest ignorowane (1M jest szybsze). PHY łącza klienckiego jest odczytywany przez `readPhy()` i widoczny w szczegółach dewelopera. Nie ma przełącznika: karta dewelopera tylko pokazuje, czy telefon to obsługuje.
iOS nie ma wyboru PHY w CoreBluetooth, więc używa wyłącznie 1M.

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

- Weryfikacja nigdy nie jest dziedziczona. Kontakt dodany ponownie (np. linkiem po usunięciu) zaczyna jako niezweryfikowany i jest
  sprawdzany od nowa przez bezpośrednie łącze, bo sam link lub karta nie pokazują, że klucz nie został podmieniony.
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

Nagrywane pakietem `record` (`AudioRecorder`, AAC-LC, `audio/mp4`) do pliku tymczasowego w `cache/att/` (§12.5), który po zakończeniu
nagrywania jest odczytywany i usuwany. Amplituda próbkowana co 100 ms zasila kreski podczas nagrywania oraz `wave`, do 64 bajtów (40 używanych),
każdy 0-255 względem najgłośniejszej próbki. Prawdziwy czas jest mierzony zegarem, a nie czytany z pliku. Wiadomość-wskaźnik niesie
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
który spał w swoim slocie, skanuje, gdy tylko aplikacja obudzi się w oknie, najwyżej raz na 20 h. Czas ostatniego skanu jest zapisywany (`kv/peopleRefreshedAt`), więc nagłówek
pokazuje go, a limit 20 h działa także po restarcie.
Wyszukiwanie kończy się po 30 s albo wcześniej, gdy przyszedł zagregowany DEAD_END i przez 10 s nie dotarła żadna
odpowiedź REPLY (telefon na końcu łańcucha od razu odsyła ślepy zaułek, ale jego REPLY buduje aplikacja chwilę później, więc
sam ślepy zaułek nie może kończyć wyszukiwania), albo od razu, gdy DISCOVER nie dotarł do żadnego sąsiada. Osoba dodana stąd jest
niezweryfikowana (przekaźnik mógł podmienić wizytówkę) i dostaje to samo ostrzeżenie co przy linku zaproszenia.

## 8. Cykl życia wiadomości (co widzi nadawca)

`encrypting` → `sending` (przekazano N sąsiadom; załączniki pokazują postęp fragmentów w %) →
`delivered` (ACK, „przez k telefonów”) lub `out_of_range` (wszystkie gałęzie zakończyły się dead-endem albo upłynął
limit 60 s, z przyciskiem **Ponów**). `failed` = błąd lokalny. Wiadomości przychodzące: wyświetlane i zgłaszane powiadomieniem dopiero
po otrzymaniu w całości (w przypadku załączników wskaźnik przychodzi po wszystkich fragmentach). Warstwa natywna wysyła ACK dla DATA zaraz po
zapisaniu do skrzynki (inbox), więc dostarczanie działa przy wyłączonym ekranie i zamkniętej aplikacji.
Gdy mesh działa, Android trzyma częściową blokadę wybudzania, blokadę Wi-Fi i blokadę multicastu (zwalniane przy zatrzymaniu), więc procesor, radio Wi-Fi
i multicast mDNS pozostają aktywne przy przygaszonym lub wyłączonym ekranie; bez nich wykrywanie DNS-SD i otwarte łącza zamierają do włączenia ekranu.
Gdy przyjdzie hello kontaktu (wrócił w zasięg albo zmienił łącze), jego wiadomości `out_of_range` i `failed` są wysyłane ponownie
automatycznie (najwyżej co 15 s na kontakt).

**Wskaźnik pisania.** Gdy w polu wiadomości jest tekst, aplikacja co najwyżej co 3 s wysyła `{ "t": "typing", "ts", "g"? }`, zaszyfrowane
protokołem Signal, tylko do kontaktów, które odpowiedziały i są bezpośrednimi sąsiadami. Idzie jako pakiet APP `[2] + zaszyfrowane`, więc nigdy
nie trafia do skrzynki ani powiadomienia, a Android odrzuca go, gdy interfejs jest odłączony. Odbiorca pokazuje w tym czacie trzy animowane
kropki przez 5 s (lub do nadejścia wiadomości), ignoruje je od kogoś, kto nie jest zaakceptowanym kontaktem, i ignoruje starsze niż 5 s.

## 9. Kontrakt mostu natywnego — `ripplo/mesh` (MethodChannel)

Strona Dart: `lib/mesh/bridge.dart` (interfejs `Mesh`, `MeshBridge` na kanałach, `DevMesh` zamiast niego w buildach deweloperskich na pulpicie).
Strona natywna: `RipploMeshPlugin.kt` (Android, `FlutterPlugin`) i `RipploMeshPlugin.swift` (iOS), z tymi samymi nazwami metod.

Kanały: `MethodChannel('ripplo/mesh', JSONMethodCodec())` dla wywołań i `EventChannel('ripplo/mesh/events', JSONMethodCodec())` dla zdarzeń.
Argumenty i wyniki to obiekty JSON. Wartości binarne to ciągi base64 (standardowego); tagi węzłów to małe litery hex. Warstwa natywna wykonuje każde wywołanie poza
głównym wątkiem. Błąd wraca jako `PlatformException(code, message)`, który `MeshBridge` rzuca ponownie jako `MeshError(code, message)`; nieznana metoda odpowiada
`notImplemented`. Wywołania opcjonalne i diagnostyczne (`getDiag`, `getTransports`, `getBleCaps`, `getDeviceInfo`, `usbLog`, `devConnect`, `isLocked`, `takeOpen`,
`takeShare`, `fromPlay` oraz `setAutoUpdate` / `requestFullScreen` / `startRing`, gdy ich brak) nigdy nie rzucają po stronie Dart: zwracają pustą wartość.

| method | args → result |
|--------|---------------|
| `start` | `{ selfTag, background? }` → `{ nodeTag }` — uruchamia transporty + usługę w tle (`background` domyślnie true; `MeshBridge` wysyła tylko `selfTag`) |
| `stop` | – |
| `send` | `{ packet }` → `{ neighbors }` — DATA/DISCOVER/REPLY pochodzące z aplikacji (`from = SELF`) |
| `sendApp` | `{ node, payload }` — pakiet APP link-local do jednego sąsiada; odrzuca `no link`, gdy łącza nie ma |
| `getNeighbors` | → `{ neighbors: [{ node, medium, kbps, rttMs, links: [{medium,kbps,rttMs,outbound}], seen: [medium] }] }` — `seen` = media, na których sąsiad został wykryty w ostatnich 2 min (LAN, Wi-Fi Direct, Wi-Fi Aware) bez otwartego łącza; zakładka Znajdź osoby pokazuje je jako wyszarzone plakietki bez ptaszka |
| `devConnect` / `devDisconnect` | Tryb dewelopera: `{ node, spec }` → `{ started }` wymusza próbę połączenia z sąsiadem jednym medium (`lan`, `wifi-direct`, `wifi-aware`, `ble:1m`, `ble:coded`), ignorując istniejące łącza i reguły inicjatora (BLE łączy się z niedawnymi trafieniami skanu, bo trafienie nie zawiera tagu węzła); `{ node, medium }` zamyka łącza tego medium |
| `getBleCaps` | → `{ coded, extended }` (tylko informacja o obsłudze, bez przełącznika) |
| `usbLog` | `{ text }` → `{ usb }`. Zapisuje tekst w logcat (tag `ripplo`) wyłącznie, gdy telefon jest podłączony przez USB z włączonym debugowaniem USB; w przeciwnym razie nic nie robi i zwraca `usb: false`. Przechodzi przez to każda linia diagnostyczna aplikacji (`lib/core/diag.dart`) i zrzut „wyślij logi”, więc deweloper z `adb logcat` czyta je bez wysyłania czegokolwiek z telefonu. Gdy `usb` jest true, „wyślij logi” pomija odbiorcę |
| `getDiag` / `clearDiag` / `getTransports` | Tryb dewelopera na Androidzie: `{ log }`, dziennik diagnostyczny w pamięci (600 linii, te same co w logcat pod tagiem `ripplo`), jego czyszczenie oraz `{ transports: [{ name, running, unsupported }] }` |
| `getDeviceInfo` | → `{ text }` — wielowierszowy opis urządzenia, radiotelefonów (BLE, Coded PHY, Wi-Fi Aware / Direct) i stanu zasilania, pokazywany w karcie dewelopera i w zrzucie logów |
| `drainInbox` | → `{ packets: [{ packet, from } lub { opened }] }` — pakiety odebrane, gdy aplikacja nie była podpięta; `opened` to rekord już odszyfrowany natywnie (§14) |
| `isLocked` | → `{ locked }` — czy blokada ekranu urządzenia jest aktywna |
| `keepAwake` | `{ on }` — Android: trzyma ekran włączony, gdy ekran połączenia jest pokazany nad ekranem blokady (§14) |
| `endLockedCall` | – Android: kończy aktywność otwartą nad ekranem blokady po połączeniu odebranym z ekranu blokady (§14) |
| `takeOpen` | → `{ open? }`, gdzie `open = { chatId, answer? }` — stuknięcie powiadomienia lub odebranie połączenia, które uruchomiło aplikację, czyszczone po odczycie; zdarzenie `open` to zapowiada |
| `getDbKey` | → `{ key }` 32 bajty, tworzony raz, przechowywany w Keystore / Keychain |
| `selfHash` | → `{ sha256 }` w hex zainstalowanego APK (tylko Android) |
| `fromPlay` | → `{ play }` true, gdy pakiet instalujący to `com.android.vending` (Android). Wtedy aplikacja pomija sprawdzanie aktualizacji i integralności, wyłącza `setAutoUpdate`, a Ustawienia → Aktualizacje pokazują tylko obecną wersję (§10) |
| `installUpdate` | `{ url, sha256, prompt? }` → `{ status }` — pobranie, weryfikacja SHA-256 i certyfikatu, instalacja. Odrzuca `install_permission` (przed pobraniem), gdy Ripplo nie ma zgody „instaluj nieznane aplikacje”; z `prompt` otwiera ten ekran ustawień |
| `requestBatteryExemption` | – (Android) |
| `requestFullScreen` | – (Android 14+) otwiera ustawienia specjalnego dostępu do powiadomień pełnoekranowych (§14) |
| `startRing` / `stopRing` | – (Android) — dzwoni i wibruje przy połączeniu przychodzącym zgodnie z systemowymi ustawieniami dźwięku (§13) |
| `takeShare` | → `{ share? }` — oczekująca zawartość z menu udostępniania Androida, czyszczona po odczycie |
| `setAutoUpdate` | `{ enabled }` — Android: zapisuje ustawienie i planuje / anuluje zadanie aktualizacji w tle (§10) |
| `checkPermissions` / `requestPermissions` | → `{ bluetooth, wifi, notifications, microphone, battery, fullscreen? }` z wartościami `granted` lub `prompt` (oraz innymi, jak zgłasza platforma). `microphone` to Android `RECORD_AUDIO`, pytane jawnie razem z pozostałymi i jeszcze raz przed połączeniem, niewymagane do wejścia do aplikacji; `battery` to `granted`, gdy aplikacja jest zwolniona z optymalizacji baterii (tylko Android; nie blokuje przejścia dalej); `fullscreen` jest na Androidzie 14+ |
| `dbPut` / `dbPutMany` | `{ store, key, idx?, value }` / `{ rows: [{ store, key, idx?, value }] }` → `{ count }` — zapis zaszyfrowanych rekordów (§12.1); most Dart używa tylko `dbPut` |
| `dbGet` / `dbDel` | `{ store, key }` → `{ value }` (`null`, gdy brak) / – |
| `dbKeys` | `{ store, prefix? }` → `{ keys }` |
| `dbAll` / `dbByIdx` | `{ store }` / `{ store, idx }` → `{ rows: [{ key, value }] }` |
| `dbCount` | → `{ count }` — liczba wierszy w bazie |
| `authAvailable` | → `{ biometric, deviceCredential }` |
| `authenticate` | `{ reason }` → `{ ok }` — systemowe okno biometrii / poświadczeń urządzenia (§12.3) |
| `setSecure` | `{ on }` — Android `FLAG_SECURE` na oknie, ukrywa zawartość w przełączniku aplikacji |
| `backupStatus` | → `{ enabled, lastAt, folder }` (`folder` to nazwa wyświetlana lub `null`) |
| `backupEnable` | → `{ code }` — tworzy kod odzyskiwania (§12.2) |
| `backupShowCode` / `backupDisable` | po uwierzytelnieniu: → `{ code }` / –. Odrzucają `auth_failed` |
| `backupChooseFolder` | → `{ folder }` — systemowy wybór folderu dla kopii automatycznych |
| `backupCreate` | `{ mode: pick / now / auto, meta }` → opis zapisanego pliku albo `{ skipped: true }` dla `auto` w ciągu 24 h od ostatniej kopii. Odrzuca `not_enabled`, `no_folder`, `cancelled` |
| `backupRestore` | `{ code }` → `{ meta }` — systemowy wybór pliku, potem weryfikacja, wyczyszczenie i przywrócenie (§12.2). Odrzuca `bad_code`, `cancelled` i błędy formatu kopii |
| `notify` | `{ title, body, chatId? }` — pokazuje lokalne powiadomienie (stuknięcie otwiera czat) |
| `signalInit` | → `{ bundle, ik }` — creates the identity on first call, then returns the same bundle (§1) |
| `signalAddContact` | `{ bundle }` → `{ tag }` — verifies both prekey signatures, runs `processPreKeyBundle` (PQXDH), saves the identity |
| `signalSeal` | `{ tag, plaintext }` → `{ payload }` — Signal-encrypt for `hex(tag)` then seal (§2); `payload` is the sealed bytes, used directly as the DATA payload (its leading `0x01` is the DATA kind) |
| `signalOpen` | `{ payload }` → `{ tag, ik, plaintext }` — unseal + Signal-decrypt; rejects on any mismatch |
| `signalProof` | `{ ik, n, challengerTag, proverTag }` → `{ mac }` — §2 nearby proof MAC with the own identity key |
| `signalSafetyNumber` | `{ ik }` → `{ digits }` — 60 digits (§2) |
| `signalForget` | `{ tag }` — delete the session and stored identity for that contact |

Wszystkie wywołania `signal*` działają na jednej kolejce szeregowej w natywnym `SignalCore`. Błędy odrzucają z kodem:
`bad_bundle`, `no_session`, `bad_message`, `untrusted_identity`.

Zdarzenia (`MeshBridge.on(event, callback)` filtruje jeden wspólny strumień kopert `{ event, data }`): `packet` `{ packet, from }` (from = węzeł w hex, `"self"` dla dostarczeń
ruchu pochodzącego z aplikacji; most dekoduje `packet` do bajtów), `neighbor` `{ node, up, medium, kbps }`, `updateProgress` `{ progress }`,
`share` `{}` (nadeszło udostępnienie, wywołaj `takeShare`), `open` `{}` (czeka stuknięcie powiadomienia lub odebranie połączenia, wywołaj `takeOpen`), `opened` (rekord odszyfrowany
natywnie, gdy aplikacja była podpięta, w tym samym kształcie co element `opened` z `drainInbox`), `devStage` `{ medium, node, stage, detail, at }` (etapy łączenia dla dewelopera).
Strona natywna emituje `open` i `share` ponownie, gdy podpina się słuchacz, a któreś nadal czeka.

Cel udostępniania (Android): `MainActivity` przyjmuje `ACTION_SEND` dla `text/plain`, `image/*`, `video/*`, `audio/*`. Plugin
czyta go przy starcie i w `onNewIntent`, przyjmuje tylko URI `content://` innych aplikacji (nigdy `file://` ani własnego
providera Ripplo), kopiuje strumień (≤ 20 MiB) do `cache/share` i trzyma jedno oczekujące udostępnienie;
`takeShare` → `{ share?: { kind: text|image|video|voice, text | mime + path } }` zwraca je i czyści. Aplikacja pokazuje
„Wyślij do…” (czaty i grupy, bez oczekujących próśb) po odblokowaniu; wybór czatu od razu wysyła tekst lub
załącznik i otwiera ten czat. Bez tego wyboru nic nie jest wysyłane. iOS nie ma jeszcze rozszerzenia udostępniania.

Gdy strona Dart nie jest podpięta, silnik trzyma pakiety dla siebie w trwałej skrzynce (inbox, maks. 2000)
i pokazuje pozbawione treści powiadomienie *„Nowa wiadomość”* dla payloadów `0x01` (albo sam je otwiera, §14).

### 9.1 Kanały dźwięku połączeń

`MethodChannel('ripplo/audio')` (kodek standardowy) i `EventChannel('ripplo/audio/pcm')`, zaimplementowane w `CallAudio.kt` i `CallAudio.swift` i używane przez
`MethodChannelCallAudio` w `lib/core/call_audio.dart`. Metody: `audioStart` `{ raw }` (otwiera nagrywanie i odtwarzanie, PCM 48 kHz mono 16-bit; `raw` = zwykłe źródło
mikrofonu bez przetwarzania głosu), `audioPlay` `{ pcm }` (kolejkuje zdekodowane PCM do odtworzenia), `audioMute` `{ on }`, `audioFallback` (restartuje nagrywanie bez przetwarzania
głosu), `audioStop`. Strumień zdarzeń dostarcza nagrane PCM jako tablice bajtów. Kodowanie i dekodowanie Opus odbywa się w Dart (§13).

## 10. Aktualizacje i integralność

- CI (`.github/workflows/build.yml`) uruchamia `flutter analyze`, `flutter test` i natywne testy jednostkowe Signal, a potem buduje na tagach `v*` i przy pushach do gałęzi
  `flutter`. Tag publikuje `Ripplo-vX.Y.Z.apk`, `Ripplo-vX.Y.Z-play.aab`, `Ripplo-vX.Y.Z-beta-unsigned-for_developers.ipa` oraz `SHA256SUMS` w wydaniu na GitHubie;
  push do `flutter` buduje tylko testowy APK (wersja `vX.Y.Z-dev<run>`), trzymany jako artefakt przebiegu `android-test` przez 14 dni i nigdy niewydawany (§15).
- Aplikacja (gdy jest internet) odczytuje `api.github.com/repos/Nahida4479/Ripplo/releases/latest`; nowszy
  semver pokazuje plakietkę aktualizacji. Android z włączoną automatyczną aktualizacją: warstwa natywna pobiera APK, sprawdza jego
  SHA-256 względem skrótu wydania oraz jego certyfikat podpisu względem zainstalowanego, a następnie instaluje
  przez `PackageInstaller` (po cichu od drugiej samoaktualizacji, Android 12+).
- Skróty wydania pochodzą z pola `digest` zasobu w odpowiedzi API (zapasowo: blok `SHA256SUMS` w opisie wydania);
  `SHA256SUMS` sam nie jest pobierany przez aplikację.
  Obecna wersja to to, co zgłasza platforma (`PackageInfo.fromPlatform()` w `lib/services/updater.dart`, natywne `versionName` ustawiane przez `--build-name`), a nie wartość wpisana w kodzie Dart.
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
- Wersja Google Play (`flutter build appbundle --release --flavor play`, job CI `play`): `android/app/src/play/AndroidManifest.xml` usuwa `REQUEST_INSTALL_PACKAGES`. Gdy `fromPlay` jest true, aplikacja nie łączy się z GitHubem po aktualizacje ani integralność i ukrywa w Aktualizacjach wszystko poza obecną wersją; aktualizacje dostarcza Play.
- W aplikacji: przy starcie i wznowieniu (najwyżej co 10 min) aplikacja sprawdza wydanie; gdy jest nowsze, pokazuje okno
  „Dostępna aktualizacja X. Zaktualizować teraz? / Później” (najwyżej raz na 6 h), niezależnie od ustawienia
  automatycznej aktualizacji. Android instaluje z okna; pozostałe platformy otwierają stronę wydania.
- Po samoaktualizacji system zamyka aplikację. `UpdatedReceiver` (`MY_PACKAGE_REPLACED`) uruchamia ponownie
  `MainActivity` po każdej aktualizacji pakietu. Android 10+ może zablokować
  start aktywności z tła, więc dodatkowo pokazuje powiadomienie „Ripplo zostało zaktualizowane. Dotknij, aby otworzyć.”,
  usuwane przy następnym wznowieniu.
- Naraz działa tylko jedna instalacja: warstwa natywna odrzuca drugie `installUpdate` jako `busy`, a UI blokuje
  Zainstaluj podczas sprawdzania i instalacji (dwa równoległe pobrania współdzieliły `update.apk` i skakał pasek).
- API GitHuba pozwala tylko na 60 niezalogowanych zapytań na godzinę z jednego IP, wspólnych dla wszystkich telefonów w tej samej sieci, więc aplikacja
  trzyma każdą odpowiedź w `shared_preferences` (`gh:<url>`, świeża przez 30 min; „Sprawdź teraz” akceptuje odpowiedź sprzed minuty; sprawdzenie integralności jest
  świeże przez dobę) i odświeża nieświeże przez `If-None-Match` (304 nie liczy się do limitu). Przy 403 lub 429 zapisuje przerwę do `x-ratelimit-reset` (co najmniej
  minutę), w międzyczasie podaje odpowiedź z pamięci, a gdy jej nie ma, pokazuje „GitHub ogranicza liczbę zapytań z tej sieci. Spróbuj ponownie po GG:MM.” zamiast
  samego kodu.
- Błędy natywnej instalacji niosą komunikat statusu `PackageInstaller`, widoczny w Ustawienia → Aktualizacje.
- Autokontrola: na Androidzie aplikacja liczy skrót własnego zainstalowanego APK i porównuje go z `SHA256SUMS`
  wydania odpowiadającego jej wersji — więc kopie udostępnione przez Nearby Share / Quick Share są również weryfikowane.
  Wynik widoczny w Ustawienia → Bezpieczeństwo.

## 11. Moduły Dart

Wszystkie w `lib/`; pakiet nazywa się `ripplo`.

```
main.dart, app.dart, router.dart   start (wybiera MeshBridge lub DevMesh), powłoka aplikacji i motyw, stan nawigacji zakładek / czatu
i18n.dart                          teksty interfejsu (en, pl), `t(key)`
contributors.dart                  loginy współtwórców dla karty O aplikacji
util/bytes.dart                    b64 / b64url / hex / utf8 / concat / random / base32
util/js.dart                       drobne funkcje zachowujące semantykę JavaScriptu (prawdziwość, zegar `now`, `cut`, int32), by przeportowana logika pasowała do dawnej implementacji
util/avatar.dart, qrparts.dart, schedule.dart, link_label.dart, github_cache.dart
                                   odcień i inicjały awatara, składanie kawałków animowanego QR, sloty odświeżania Ludzi (§7), etykieta medium łącza, pamięć odpowiedzi GitHuba (§10)
crypto/vault.dart                  szyfrowanie / odszyfrowanie rekordów AES-GCM kluczem bazy
crypto/db.dart                     RawStore (NativeRawStore przez most, FileRawStore, MemoryRawStore) i szyfrowany magazyn rekordów
crypto/identity.dart               wizytówka tożsamości, tag / ripploId, kodowanie / dekodowanie linku zaproszenia (§1)
crypto/attachment.dart             szyfrowanie / odszyfrowanie pliku + podział na fragmenty (§2)
crypto/call_frame.dart             szyfrowanie / odszyfrowanie ramek połączenia, okno powtórzeń (§13)
mesh/packet.dart                   kodowanie / dekodowanie pakietów, stałe (§3)
mesh/router.dart                   router w Dart (§3.1)
mesh/bridge.dart                   interfejs `Mesh` i `MeshBridge` na MethodChannel (§9)
mesh/dev_mesh.dart, dev_signal.dart  symulator desktopowy: Mesh przez UDP loopback, jawny zamiennik Signal (§15)
core/state.dart, obs.dart          reaktywny stan aplikacji (`ObsMap`, `ObsList`)
core/messenger.dart, messenger_contacts.dart, messenger_msgs.dart
                                   `Core`: profil, kontakty i weryfikacja, Ludzie, wiadomości, załączniki, grupy, przywracanie kopii
core/calls.dart, call_audio.dart   sygnalizacja i silnik połączeń, Opus na natywnych kanałach dźwięku (§13, §9.1)
core/api.dart                      fasada używana przez UI (zob. niżej)
core/diag.dart                     dziennik diagnostyczny, przekazywany do `usbLog`
services/                          updater, notifications, open_intent, deep_link, share, permissions, scheduler, range_refresh, lock, backup,
                                   ringtone, theme, prefs (motyw i język w shared_preferences), media_files (§12.5)
ui/tokens.dart, widgets.dart       tokeny projektu i wspólne widgety (docs/DESIGN.pl.md)
ui/icons.dart, avatar.dart, qr.dart, ui_state.dart
                                   ikony Lucide, widget awatara, koder i rysownik QR, stan toastów / arkuszy
components/                        arkusze, nakładki i karty (dodawanie kontaktu, nowy czat, udostępnianie, potwierdzenie, połączenie, blokada, kopia, skaner QR)
views/                             Czaty, Czat, Ludzie, Kontakt, Ustawienia, Gate (uprawnienia), Onboarding
```

`core/api.dart` (kontrakt UI), funkcje najwyższego poziomu nad jednym wspólnym `Core` i `RipploState`:
`init`, `createProfile(name)`, `setName`, `setAvatar`, `myInviteLink`, `addContactFromLink(text, via)`,
`invite`, `acceptRequest`, `declineRequest`, `verifyNearby(id)`, `verifyByQr(id, scanned)`, `markVerified(id)`,
`safetyNumber(id)`, `sendText(chatId, text)`, `sendAttachment(chatId, file, kind, ...)`, `sendTyping`,
`retry(msgId)`, `unsendMessage`, `loadMessages(chatId)`, `markRead(chatId)`, `createGroup(name, memberIds)`,
`refreshPeople()`, `searchPeople`, `startCall`, `acceptCall`, `hangUp`, `setMuted`, `deleteChat(chatId)`, `deleteContact(id)`,
`saveSettings`, `restoreBackup`, `sendDevLog`, `deleteDevLog`, `nodeOf`.

## 12. Lokalny magazyn, kopia zapasowa i blokada aplikacji

### 12.1 Magazyn natywny

Jedna baza SQLite na aplikację (Android `android.database.sqlite`, iOS systemowy `libsqlite3`), plik
`ripplo.db` w prywatnej pamięci aplikacji (iOS: Application Support, ochrona pliku
`completeUntilFirstUserAuthentication`, wyłączony z kopii iCloud):

```sql
CREATE TABLE rows (store TEXT NOT NULL, key TEXT NOT NULL, idx TEXT, value BLOB NOT NULL,
                   PRIMARY KEY (store, key));
CREATE INDEX rows_idx ON rows (store, idx);
```

`value` to dokładnie to, co zapisuje Dart: już zaszyfrowane AES-GCM przez `lib/crypto/vault.dart` kluczem bazy
(AAD `store/key`). Warstwa natywna nigdy nie widzi treści czatów. `lib/crypto/db.dart` sięga do niej przez `RawStore`: `NativeRawStore` wywołuje
`dbPut` / `dbGet` / `dbDel` / `dbKeys` / `dbAll` / `dbByIdx` (§9); `FileRawStore` (plik JSON) obsługuje desktopową sieć deweloperską, a `MemoryRawStore` testy.

IndexedDB z WebView dawnej aplikacji Vue i jego jednorazowe kopiowanie do tego magazynu już nie istnieją: aplikacja Flutter czyta tylko `ripplo.db`, a
`localStorage` też nie jest czytany (motyw i język resetują się raz, §15). Każda przyszła zmiana magazynu wychodzi z migracją — aktualizacja nigdy nie może zgubić
danych.

### 12.2 Kopia zapasowa

Kod odzyskiwania: 30 losowych cyfr (≈ 100 bitów), pokazanych jako 6 grup po 5, generowany natywnie.
`codeKey = PBKDF2-HMAC-SHA256(cyfry kodu jako ASCII, salt(16), 600000, 32)`.
Opcjonalny drugi czynnik (§12.4): `backupKey = HKDF-SHA256(ikm = codeKey | prf(32), salt, "ripplo-backup-v1", 32)`,
w przeciwnym razie `backupKey = codeKey`. `backupKey`, `salt` i opis czynnika są trzymane na urządzeniu, opakowane niebiometrycznym kluczem Keystore / Keychain,
aby kopie automatyczne działały bez nadzoru; kod też jest trzymany (opakowany), aby użytkownik mógł go zobaczyć ponownie po uwierzytelnieniu.

Plik `Ripplo-backup-YYYYMMDD-HHMM.rbk`:

```
"RIPPLOBK" | ver u8 = 1 | flags u8 (bit0 = drugi czynnik) | iterations u32 | salt(16)
[if bit0: credIdLen u16 | credId | prfSalt(32)]
frames: u32 frameLen | nonce(12) | AES-256-GCM(backupKey, plaintext ≤ 1 MiB, AAD = SHA-256(header) | index u64 | last u8)
```

Strumień jawny to rekordy `type u8 | len u32 | bytes`:
`1` meta JSON `{ "app": version, "created": ms, "ripploId" }`, `2` klucz bazy (32), `3` rekord magazynu Signal
(`keyLen u16 | key | wartość jawna`), `4` wiersz magazynu (`store | key | idx` jako UTF-8 z prefiksem długości,
potem zaszyfrowana wartość). Plik z brakującą lub nieuwierzytelnioną ostatnią ramką jest odrzucany.

Miejsca docelowe: ręcznie = systemowe „Zapisz jako” (Android `ACTION_CREATE_DOCUMENT`, iOS document picker) —
użytkownik może wybrać Dysk Google, iCloud Drive, Proton Drive, pendrive. Automatycznie = folder wybrany
raz (Android `ACTION_OPEN_DOCUMENT_TREE` z trwałym uprawnieniem, iOS zakładka security-scoped), zapisywany najwyżej raz na 24 h przy otwarciu aplikacji. Zarówno kopia automatyczna, jak i „Utwórz kopię teraz” (gdy folder jest ustawiony) zapisują
jeden plik `Ripplo-backup.rbk` i zastępują poprzedni: nowa kopia trafia najpierw do `Ripplo-backup.rbk.tmp`,
potem stary plik jest usuwany, a plik tymczasowy przemianowywany (iOS: `replaceItemAt`), więc nieudany zapis nigdy
nie niszczy ostatniej dobrej kopii. Bez folderu „Utwórz kopię teraz” otwiera „Zapisz jako” i tworzy plik ze znacznikiem czasu.
Pliki ze znacznikiem czasu z dawnych wersji są pozostawiane w spokoju.

Przywracanie (onboarding → „Przywróć z kopii”): wybór pliku → wpisanie kodu → [drugi czynnik] → warstwa natywna
czyści lokalny stan, zapisuje klucz bazy, rekordy Signal i wiersze, a aplikacja inicjalizuje stan od nowa. Ponieważ stan ratchetu Signal w kopii jest starszy niż u rozmówców, aplikacja potem odtwarza każdą sesję z zapisanej
karty kontaktu (`signalForget` + `signalAddContact`) i wysyła `{ "t": "reset" }`. Wiadomość od znanego kontaktu,
której nie da się odszyfrować, wywołuje to samo resetowanie i pokazuje „Nie udało się odszyfrować wiadomości od X — poproś o ponowne wysłanie”. Każda wiadomość aplikacji do kontaktu niesie `c` = własną kartę (b64),
dopóki kontakt nie potwierdzi jej odbioru, więc każdy kontakt ma kartę, z której można zresetować sesję.

### 12.3 Blokada aplikacji (opcjonalna)

Domyślnie wyłączona. Po włączeniu: Android `BiometricPrompt` (`BIOMETRIC_STRONG | DEVICE_CREDENTIAL`), iOS
`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` przy starcie i po 30 s w tle;
`FLAG_SECURE` / rozmyty zrzut ukrywa zawartość w przełączniku aplikacji. Podgląd kodu odzyskiwania,
ręczna kopia, przywracanie i wyłączenie blokady zawsze wymagają uwierzytelnienia, gdy istnieje blokada lub
poświadczenie urządzenia. Dane biometryczne nigdy nie opuszczają bezpiecznego sprzętu telefonu i nie są
synchronizowane; nowy telefon można przywrócić tylko kodem (i drugim czynnikiem).

### 12.4 Drugi czynnik (opcjonalny, jeszcze niezaimplementowany)

Zaplanowany; obecna wersja nie tworzy drugiego czynnika. Kopie nigdy nie ustawiają `bit0`, a przywracanie odrzuca plik, który go ma, kodem `need_factor`
(interfejs mówi, że drugi czynnik nie jest jeszcze obsługiwany w tej wersji). Decyzja dla pierwszej wersji to wyłącznie YubiKey (CTAP2 `hmac-secret`
przez `yubikit-android`); klucze dostępu (passkeys) odłożono. Poniższy tekst to projekt.

Klucz dostępu (passkey) lub klucz bezpieczeństwa obsługujący rozszerzenie WebAuthn PRF (CTAP2 `hmac-secret`): Menedżer haseł Google,
menedżer haseł działający jako dostawca poświadczeń (np. Proton Pass) albo YubiKey.
Jego wynik PRF dla `prfSalt` jest mieszany do `backupKey` (§12.2). Tworzony przy włączaniu kopii z opcją „pomiń”; system pyta, gdzie go zapisać.
Szczegóły zależą od obsługi przez dostawcę (zob. README).

### 12.5 Odszyfrowane multimedia na dysku

Obrazy są odszyfrowywane tylko w pamięci (`Image.memory`) i nigdy nie trafiają na dysk. Wideo i głos wymagają pliku dla systemowych odtwarzaczy
(`video_player`, `just_audio`), więc odszyfrowana kopia jest zapisywana w `cache/att/` (`lib/services/media_files.dart`; prywatna pamięć podręczna aplikacji, losowa 16-bajtowa nazwa hex,
rozszerzenie z typu mime) tylko na czas odtwarzania i usuwana po jego zakończeniu lub zamknięciu widoku. Nagranie głosowe też tam ląduje (jawnie,
bo nagrywarka potrzebuje pliku), dopóki nie zostanie odczytane do zaszyfrowania i wysłane, po czym jest usuwane. `wipeMediaCache()` usuwa cały katalog przy każdym starcie aplikacji,
więc awaria nie zostawia odszyfrowanych multimediów.


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

Audio: nagrywanie i odtwarzanie są natywne (`ripplo/audio`, §9.1), PCM 48 kHz mono; na Androidzie `AudioRecord` ze źródłem `VOICE_COMMUNICATION` oraz
`AcousticEchoCanceler` i `NoiseSuppressor`, jeśli telefon je ma, a do odtwarzania `AudioTrack`. W Dart `OpusCallAudio` (`lib/core/call_audio.dart`, `opus_dart`
przez FFI z biblioteką `opus_flutter`) tnie 20 ms ramki, koduje Opus 16 kb/s, trzy ramki na pakiet (około 17
pakietów i 4,5 kB/s w każdą stronę), dekoduje po stronie odtwarzania i trzyma bufor jitter 100 ms; ramki, które
stałyby w kolejce dalej niż 400 ms, są porzucane. Wersja desktopowa na Linuksie nie ma dźwięku połączeń. Raz na sekundę silnik połączenia raportuje szczytowy poziom nagranego i zdekodowanego dźwięku. Przy 4 s ciszy na lokalnym mikrofonie
(gdy nie jest wyciszony) ekran ostrzega „twój mikrofon wydaje się milczeć”; ramki, które przychodzą, ale dekodują się do ciszy, dają „dźwięk
dochodzi, ale jest cichy”; brak jakiejkolwiek ramki przez 4 s po uruchomieniu rozmowy daje „nie dotarł jeszcze żaden dźwięk”. Rozpoczęcie
lub odebranie połączenia najpierw sprawdza uprawnienie do mikrofonu i prosi o nie natywnie, zanim ruszy nagrywanie.
Koder i dekoder są odbudowywane po błędzie, a format PCM jest czytany tak, jak przyszedł, więc jedna zła ramka nie wycisza rozmowy na stałe; ekran połączenia pokazuje
liczby ramek wysłanych / odebranych / odtworzonych / błędów do diagnozy. Jeśli mikrofon milczy przez 4 s, silnik najpierw raz ponawia próbę bez przetwarzania głosu (bez usuwania echa, redukcji szumu i automatycznego
wzmocnienia), częstej przyczyny cichego nagrywania na niektórych telefonach, i dopiero potem pokazuje ostrzeżenie. Wiersz statystyk pokazuje też stan ścieżki,
stan silnika audio i liczbę przechwyconych ramek. Wyciszenie wyłącza ścieżkę, więc cisza jest nadal wysyłana i podtrzymuje łącze.
Rozmowa kończy się `lost` po 6 s bez uwierzytelnionej ramki (30 s przed pierwszą, gdy u rozmówcy może być otwarte pytanie o
mikrofon) albo gdy przez 8 s nie ma żadnego sąsiada dla połączenia. Sąsiad jest znajdowany po karcie z hello, po węźle, z którego przyszły
uwierzytelnione ramki połączenia (wiązanym przy pierwszej ramce), albo po węźle zapamiętanym przy kontakcie (`contact.node`, zapisywanym, gdy dochodzi karta hello),
więc połączenie odebrane tuż po ponownym otwarciu aplikacji, zanim wymieniono jakiekolwiek hello, nie jest przerywane.

Dzwonienie (Android, `Ringer`) idzie za ustawieniami samego telefonu, a nie za głośnością aplikacji: tryb dzwonka normalny = domyślny
dzwonek na strumieniu dzwonka (`USAGE_NOTIFICATION_RINGTONE`, w pętli) plus wibracja; tryb wibracji = tylko wibracja; tryb cichy albo Nie
przeszkadzać / każdy filtr przerw inny niż „wszystko” = ani dźwięku, ani wibracji, tylko ekran połączenia. Inne platformy, a także nieudane natywne dzwonienie, używają zapasowo
systemowego dźwięku alertu z wibracją co 2,5 s (`lib/services/ringtone.dart`).

Jeszcze nie: dzwonienie przy zamkniętej aplikacji, rozmowy przez kilka telefonów, iOS (natywna ścieżka dźwięku istnieje, ale jest nietestowana).
iOS nigdy nie zadzwoni do zamkniętej aplikacji bez pusha od Apple, a on wymaga serwera.


## 14. Powiadomienia i połączenia przy zamkniętej aplikacji (Android)

Pakiet DATA dla tego telefonu, który dochodzi, gdy strona Dart nie jest podpięta (aplikacja zamknięta lub ekran zgaszony), był dotąd zapisywany surowy
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


## 15. Budowanie, uruchamianie, testy i CI

Flutter 3.50.1 (Dart ^3.9; wersja przypięta w CI). Polecenia z katalogu głównego repozytorium:

| polecenie | co robi |
|-----------|---------|
| `flutter pub get` | pobiera zależności |
| `flutter analyze` | analiza statyczna z `flutter_lints` (CI ją uruchamia) |
| `TZ=Europe/Warsaw flutter test` | wszystkie testy jednostkowe, widgetów i golden (CI uruchamia `flutter test`). Testy wektorowe porównują Dart z `test/vectors/js_vectors.json`, wygenerowanym z dawnej implementacji JavaScript, a wektory harmonogramu są pomijane, gdy strefa czasowa to nie `Europe/Warsaw` |
| `flutter run -d linux --dart-define=RIPPLO_PROFILE=<nazwa>` | symulator desktopowy: uruchom dwie lub więcej instancji z różnymi `<nazwa>`, by zobaczyć dwa telefony. `--dart-define=RIPPLO_SOLO=true` izoluje jedną |
| `flutter build apk --release --flavor full` | APK (wydanie na GitHubie, F-Droid, sideload) |
| `flutter build appbundle --release --flavor play` | pakiet Google Play, bez `REQUEST_INSTALL_PACKAGES` |
| `cd android && ./gradlew testFullReleaseUnitTest` | natywne testy jednostkowe kryptografii Signal (CI) |
| `dart run tool/parity.dart [goldens] [ref] [out] [prefiksy]` | zgodność zrzutów ekranu, zob. niżej |

**Symulator desktopowy.** `main.dart` używa `MeshBridge` na Androidzie, iOS i w każdej wersji release; w buildach debug i profile na pulpicie używa `DevMesh`
(`lib/mesh/dev_mesh.dart`). Każda instancja zajmuje port UDP na `127.0.0.1` z zakresu 47700-47731 (32 sloty, slot początkowy to skrót z `RIPPLO_PROFILE`, brany jest następny
wolny), ogłasza się hello co 2 s, odrzuca sąsiada po 5 s ciszy i uruchamia `lib/mesh/router.dart` na wirtualnym łączu `lan` 20 000 kbps.
Ramki to datagramy `type(1) | from(32) | to(32) | payload`. Signal to jawny zamiennik `lib/mesh/dev_signal.dart` (§2), magazyn to plik
`ripplo-dev-<profil>/db.json` w systemowym katalogu tymczasowym, a każde uprawnienie wygląda na przyznane. Transporty, połączenia, aktualizacje, kopia zapasowa i blokada aplikacji nie są symulowane.

**Testy golden.** Każdy ekran i arkusz ma testy golden w `test/views/` i `test/components/` (rozmiar urządzenia 412 × 915, jasny i ciemny; czcionki z
`test/support/fonts.dart`); obrazy leżą w `test/goldens/` i są nadpisywane przez `flutter test --update-goldens`. Zrzuty ekranu aplikacji Vue są trzymane w
`test/goldens/ref/` jako wzorzec. `tool/parity.dart` porównuje każdy golden z Fluttera z jego wzorcem: piksel różni się, gdy dowolny kanał różni się o więcej niż 16, odsetek
różniących się pikseli nie może przekroczyć 1,5 % na obraz, brak wzorca lub golden to porażka, a kod wyjścia jest niezerowy przy każdej porażce. Dla każdej pary zapisuje
różnicę z czerwoną nakładką w `build/parity/`. `test/support/parity_test.dart` testuje samo narzędzie.

**CI** (`.github/workflows/build.yml`). Na tagu `v*` lub przy pushu do gałęzi `flutter` (oraz ręcznie): job `android` uruchamia `flutter pub get`, `flutter analyze`, `flutter test`,
natywne testy jednostkowe i `flutter build apk --release --flavor full`, a potem weryfikuje podpis. Push do gałęzi wysyła APK jako artefakt `android-test` (14 dni) i nic więcej;
tag wysyła artefakt `android`. Tagi uruchamiają też job `ios` (`flutter build ios --release --no-codesign`, niepodpisany IPA), job `play` (podpisany AAB, sprawdzany pod kątem braku
`REQUEST_INSTALL_PACKAGES`), potem `release` (wydanie na GitHubie z `SHA256SUMS`, potem workflow repozytorium F-Droid) i `google-play` (wysyłka na ścieżkę alpha jako
wersja robocza, tylko gdy istnieje sekret konta usługi). Materiał podpisujący pochodzi wyłącznie z sekretów GitHuba, a build tagu odmawia pracy bez keystore.

**Aktualizacja z wersji Vue.** Czaty, kontakty, stan Signal i ustawienia kopii leżą w magazynie natywnym i plikach keystore i zostają zachowane. Motyw, akcent, gradient
i język były trzymane w `localStorage` WebView, którego Flutter nie czyta, więc resetują się do domyślnych raz, przy pierwszym starcie wersji Flutter. Pamięć odpowiedzi GitHuba
odbuduje się przy następnym sprawdzeniu.
