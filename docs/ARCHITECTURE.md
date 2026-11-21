# Ripplo architecture

Ripplo is an offline-first, end-to-end encrypted mesh messenger.
Vue 3 (JS) UI + crypto in a Capacitor 8 WebView; transports and the relay router are native
(Kotlin / Swift) so phones keep relaying with the screen off.

```
┌──────────────── WebView (JS) ────────────────┐      ┌──────── native (Kotlin / Swift) ────────┐
│ Vue UI ── core/api.js ── crypto/* (Signal)   │      │ MeshEngine (foreground service on Android)│
│                  │                           │ base64│  Router  (dedupe, TTL, reverse paths)    │
│            mesh/bridge.js ───────────────────┼──────►│  Links   (best link per neighbor)        │
│  (web dev fallback: mesh/router.js +         │◄──────┤  Transports: BLE GATT, BLE L2CAP, LAN,   │
│   BroadcastChannel between browser tabs)     │events │  Wi-Fi Direct*, Wi-Fi Aware*, Multipeer** │
└──────────────────────────────────────────────┘      └──────────────────────────────────────────┘
                                                        * Android only   ** iOS only
```

Relays never see plaintext, never decrypt and never notify their user. Only the recipient's JS
decrypts.

## 1. Identity

- Signal identity key pair (Curve25519, libsignal format: public key 33 bytes, `0x05` prefix).
- `tag` = `SHA-256(identityPub33)[0..16]` — 16-byte routing address used in packet `dest`.
- `ripploId` = Crockford base32 of `tag[0..10]` → 16 chars, shown as `XXXX-XXXX-XXXX-XXXX`.
- Signal address = `new SignalProtocolAddress(ripploId, 1)` (one device per identity).
- A contact's `ripploId` MUST equal the one derived from its identity key. Anything else is rejected.

### Contact card

```json
{ "v": 1, "n": "Alice", "ik": "<b64 identity pub 33>", "rid": 1234,
  "spk": { "id": 1, "pub": "<b64>", "sig": "<b64>" } }
```
Card = name + Signal prekey bundle without one-time prekeys (X3DH works without them).

### Invite link / QR payload

`ripplo://add/<base64url(cardJSON)>.<base64url(SHA-256(cardJSON)[0..6])>`

The suffix is an integrity checksum (catches truncation / corruption). It is NOT authentication —
anyone can recompute it. Authenticity comes from verification (section 5). No server ever sees the
link. The QR code encodes the same string.

## 2. Encryption layers

1. **Signal protocol** (`@privacyresearch/libsignal-protocol-typescript`): X3DH + Double Ratchet.
   Every app message (text, attachment pointer, group update, ...) is a JSON object encrypted with
   `SessionCipher` for the recipient. Groups = client-side fan-out: the same app message is
   encrypted pairwise for every member (like early Signal groups). Voice notes, photos and videos
   are attachments.
2. **Sealed sender** (hides the sender from relays):
   `sealed = 0x01 | ephPub(32) | nonce(12) | AES-256-GCM(key, inner)`
   `key = HKDF-SHA256(ikm = X25519(ephPriv, recipientIdentityPub32), salt = recipientTag, info = "ripplo-sealed-v1", 32)`
   `inner = UTF-8 JSON { "f": senderRipploId, "t": signalMsgType (1 | 3), "b": "<b64 signal body>" }`
   The recipient decrypts with `X25519(identityPriv, ephPub)`, then runs Signal decryption for
   address `f`. For PreKey messages it checks that the identity key inside equals the one that
   derives `f`.
3. **Attachments** (Signal-style): file is encrypted once with a random AES-256-GCM key
   (`ct = nonce(12) | GCM(file)`). `ct` is split into 32 KiB chunks sent as separate DATA packets.
   The key, `SHA-256(ct)`, mime, size and chunk count travel in a Signal-encrypted pointer message
   sent **after** every chunk was ACKed. The recipient verifies the hash before decrypting.
4. **At rest**: IndexedDB values are AES-GCM encrypted with a 256-bit DB key held by the OS
   (Android Keystore-wrapped / iOS Keychain, via `RipploMesh.getDbKey()`). Web dev build: key in
   localStorage, flagged as insecure in the UI.

Limits: text ≤ 1000 characters, attachment ≤ 20 MiB (before encryption).

## 3. Mesh packet (binary, big-endian)

| off | size | field |
|-----|------|-------|
| 0   | 1    | version = `1` |
| 1   | 1    | type |
| 2   | 1    | ttl  (hops still allowed) |
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

Defaults: `TTL = 8`, seen/reverse/route entries expire after 10 min, seen-cache cap 20 000.

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
    if from != SELF and p.ttl <= 1: send DEAD_END to from; return
    q = copy(p); if from != SELF: q.ttl -= 1; q.hops += 1
    targets = DATA and routes[p.dest] alive and != from ? [routes[p.dest]] : neighbors - from
    if targets empty: deadEnd(p.id); return
    reverse[p.id].pending = len(targets); send q to each
  ACK | REPLY:
    if seen(p): return; mark seen
    r = reverse[p.dest]; if !r: return
    if ACK: routes[r.dest] = from (unless from == SELF); r.done = true
    if r.prev == SELF: deliver to JS (hops = p.hops)  else: send p (hops+1) to r.prev
  DEAD_END:
    if seen(p): return; mark seen
    r = reverse[p.dest]; if !r or r.done: return
    r.pending -= 1; if r.pending <= 0: deadEnd(p.dest)

deadEnd(id):  r = reverse[id]; r.done = true
              if r.prev == SELF: deliver DEAD_END(dest=id) to JS
              else send DEAD_END(new id, dest=id) to r.prev
```

Why messages cannot loop: every node forwards a given `id` at most once (seen-set), TTL drops
by one per hop, and duplicates are answered with DEAD_END instead of being forwarded. When every
branch dies the DEAD_ENDs aggregate back to the sender, which shows *"Contact is out of mesh range"*.
JS also gives up after 90 s without ACK/DEAD_END (links can vanish mid-flight).

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

## 6. Link-local APP messages (JSON)

- `{ "t": "hello", "card": <card> }` — sent on every new neighbor; fills the People tab "nearby"
  section and enables the nearby proof.
- `{ "t": "challenge" ... }`, `{ "t": "proof" ... }` — section 5.

## 7. People tab (mesh-wide discovery)

DISCOVER payload = `{ "t": "who" }`; every node answers with REPLY payload = its card JSON.
Refreshed automatically once every 24 h between 02:00 and 05:00 local time, or when the user taps
refresh. DISCOVER floods the whole mesh, hence the nightly schedule. A person added from here is
unverified (a relay could have swapped the card) and gets the same warning as an invite link.

## 8. Message lifecycle (what the sender sees)

`encrypting` → `sending` (handed to N neighbors; attachments show chunk progress %) →
`delivered` (ACK, "via k phones") or `out_of_range` (all branches dead-ended or 90 s timeout,
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
| `installUpdate` | `{ url, sha256 }` → `{ status }` — download, verify SHA-256 + signing cert, install |
| `requestBatteryExemption` | – (Android) |
| `checkPermissions` / `requestPermissions` | aliases `bluetooth`, `wifi`, `notifications` |

Events (`addListener`): `packet` `{ packet, from }` (from = node hex, `"self"` for deliveries of
JS-originated traffic), `neighbor` `{ node, up, medium, kbps }`, `updateProgress` `{ progress }`.

When no JS listener is attached the engine keeps packets for self in a persisted inbox (max 2000)
and shows a content-free notification *"New message"* for `0x01` payloads.

## 10. Updates and integrity

- CI (`.github/workflows/build.yml`) builds on tags `v*`, publishes `Ripplo-vX.Y.Z.apk`,
  `Ripplo-vX.Y.Z-unsigned.ipa` and `SHA256SUMS` in the GitHub release.
- The app (when online) reads `api.github.com/repos/Nahida4479/Ripplo/releases/latest`; a newer
  semver shows an update badge. Android with auto-update on: native downloads the APK, checks its
  SHA-256 against `SHA256SUMS` and its signing certificate against the installed one, then installs
  via `PackageInstaller` (silent from the second self-update on, Android 12+).
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
