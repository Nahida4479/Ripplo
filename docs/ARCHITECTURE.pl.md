# Architektura Ripplo

[🇬🇧 English](ARCHITECTURE.md) | 🇵🇱 Polski

Ripplo to komunikator mesh typu offline-first, z szyfrowaniem end-to-end.
Interfejs Vue 3 (JS) i kryptografia działają w WebView Capacitor 8; transporty i router przekaźnikowy
są natywne (Kotlin / Swift), dzięki czemu telefony przekazują wiadomości także przy wyłączonym ekranie.

```
┌──────────────── WebView (JS) ────────────────┐      ┌──────── native (Kotlin / Swift) ────────┐
│ Vue UI ── core/api.js ── crypto/* (Signal)   │      │ MeshEngine (foreground service on Android)│
│                  │                           │ base64│  Router  (dedupe, reverse paths)        │
│            mesh/bridge.js ───────────────────┼──────►│  Links   (best link per neighbor)        │
│  (web dev fallback: mesh/router.js +         │◄──────┤  Transports: BLE GATT, BLE L2CAP, LAN,   │
│   BroadcastChannel between browser tabs)     │events │  Wi-Fi Direct*, Wi-Fi Aware*, Multipeer** │
└──────────────────────────────────────────────┘      └──────────────────────────────────────────┘
                                                        * Android only   ** iOS only
```

Przekaźniki nigdy nie widzą treści, nigdy nie odszyfrowują i nigdy nie powiadamiają swojego użytkownika.
Odszyfrowuje wyłącznie JS odbiorcy.

## 1. Tożsamość

- Para kluczy tożsamości Signal (Curve25519, format libsignal: klucz publiczny 33 bajty, prefiks `0x05`).
- `tag` = `SHA-256(identityPub33)[0..16]` — 16-bajtowy adres routingu używany w polu `dest` pakietu.
- `ripploId` = Crockford base32 z `tag[0..10]` → 16 znaków, wyświetlane jako `XXXX-XXXX-XXXX-XXXX`.
- Adres Signal = `new SignalProtocolAddress(ripploId, 1)` (jedno urządzenie na tożsamość).
- `ripploId` kontaktu MUSI być równy temu wyliczonemu z jego klucza tożsamości. Wszystko inne jest odrzucane.

### Wizytówka kontaktu

```json
{ "v": 1, "n": "Alice", "ik": "<b64 identity pub 33>", "rid": 1234,
  "spk": { "id": 1, "pub": "<b64>", "sig": "<b64>" } }
```
Wizytówka = imię + pakiet kluczy (prekey bundle) Signal bez jednorazowych prekeyów (X3DH działa bez nich).

### Link zaproszenia / zawartość kodu QR

`ripplo://add/<base64url(cardJSON)>.<base64url(SHA-256(cardJSON)[0..6])>`

Przyrostek to suma kontrolna integralności (wychwytuje obcięcie / uszkodzenie). NIE jest to uwierzytelnienie —
każdy może ją przeliczyć. Autentyczność zapewnia weryfikacja (sekcja 5). Żaden serwer nigdy nie widzi
linku. Kod QR zawiera ten sam ciąg znaków.

## 2. Warstwy szyfrowania

1. **Protokół Signal** (`@privacyresearch/libsignal-protocol-typescript`): X3DH + Double Ratchet.
   Każda wiadomość aplikacji (tekst, wskaźnik załącznika, aktualizacja grupy, ...) to obiekt JSON szyfrowany
   przez `SessionCipher` dla odbiorcy. Grupy = fan-out po stronie klienta: ta sama wiadomość aplikacji jest
   szyfrowana parami dla każdego członka (jak we wczesnych grupach Signal). Wiadomości głosowe, zdjęcia i filmy
   są załącznikami.
2. **Sealed sender** (ukrywa nadawcę przed przekaźnikami):
   `sealed = 0x01 | ephPub(32) | nonce(12) | AES-256-GCM(key, inner)`
   `key = HKDF-SHA256(ikm = X25519(ephPriv, recipientIdentityPub32), salt = recipientTag, info = "ripplo-sealed-v1", 32)`
   `inner = UTF-8 JSON { "f": senderRipploId, "t": signalMsgType (1 | 3), "b": "<b64 signal body>" }`
   Odbiorca odszyfrowuje przez `X25519(identityPriv, ephPub)`, a następnie uruchamia deszyfrowanie Signal dla
   adresu `f`. Dla wiadomości PreKey sprawdza, czy zawarty w niej klucz tożsamości jest tym, z którego
   wyprowadzono `f`.
3. **Załączniki** (w stylu Signal): plik jest szyfrowany raz losowym kluczem AES-256-GCM
   (`ct = nonce(12) | GCM(file)`). `ct` jest dzielony na fragmenty po 32 KiB wysyłane jako osobne pakiety DATA.
   Klucz, `SHA-256(ct)`, typ mime, rozmiar i liczba fragmentów podróżują w wiadomości-wskaźniku zaszyfrowanej
   protokołem Signal, wysyłanej **po** potwierdzeniu (ACK) każdego fragmentu. Odbiorca weryfikuje skrót przed odszyfrowaniem.
4. **Dane w spoczynku**: wartości w IndexedDB są szyfrowane AES-GCM 256-bitowym kluczem bazy danych, który przechowuje system
   (opakowany Android Keystore / iOS Keychain, przez `RipploMesh.getDbKey()`). W wersji webowej do developmentu: klucz w
   localStorage, oznaczony w interfejsie jako niebezpieczny.

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
   stronie to ta, którą dodałeś.”* z trzema akcjami: **Zweryfikuj kodem QR** (zeskanuj osobiście jej QR
   bezpieczeństwa), **Ponów przez sieć**, **Jestem pewien, że to ta osoba** (→ `manual`, okno potwierdzenia).
4. Sąsiad lub wpis w Ludziach ogłaszający tę samą nazwę wyświetlaną z innym kluczem wywołuje czerwone
   ostrzeżenie *możliwa podmiana klucza*.

Ograniczenie (opisane w aplikacji): dowód bliskości pokazuje, że właściciel klucza jest fizycznie w zasięgu,
a nie kim jest. Atakujący, który podmienił link i stoi w pobliżu, go przejdzie; porównanie QR / numeru bezpieczeństwa
z prawdziwą osobą to mocna weryfikacja.

Numer bezpieczeństwa (safety number): w stylu Signal, 60 cyfr z obu kluczy tożsamości (SHA-512 iterowany 5200×,
`fingerprint version 0 | key | ripploId`), wyświetlany w 12 grupach po 5 oraz jako QR.

## 6. Wiadomości APP link-local (JSON)

- `{ "t": "hello", "card": <card> }` — wysyłana do każdego nowego sąsiada; wypełnia sekcję „W pobliżu” w zakładce Ludzie
  i umożliwia dowód bliskości.
- `{ "t": "challenge" ... }`, `{ "t": "proof" ... }` — sekcja 5.

## 7. Zakładka Ludzie (wykrywanie w całej sieci mesh)

Payload DISCOVER = `{ "t": "who" }`; każdy węzeł odpowiada payloadem REPLY = JSON swojej wizytówki.
Odświeżane automatycznie raz na 24 h między 02:00 a 05:00 czasu lokalnego albo gdy użytkownik stuknie
odśwież. DISCOVER zalewa całą sieć mesh, stąd nocny harmonogram. Osoba dodana stąd jest
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
| `installUpdate` | `{ url, sha256 }` → `{ status }` — download, verify SHA-256 + signing cert, install |
| `requestBatteryExemption` | – (Android) |
| `checkPermissions` / `requestPermissions` | aliases `bluetooth`, `wifi`, `notifications` |

Zdarzenia (`addListener`): `packet` `{ packet, from }` (from = węzeł w hex, `"self"` dla dostarczeń
ruchu pochodzącego z JS), `neighbor` `{ node, up, medium, kbps }`, `updateProgress` `{ progress }`.

Gdy nie ma podłączonego listenera JS, silnik trzyma pakiety dla siebie w trwałej skrzynce (inbox, maks. 2000)
i pokazuje pozbawione treści powiadomienie *„Nowa wiadomość”* dla payloadów `0x01`.

## 10. Aktualizacje i integralność

- CI (`.github/workflows/build.yml`) buduje na tagach `v*` i publikuje `Ripplo-vX.Y.Z.apk`,
  `Ripplo-vX.Y.Z-unsigned.ipa` oraz `SHA256SUMS` w wydaniu na GitHubie.
- Aplikacja (gdy jest internet) odczytuje `api.github.com/repos/Nahida4479/Ripplo/releases/latest`; nowszy
  semver pokazuje plakietkę aktualizacji. Android z włączoną automatyczną aktualizacją: warstwa natywna pobiera APK, sprawdza jego
  SHA-256 względem `SHA256SUMS` oraz jego certyfikat podpisu względem zainstalowanego, a następnie instaluje
  przez `PackageInstaller` (po cichu od drugiej samoaktualizacji, Android 12+).
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
