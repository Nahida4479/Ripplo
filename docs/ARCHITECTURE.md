# Ripplo architecture

🇬🇧 English | [🇵🇱 Polski](ARCHITECTURE.pl.md)

Ripplo is an offline-first, end-to-end encrypted mesh messenger.
Vue 3 (JS) UI in a Capacitor 8 WebView. Signal crypto (official `libsignal`), transports and the
relay router are native (Java / Swift), so private keys never enter the WebView and phones keep
relaying with the screen off.

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

Relays never see plaintext, never decrypt and never notify their user.

## 1. Identity

- Signal identity key pair from `IdentityKeyPair.generate()` (Curve25519; public key 33 bytes, `0x05` prefix).
- `tag` = `SHA-256(identityPub33)[0..16]` — 16-byte routing address used in packet `dest`.
- `ripploId` = Crockford base32 of `tag[0..10]` → 16 chars, shown as `XXXX-XXXX-XXXX-XXXX`.
- Signal address = `SignalProtocolAddress(hex(tag), 1)` (lowercase hex, one device per identity).
- `IdentityKeyStore.isTrustedIdentity` / `saveIdentity` reject any identity whose `SHA-256(ik)[0..16]`
  differs from the address tag. Trust-on-first-use otherwise; a changed key for a known tag is impossible
  by construction (the tag is the key's hash).
- Created once on first start: registration id (14-bit random), signed prekey id 1 (EC),
  Kyber-1024 last-resort prekey id 1 (`KEMKeyPair.generate(KYBER_1024)`, signature =
  `identityPriv.calculateSignature(kyberPub.serialize())`). No one-time prekeys: there is no server
  to hand them out. `markKyberPreKeyUsed` is a no-op (last-resort key is reusable, as in Signal).

### Bundle (native, binary, big-endian) — 1776 bytes

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

### Contact card (JS) and invite link / QR

`card = 0x02 | nameLen u8 | name UTF-8 (≤ 120 bytes, ≤ 40 chars) | bundle(1776)`

`ripplo://add/<base64url(card)>.<base64url(SHA-256(card)[0..6])>` — about 2.4 KB. The QR code
encodes the same string with error correction level **L** (it does not fit M).

The suffix is an integrity checksum (catches truncation / corruption). It is NOT authentication —
anyone can recompute it. Authenticity comes from verification (section 5). No server ever sees the
link.

## 2. Encryption layers

1. **Signal protocol — official `libsignal` 0.108.5** (AGPL-3.0, by Signal). PQXDH (X25519 +
   Kyber-1024 / ML-KEM) for session setup and the SPQR triple ratchet (Double Ratchet + sparse
   post-quantum ratchet), always on. Every app message (text, attachment pointer, group update)
   is a JSON object encrypted with `SessionCipher` for the recipient. Groups = client-side fan-out
   (pairwise encryption for every member). Voice notes, photos and videos are attachments.
2. **Sealed sender** (hides the sender from relays), done natively:
   `sealed = 0x01 | ephPub(32) | nonce(12) | AES-256-GCM(key, inner)`
   `key = HKDF-SHA256(ikm = X25519(ephPriv, recipientIdentityPub32), salt = recipientTag, info = "ripplo-sealed-v2", 32)`
   `inner = 0x02 | senderTag(16) | msgType u8 (2 = SignalMessage, 3 = PreKeySignalMessage) | body`
   `ephPub` = the 32 key bytes without the `0x05` prefix (X25519 via libsignal
   `ECPrivateKey.calculateAgreement`). The recipient decrypts with its identity private key, then
   runs Signal decryption for address `hex(senderTag)`. A PreKey message whose identity key does not
   hash to `senderTag` is rejected before decryption.
3. **Attachments** (Signal-style, in JS): file is encrypted once with a random AES-256-GCM key
   (`ct = nonce(12) | GCM(file)`). `ct` is split into 32 KiB chunks sent as separate DATA packets.
   The key, `SHA-256(ct)`, mime, size and chunk count travel in a Signal-encrypted pointer message
   sent **after** every chunk was ACKed. The recipient verifies the hash before decrypting.
4. **At rest**: Signal state (identity, prekeys, sessions, identities) is stored natively as files,
   each AES-256-GCM encrypted with a key held by Android Keystore / iOS Keychain
   (`AfterFirstUnlockThisDeviceOnly`). The JS IndexedDB (messages, contacts, chats) is AES-GCM
   encrypted with the DB key from `RipploMesh.getDbKey()`.
5. **Web dev build**: `src/mesh/devSignal.js` replaces the native Signal calls with a plaintext
   stand-in so two browser tabs can exercise the UI. It provides NO security and the UI says so.

Safety number: `NumericFingerprintGenerator(5200).createFor(1, myTag, myIk, theirTag, theirIk)`
displayable 60 digits (identical on both sides, both platforms).

Nearby proof key: `K = HKDF-SHA256(X25519(myIdentityPriv, otherIk32), salt = n, info = "ripplo-proof-v1", 32)`,
`mac = HMAC-SHA256(K, "ripplo-proof-v1" | n | challengerTag | proverTag)` (native, see §5).

Limits: text ≤ 1000 characters, attachment ≤ 20 MiB (before encryption).

## 3. Mesh packet (binary, big-endian)

| off | size | field |
|-----|------|-------|
| 0   | 1    | version = `1` |
| 1   | 1    | type |
| 2   | 1    | ttl  (reserved, ignored; send 8) |
| 3   | 1    | hops (hops taken so far) |
| 4   | 16   | id   (random per packet) |
| 20  | 16   | dest |
| 36  | n    | payload |

Max packet 65 536 bytes. Types:

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

DATA payload first byte: `0x01` sealed message, `0x02` attachment chunk
(`0x02 | attId(16) | index u32 | total u32 | bytes`).

No hop limit. Defaults: seen/reverse/route entries expire after 10 min, seen-cache cap 20 000.

### 3.1 Router (identical in `src/mesh/router.js`, Kotlin and Swift)

State: `seen` set of `(type,id)`, `reverse[id] = {prev, dest, pending, done}`,
`routes[destTag] = neighbor`, `self` tag. `prev = SELF` for packets the local JS originated.

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

Why messages cannot loop: every node forwards a given `id` at most once (seen-set), so a
packet can never pass the same phone twice, and duplicates are answered with DEAD_END instead of being forwarded. When every
branch dies the DEAD_ENDs aggregate back to the sender, which shows *"Contact is out of mesh range"*.
There is no hop limit, so a message crosses any chain of phones, however long. JS also gives up
after 5 min without ACK/DEAD_END (links can vanish mid-flight).

The ACK on the way back teaches every relay `routes[dest] = neighbor`, so later packets (e.g. media
chunks) go unicast along the learned path instead of flooding.

Relays never hand relayed DATA to JS and never notify the user (requirement: no "a message passed
through your phone" spam).

Abuse limits (native): max 200 packets/s per neighbor, max 32 MiB queued per link, drop on overflow.

## 4. Links and speed selection

Every transport delivers a byte stream; frames are `u32 length | packet`. The first frame on a new
link is LINK_HELLO with the random per-process `nodeTag`. Links are grouped by `nodeTag`, so one
neighbor may have several links (e.g. BLE + LAN). On link up and every 60 s the engine sends
PING with filler (16 KiB on Wi-Fi/L2CAP media, 2 KiB on BLE GATT) and measures
`kbps = bits / rttMs`. The router always sends through the neighbor's fastest live link and falls
back to the next on failure. Before the first measurement, nominal kbps: lan 20000,
wifi-aware 20000, wifi-direct 20000, multipeer 10000, l2cap 300, ble 50.

Duplicate links of the same medium to the same node: keep the one initiated by the lower nodeTag.

| medium       | Android | iOS | interop | discovery |
|--------------|---------|-----|---------|-----------|
| `ble`        | ✓ | ✓ | ✓ | GATT service `6f2a0001-5c3e-4b7a-9d1e-2b9c6e1a0f01`; RX char `…0002` (write), TX char `…0003` (notify), PSM char `…0004` (read, u16) |
| `l2cap`      | ✓ (10+) | ✓ | ✓ | BLE L2CAP CoC, PSM read from `…0004` after GATT connect |
| `lan`        | ✓ | ✓ | ✓ | DNS-SD `_ripplo._tcp` on the current Wi-Fi/hotspot, TCP |
| `wifi-direct`| ✓ | – | – | Wi-Fi P2P DNS-SD `_ripplo._tcp`, group owner listens on TCP 47321 |
| `wifi-aware` | ✓ (8+, if hardware) | – | – | NAN service `ripplo`, TCP 47322 over the NAN data path |
| `multipeer`  | – | ✓ | – | MultipeerConnectivity service type `ripplo-mesh` |

BLE GATT is a byte stream per direction: central writes slices of `mtu-3` to RX (write with
response, ordered); peripheral notifies slices on TX. Request MTU 517.

Classic Bluetooth RFCOMM is not used: iOS apps cannot use it without MFi; L2CAP CoC is the
cross-platform Bluetooth fast path. Wi-Fi Aware on iOS 26 requires a paid-developer entitlement;
add it once the project has one.

## 5. Contacts and key verification

`verification`: `none` | `nearby` (proved over a direct link) | `qr` (in-person QR compare) |
`manual` (user vouched, e.g. compared the safety number in another messenger).

Nearby proof (link-local APP packets, never relayed):
```
A → B  { "t": "challenge", "n": <b64 32 random>, "from": A.ripploId }
B → A  { "t": "proof", "n": ..., "mac": HMAC-SHA256(K, "ripplo-proof-v1" | n | A.tag | B.tag) }
K = HKDF-SHA256(X25519(B.priv, A.pub), salt = n, info = "ripplo-proof-v1", 32)
```
Only the holder of B's private key (or A's) can compute K, so a substituted key fails.

Flow after adding a contact by link, People tab or QR:
1. Look for a direct neighbor whose APP hello card has the contact's `ripploId`; run the challenge.
   Keep trying for 60 s.
2. Success → `nearby` (or `qr` if the contact was added by scanning).
3. Failure → warning: *"Could not verify this public key. You can't be sure the person on the
   other side is who you added."* with three actions: **Verify with QR code** (scan their safety
   QR in person), **Retry over mesh**, **I'm sure it's them** (→ `manual`, confirm dialog).
4. A neighbor or People entry announcing the same display name with a different key raises a red
   *possible key substitution* warning.

Limitation (documented in-app): a nearby proof shows the key's owner is physically in range,
not who they are. An attacker who swapped a link and stands nearby passes it; QR / safety-number
comparison with the real person is the strong check.

Safety number: Signal-style, 60 digits from both identity keys (SHA-512 iterated 5200×,
`fingerprint version 0 | key | ripploId`), shown in 12 groups of 5 and as a QR.

### Profile picture

Optional, set in Settings → Profile: cropped to a 160×160 JPEG, ≤ 16 KiB, stored in `kv/profile.avatar`
(base64). It never goes into the card, QR, link, `hello` or `REPLY` (they must stay small and reach
strangers). It travels only as the field `av` of a Signal-encrypted message, so a relay never sees it:
- `av` is attached to a message to a contact whenever `contact.avSent != myAvatarVersion`
  (`SHA-256(avatar)[0..4]`, empty when none). The first message to a new contact therefore carries it,
  and the receiver shows it for whoever added them or wants to add them.
- Changing or removing the picture sends `{ "t": "avatar" }` (carrier only) to every contact; a failed
  send resets `avSent`, so the next message retries. `av: ""` removes it on the receiver.
- The receiver accepts `av` only if it is base64, ≤ 16 KiB and starts with the JPEG magic `FF D8 FF`,
  then stores `contact.avatar`; anything else is ignored.

## 6. Link-local APP messages (JSON)

- `{ "t": "hello", "card": "<b64 card bytes>" }` — sent on every new neighbor; fills the People tab "nearby"
  section and enables the nearby proof.
- `{ "t": "challenge" ... }`, `{ "t": "proof" ... }` — section 5.

## 7. People tab (mesh-wide discovery)

DISCOVER payload = `{ "t": "who" }`; every node answers with REPLY payload = its card bytes (§1).
Refreshed automatically once every 24 h between 02:00 and 05:00 local time, or when the user taps
refresh. DISCOVER floods the whole mesh, hence the nightly schedule. A person added from here is
unverified (a relay could have swapped the card) and gets the same warning as an invite link.

## 8. Message lifecycle (what the sender sees)

`encrypting` → `sending` (handed to N neighbors; attachments show chunk progress %) →
`delivered` (ACK, "via k phones") or `out_of_range` (all branches dead-ended or 5 min timeout,
with **Retry**). `failed` = local error. Incoming: shown and notified only once complete
(for attachments the pointer arrives after all chunks). Native ACKs DATA as soon as it is
persisted to the inbox, so delivery works with the screen off and the app closed.

## 9. Native plugin contract — `RipploMesh` (Capacitor)

Binary values are base64 (standard) strings; node tags are lowercase hex.

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
| `installUpdate` | `{ url, sha256, prompt? }` → `{ status }` — download, verify SHA-256 + signing cert, install. Rejects `install_permission` (before downloading) when "install unknown apps" is not allowed for Ripplo; with `prompt` it opens that settings screen |
| `requestBatteryExemption` | – (Android) |
| `checkPermissions` / `requestPermissions` | aliases `bluetooth`, `wifi`, `notifications`; the result also has `battery` (`granted` when exempt from battery optimization, Android only; not required to continue) |
| `signalInit` | → `{ bundle, ik }` — creates the identity on first call, then returns the same bundle (§1) |
| `signalAddContact` | `{ bundle }` → `{ tag }` — verifies both prekey signatures, runs `processPreKeyBundle` (PQXDH), saves the identity |
| `signalSeal` | `{ tag, plaintext }` → `{ payload }` — Signal-encrypt for `hex(tag)` then seal (§2); `payload` is the sealed bytes, used directly as the DATA payload (its leading `0x01` is the DATA kind) |
| `signalOpen` | `{ payload }` → `{ tag, ik, plaintext }` — unseal + Signal-decrypt; rejects on any mismatch |
| `signalProof` | `{ ik, n, challengerTag, proverTag }` → `{ mac }` — §2 nearby proof MAC with the own identity key |
| `signalSafetyNumber` | `{ ik }` → `{ digits }` — 60 digits (§2) |
| `signalForget` | `{ tag }` — delete the session and stored identity for that contact |

All `signal*` calls run on one serial queue in the native `SignalCore`. Errors reject with a code:
`bad_bundle`, `no_session`, `bad_message`, `untrusted_identity`.

Events (`addListener`): `packet` `{ packet, from }` (from = node hex, `"self"` for deliveries of
JS-originated traffic), `neighbor` `{ node, up, medium, kbps }`, `updateProgress` `{ progress }`.

When no JS listener is attached the engine keeps packets for self in a persisted inbox (max 2000)
and shows a content-free notification *"New message"* for `0x01` payloads.

## 10. Updates and integrity

- CI (`.github/workflows/build.yml`) builds on tags `v*`, publishes `Ripplo-vX.Y.Z.apk`,
  `Ripplo-vX.Y.Z-unsigned.ipa` and `SHA256SUMS` in the GitHub release.
- The app (when online) reads `api.github.com/repos/Nahida4479/Ripplo/releases/latest`; a newer
  semver shows an update badge. Android with auto-update on: native downloads the APK, checks its
  SHA-256 against the release hash and its signing certificate against the installed one, then installs
  via `PackageInstaller` (silent from the second self-update on, Android 12+).
- Release hashes come from the `digest` field of the release asset in the API response (fallback: the
  `SHA256SUMS` block in the release notes); `SHA256SUMS` is never fetched from the WebView because
  github.com download redirects carry no CORS headers. The current version is the native
  `versionName` (`App.getInfo()`), not the bundled `package.json` version.
- After a self-update the system kills the app. `UpdatedReceiver` (`MY_PACKAGE_REPLACED`) relaunches
  `MainActivity` only if Ripplo started that install in the last 30 min. Android 10+ may block starting an
  activity from the background, so it also posts a "Ripplo was updated. Tap to open." notification,
  removed on the next resume.
- Native install errors carry the `PackageInstaller` status message, shown in Settings → Updates.
- Self-check: on Android the app hashes its own installed APK and compares it with `SHA256SUMS` of
  the release matching its version — so copies shared with Nearby Share / Quick Share are verified
  too. Result shown in Settings → Security.

## 11. JS modules

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

`core/api.js` (UI contract):
`init()`, `createProfile(name)`, `myInviteLink()`, `addContactFromLink(text, via)`,
`addPerson(person)`, `verifyNearby(id)`, `verifyByQr(id, scanned)`, `markVerified(id)`,
`safetyNumber(id)`, `sendText(chatId, text)`, `sendAttachment(chatId, file, kind)`,
`retry(msgId)`, `loadMessages(chatId)`, `markRead(chatId)`, `createGroup(name, memberIds)`,
`refreshPeople()`, `deleteChat(chatId)`, `deleteContact(id)`.

## 12. Local storage, backup and app lock

### 12.1 Native store (replaces IndexedDB on devices)

One SQLite database per app (Android `android.database.sqlite`, iOS system `libsqlite3`), file
`ripplo.db` in app-private storage (iOS: Application Support, file protection
`completeUntilFirstUserAuthentication`, excluded from iCloud backup):

```sql
CREATE TABLE rows (store TEXT NOT NULL, key TEXT NOT NULL, idx TEXT, value BLOB NOT NULL,
                   PRIMARY KEY (store, key));
CREATE INDEX rows_idx ON rows (store, idx);
```

`value` is exactly what JS writes: already AES-GCM sealed by `src/crypto/vault.js` with the DB key
(AAD `store/key`). Native never sees chat plaintext. `src/crypto/db.js` keeps its API; on native it
calls the plugin, on the web it keeps IndexedDB.

Migration: on the first native start with an empty `rows` table, JS copies every IndexedDB record
as-is (same DB key, values stay sealed) into the native store, verifies the counts, then deletes the
IndexedDB database. Every future storage change ships with a migration — an update must never lose
data.

### 12.2 Backup

Recovery code: 30 random digits (≈ 100 bits), shown as 6 groups of 5, generated natively.
`codeKey = PBKDF2-HMAC-SHA256(code digits as ASCII, salt(16), 600000, 32)`.
Optional second factor (§12.4): `backupKey = HKDF-SHA256(ikm = codeKey | prf(32), salt, "ripplo-backup-v1", 32)`,
otherwise `backupKey = codeKey`. `backupKey`, `salt` and the factor descriptor are kept on the device
wrapped by a non-biometric Keystore / Keychain key so automatic backups run unattended; the code is
kept too (wrapped) so the user can view it again after authenticating.

File `Ripplo-backup-YYYYMMDD-HHMM.rbk`:

```
"RIPPLOBK" | ver u8 = 1 | flags u8 (bit0 = second factor) | iterations u32 | salt(16)
[if bit0: credIdLen u16 | credId | prfSalt(32)]
frames: u32 frameLen | nonce(12) | AES-256-GCM(backupKey, plaintext ≤ 1 MiB, AAD = SHA-256(header) | index u64 | last u8)
```

Plaintext stream = records `type u8 | len u32 | bytes`:
`1` meta JSON `{ "app": version, "created": ms, "ripploId" }`, `2` DB key (32), `3` Signal store
record (`keyLen u16 | key | plaintext value`), `4` store row (`store | key | idx` as
length-prefixed UTF-8, then the sealed value). A file with a missing or unauthenticated last frame is
rejected.

Destinations: manual = system "Save as" (Android `ACTION_CREATE_DOCUMENT`, iOS document picker) —
the user can pick Google Drive, iCloud Drive, Proton Drive, a USB stick. Automatic = a folder picked
once (Android `ACTION_OPEN_DOCUMENT_TREE` with a persisted permission, iOS security-scoped bookmark),
written at most once per 24 h when the app is opened; keeps the last 3 files.

Restore (onboarding → "Restore from backup"): pick file → enter code → [second factor] → native
wipes local state, writes the DB key, Signal records and rows, restarts JS. Because the Signal
ratchet state in a backup is older than the peers', JS then re-creates every session from the
contact's stored card (`signalForget` + `signalAddContact`) and sends `{ "t": "reset" }`. A message
that fails to decrypt from a known contact triggers the same reset and shows "Couldn't decrypt a
message from X — ask them to resend". Every app message to a contact carries `c` = own card (b64)
until that contact has acknowledged one, so every contact has a card to reset from.

### 12.3 App lock (optional)

Off by default. When on: Android `BiometricPrompt` (`BIOMETRIC_STRONG | DEVICE_CREDENTIAL`), iOS
`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` on start and after 30 s in the background;
`FLAG_SECURE` / blurred snapshot hides content in the app switcher. Viewing the recovery code,
manual backup, restore and turning the lock off always require authentication when a lock or
device credential exists. Biometric data never leaves the phone's secure hardware and is never
synced; a new phone can only restore with the code (and the second factor).

### 12.4 Second factor (optional)

A passkey or security key that supports the WebAuthn PRF extension (CTAP2 `hmac-secret`): Google
Password Manager, a password manager acting as a credential provider (e.g. Proton Pass), or a YubiKey.
Its PRF output for `prfSalt` is mixed into `backupKey` (§12.2). Created while enabling backups with
a "skip" option; the OS asks where to save it. Details depend on provider support (see README).
