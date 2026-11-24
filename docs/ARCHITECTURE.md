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

`ripplo://add/<base64url(card)>.<base64url(SHA-256(card)[0..6])>` — about 2.4 KB. A single QR for it would be version 40
(177 × 177 modules), which no phone camera reads reliably, so the QR is an animated sequence of frames (error correction **L**):
the link is cut into pieces of 420 characters, each shown as `ripplo://p/<set>.<i>.<n>.<piece>` (`set` = base64url of
SHA-256(link)[0..6]; about 6 frames, QR version 13, 69 × 69 modules) and the frames repeat every 700 ms. The scanner collects pieces
in any order (up to 20 per set, 4 sets in flight, repeats ignored), joins them when all are present, checks the set id against
SHA-256 of the result and only then handles the link as if it had been pasted. A mismatching set is discarded with a checksum error.

**Shareable invite ("Invite a friend").** The share button sends the text plus the same link in web form,
`https://nahida4479.github.io/Ripplo/add/#<same payload>` (`/pl/add/#…` for Polish), with a fresh single-use token each time. The payload is in the
fragment, which the browser never sends to the site, so GitHub Pages learns nothing. The page validates the shape, shows no name from the
card (it is unauthenticated text), and offers *Open in Ripplo* (`ripplo://add/…`), *Copy invite* and the download/SideStore guide. Sideloaded builds
have no install referrer and no universal links (those need a domain root and a paid Apple team), so after installing the person opens the
same link again or pastes it under *Add contact → Paste link*. `parseLink` accepts both forms, only for that exact site. A link opened
before the profile exists is kept and offered once onboarding ends. Adding is the usual unverified contact (nearby proof, QR or manual verification later).
The verification QR (60 digits) stays a single small code.

The suffix is an integrity checksum (catches truncation / corruption). It is NOT authentication —
anyone can recompute it. Authenticity comes from verification (section 5). No server ever sees the
link.

### Single-use invite links

Each time the "My code" tab is shown (and each `myInviteLink()` call) a new random 8-byte token is issued and the link becomes
`ripplo://add/<card>.<checksum>.<token>` (token = 11 base64url characters; a link without a token still parses). The issuer keeps
up to 30 unused tokens (`kv/tokens`, oldest dropped). The person who scans the link remembers the token on the new contact and the
first messages to the issuer carry it as `tk` next to the card, until the issuer has answered once. The issuer redeems a token once:
the sender is then trusted as someone the issuer handed the link to (`addedVia: "link"`, so calls and media are accepted, §6.1). A token
that is unknown or already used by someone else earns nothing, and that sender stays a stranger who wrote first. A repeat of the same
token by the same sender is harmless. The link is therefore a one-time key, not an access list: forwarding it gives the second
person no trust, only the first person to use it.

Scanning or opening a link (`qr`, `link`) also sends one small sealed profile message to the issuer at once, carrying the card and the token, so the issuer
sees the scanner in their contacts straight away instead of after the first chat message. If the issuer is out of range it is not retried; the card then
rides on the first real message as before.

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

**Compatibility between versions.** Phones of different versions must keep seeing each other. Rules: wire changes are additive; unknown
DATA/APP payload tags, message types, JSON fields and packet types are ignored, never fatal; a frame with an unknown packet version is
skipped without closing the link (only a malformed length closes it); `LINK_HELLO` carries the node tag in its first 16 bytes and anything after
them is ignored; discovery identifiers (BLE UUIDs, `_ripplo._tcp`, Multipeer type) never change. A neighbor whose `hello` card this
version cannot read stays a neighbor and is shown as "Update needed" in Settings, so a version gap is visible instead of silent.

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
after 60 s without ACK/DEAD_END (links can vanish mid-flight); attachment chunks wait 20 s and are re-sent up to 4 times with fresh packet ids.

The ACK on the way back teaches every relay `routes[dest] = neighbor`, so later packets (e.g. media
chunks) go unicast along the learned path instead of flooding.

Relays never hand relayed DATA to JS and never notify the user (requirement: no "a message passed
through your phone" spam).

Abuse limits (native): max 200 packets/s per neighbor, max 32 MiB queued per link, drop on overflow.

## 4. Links and speed selection

Every transport delivers a byte stream; frames are `u32 length | packet`. The first frame on a new
link is LINK_HELLO with the random per-process `nodeTag`. Links are grouped by `nodeTag`, so one
neighbor may have several links (e.g. BLE + LAN). On link up and every 5 s (every 15 s on BLE) the engine sends
PING with filler (16 KiB on Wi-Fi/L2CAP media, 2 KiB on BLE GATT) and measures
`kbps = bits / rttMs`. The router always sends through the neighbor's fastest live link and falls
back to the next on failure. Before the first measurement, nominal kbps: lan 20000,
wifi-aware 20000, wifi-direct 20000, multipeer 10000, l2cap 300, ble 50.

A link is closed when no byte at all has arrived for more than 30 s on two consecutive 5 s checks. Any received byte counts, so a
long transfer never trips it. A link that has been silent for more than 12 s is tried only after the neighbor's other links, so a dead Wi-Fi link no longer swallows packets while BLE would still work. Without this a link whose peer vanished without closing the socket stayed in the neighbor list, the
router kept unicasting along the route learned from an earlier ACK, and messages ended as "out of range" with the phones side by side.
Closing it clears the routes through it, so the next DATA floods again.
Android LAN retries a known peer every 4 s and a failed service resolve up to 5 times, so the fast link comes up within seconds instead of a minute.

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

**BLE Coded PHY (Android only, always on).** On a phone that reports
`isLeCodedPhySupported()` and `isLeExtendedAdvertisingSupported()`, the node also starts an extended advertising set on the Coded PHY
(connectable, same service UUID, high TX power) and runs two parallel scans: a 1M scan and a dedicated Coded-only scan (`setLegacy(false)`), so the Coded PHY gets the whole scan window instead of sharing it with 1M and is found at the edge of its range, before 1M is audible. A scan hit carries its primary PHY; a coded hit is connected with
`PHY_LE_CODED_MASK` (long range, 125 / 500 kbit/s), a 1M hit with `PHY_LE_1M_MASK`. If a 1M hit for the same address was seen in the last 20 s the coded
hit is ignored (1M is faster). The PHY of a client link is read with `readPhy()` and shown in the developer details. There is no switch: the developer card only shows whether the phone supports it.
iOS has no PHY selection in CoreBluetooth, so it only ever uses 1M.

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

### Changing the display name

Settings → Profile → Change name. The card (and so the invite link, QR, `hello` and `REPLY`) is rebuilt
with the new name and `hello` is re-sent to current neighbors. Contacts learn the name only from an
authenticated, Signal-encrypted message: field `nm` is attached to a message whenever
`contact.nameSent != myName`, and `{ "t": "profile" }` (carrier only) goes to every contact right away;
a failed send resets `nameSent`. The receiver applies `nm` after `cleanName` (≤ 40 chars) and re-runs
the same-name conflict check. Names inside cards are NOT signed, so a name from a card, `hello` or
`REPLY` never overrides the name of an existing contact. The `ripploId` and keys do not change.

### Verification memory, always-on checks and hints

- Verification is never inherited. A contact added again (for example by link after deleting it) starts as not verified and is proven over a
  direct link again, because a link or card on its own cannot show that the key was not swapped.
- A nearby proof is tried for every new contact (also one who wrote first) and again whenever a neighbor whose card matches an
  unverified contact shows up (at most every 30 s), as long as the contact is not a pending request.
- When you verify someone, they get `vf` (nearby / qr / manual) in the next message, plus an immediate `{ "t": "profile" }`. The
  receiver stores it as `peerVerified` and shows "X already verified your key" as a hint only: a claim from the key under test proves
  nothing, so it never changes the receiver's own verification state. If a contact whose card you already have sends the card again
  after you had been acknowledged, they lost you (deleted and re-added); `avSent`, `nameSent` and `vfSent` are reset and the profile
  is pushed again. Strangers who only wrote first (`incoming`, never replied to) get none of this.

### Unsending a message

Long-press (or right-click, or "Unsend" after tapping the bubble) on your own message. `{ "t": "unsend", "id": <wire id>, "g"? }` goes
to every recipient, and the message disappears locally at once, including the photo blob. The receiver accepts it only for the sender's
own messages (the local id is `senderId.wireId`, the sender is authenticated by Signal), deletes the message and its blob, clears the
quoted excerpt in replies it can see, and remembers the id in `kv/unsent` (1000 entries) so a message that arrives after its unsend is
dropped. Undelivered unsends stay in `kv/unsends` and are retried on start and whenever a neighbor appears. Notifications already shown
cannot be recalled.

### Replies and captions

A `msg` or `att` message may carry `re = { id, who, text?, kind? }`: `id` is the wire id of the quoted message, `who` the
ripploId of its author, `text` an excerpt of at most 120 characters, `kind` image / video / voice for media. The receiver
validates all four fields and drops a malformed `re` while keeping the message. It maps the reference to the local message id
(`id` for its own messages, `who.id` for everyone else's) so a tap on the quote scrolls to the original. The excerpt is whatever the
sender declares, as in any messenger. An `att` pointer may also carry `text`, a caption of at most 1000 characters, shown under the
media. A caption or reply never changes what is allowed: the media gating of section 6.1 still applies.

### Voice messages

Recorded with `MediaRecorder` (`audio/webm;codecs=opus`, else `audio/mp4`, `audio/ogg`), 250 ms slices. A live
level meter (WebAudio analyser) feeds both the recording bars and `wave`, up to 64 bytes (40 used), each
0-255 relative to the loudest sample. The real duration is measured, not read from the Blob. The pointer message
carries `duration` (s, ≤ 3600) and `wave` (base64, ≤ 96 chars); the receiver validates both and draws the bars from
`wave`. A recording shorter than ~800 bytes or with peak < 0.02 is not sent ("No sound was recorded").

### Profile picture

Optional, set in Settings → Profile: cropped to a 160×160 JPEG, ≤ 16 KiB, stored in `kv/profile.avatar`
(base64). It never goes into the card, QR, link, `hello` or `REPLY` (they must stay small and reach
strangers). It travels only as the field `av` of a Signal-encrypted message, so a relay never sees it:
- `av` is attached to a message to a contact whenever `contact.avSent != myAvatarVersion`
  (`SHA-256(avatar)[0..4]`, empty when none). The first message to a new contact therefore carries it,
  and the receiver shows it for whoever added them or wants to add them.
- Changing or removing the picture sends `{ "t": "profile" }` (carrier only) to every contact; a failed
  send resets `avSent`, so the next message retries. `av: ""` removes it on the receiver.
- The receiver accepts `av` only if it is base64, ≤ 16 KiB and starts with the JPEG magic `FF D8 FF`,
  then stores `contact.avatar`; anything else is ignored.

## 6. Link-local APP messages (JSON)

- `{ "t": "hello", "card": "<b64 card bytes>", "r": 1? }` — sent on every new neighbor; fills the People tab "nearby"
  section and enables the nearby proof. `r` = "I do not have your card yet, answer": the receiver replies with a hello
  without `r`. A sender that still lacks the neighbor's card retries with `r` after 3, 6, 12 … up to every 60 s for as long as the neighbor stays without a card, and a hello that
  arrives before the neighbor event is cached per node, so discovery is symmetric. When the user is hidden (below),
  hellos are sent only to neighbors whose card belongs to a contact (one answer per link, so two hidden contacts
  do not ping-pong).
- `{ "t": "challenge" ... }`, `{ "t": "proof" ... }` — section 5.

## 6.1 Invitations (People tab)

Instead of adding a stranger directly, "Invite" sends a request; the other person accepts or declines.
Everything is Signal-encrypted; the card rides along as the usual `c` piggyback.
- Sender: stores a contact with `request: "out"` (no chat yet) and sends `{ "t": "invite" }`. A failed
  delivery sets `inviteFailed` and the row offers Retry.
- Receiver: an `invite` from an unknown sender creates a contact with `request: "in"` and no chat, plus a
  notification. The number of pending requests is unlimited (the 20-person limit applies only to searching). From a `request: "in"` contact every message except `invite`
  is dropped. Chats tab → "Requests" (under the search field) shows Accept / Decline.
- Accept: the request flag is cleared, the chat is created, a nearby verification starts, `{ "t": "accept" }` is sent.
  Decline: `{ "t": "decline" }` is sent, then the contact and its session are deleted; the sender removes the
  pending contact. Any other message from a `request: "out"` contact, or a mutual `invite`, counts as acceptance.
- Contacts with a request flag are hidden from New chat, cannot be put in groups, never receive profile pushes (`profile`,
  `hello` re-sends) and get a bare `{ "t": "decline" }` without card, name or photo. Writing to someone you only invited
  is refused, and scanning the QR or opening the link of someone who invited you accepts the request.
  Anyone not yet in your contacts can still open a normal chat by writing first (QR/link flow); they can send text,
  but no call rings (§13) and no media pointer is accepted until you have written back. The mirror rule holds for the sender:
  `sendAttachment` in a direct chat throws `media_locked` until the other person has answered (`cardAck`), unless they wrote
  first (`addedVia: "incoming"`); text is always allowed. Groups are not gated.

## 7. People tab (mesh-wide discovery)

DISCOVER payload = `{ "t": "who" }`; every node answers with REPLY payload = its card bytes (§1).
Settings → Profile → "Visible in Find people" (on by default). Turning it off also sends link-local `{ "t": "bye" }` to neighbors that are not
contacts, which drop the card they hold for you (contacts keep it), and an `invite` from a stranger is ignored while hidden. Off: DISCOVER is not answered (the node still
forwards it) and hello is sent only to accepted contacts (§6). Limits: a neighbor that replays a contact's public card gets your
hello back, so presence is not hidden from an active attacker, and two hidden contacts do not find each other nearby (neither
sends first), so they cannot verify nearby or call.

DISCOVER payload: `{ "t": "who", "h"?: n, "lo"?: n, "q"?: hash }`. `h` / `lo` = answer only when the distance `d`
(links from the requester, `packet.hops + 1`) satisfies `lo < d <= h`; `q` = `b64url(SHA-256("ripplo-find-v1\0" | norm)[0..8])`
where `norm` is the NFKC-lowercased, whitespace-collapsed name, or the ripploId without dashes in upper case; a node
answers only when `q` equals the hash of its own name or id. Searching therefore needs the exact full name or id. The hash is short and unsalted, so it hides the name only from casual
observers: whoever guesses the name (or already holds the card from an earlier REPLY, for an id) can match it. It is not a
privacy guarantee. The requester also checks every reply against the query.
The list of an automatic or manual refresh holds at most 20 people and is searched in rings (h = 1, 3, 8, then
unbounded; each ring is a separate DISCOVER, the next one only when fewer than 20 were found). Inside the list the
nearest win: when it is full, a reply with fewer hops replaces the farthest person and the list stays sorted by hops.
A name search keeps at most 50 matches, shows them instead of the list, and clearing it restores the previous list.

Refreshed automatically once a night, or when the user taps refresh. DISCOVER floods the whole mesh, hence
the schedule: the 02:00-05:00 local window is cut into 720 slots of 15 s and each phone owns the slot
`parseInt(tag[0..4 bytes]) mod 720` (stable, so phones scan one after another instead of all at once). A phone that
was asleep at its slot scans as soon as the app wakes inside the window, at most once per 20 h. The time of the last scan is stored (`kv/peopleRefreshedAt`), so the header
shows it and the 20 h limit holds across restarts.
The search ends after 30 s, or earlier when the aggregated DEAD_END has arrived and no REPLY came for 10 s
(a leaf phone dead-ends immediately but its REPLY is built by JS a moment later, so a dead end alone must not
end the search), or at once when the DISCOVER reached no neighbor. A person added from here is
unverified (a relay could have swapped the card) and gets the same warning as an invite link.

## 8. Message lifecycle (what the sender sees)

`encrypting` → `sending` (handed to N neighbors; attachments show chunk progress %) →
`delivered` (ACK, "via k phones") or `out_of_range` (all branches dead-ended or 60 s timeout,
with **Retry**). `failed` = local error. Incoming: shown and notified only once complete
(for attachments the pointer arrives after all chunks). Native ACKs DATA as soon as it is
persisted to the inbox, so delivery works with the screen off and the app closed.
While the mesh runs, Android holds a partial wake lock, a Wi-Fi lock and a multicast lock (released on stop), so the CPU, Wi-Fi radio and mDNS multicast stay
awake with a dimmed or off screen; without them DNS-SD discovery and open links stall until the screen turns on.
When a contact's hello arrives (it came back into range or switched link), its `out_of_range` and `failed` messages are re-sent
automatically (at most every 15 s per contact).

**Typing indicator.** While the composer has text, the app sends `{ "t": "typing", "ts", "g"? }` at most every 3 s, Signal-sealed,
only to contacts that have replied and are direct neighbors. It travels as an APP packet `[2] + sealed`, so it is never stored in the
inbox or notified, and Android drops it while the UI is detached. The receiver shows three animated dots in that chat for 5 s (or until the
message arrives), ignores it from anyone who is not an accepted contact, and ignores one older than 5 s.

## 9. Native plugin contract — `RipploMesh` (Capacitor)

Binary values are base64 (standard) strings; node tags are lowercase hex.

| method | args → result |
|--------|---------------|
| `start` | `{ selfTag }` → `{ nodeTag }` — starts transports + background service |
| `stop` | – |
| `send` | `{ packet }` → `{ neighbors }` — JS-originated DATA/DISCOVER/REPLY (`from = SELF`) |
| `sendApp` | `{ node, payload }` — link-local APP packet to one neighbor |
| `getNeighbors` | → `{ neighbors: [{ node, medium, kbps, rttMs, links: [{medium,kbps,rttMs,outbound}], seen: [medium] }] }` — `seen` = media on which the neighbor was discovered in the last 2 min (LAN, Wi-Fi Direct, Wi-Fi Aware) without an open link; the People tab shows them as dimmed chips without a check |
| `devConnect` / `devDisconnect` | Developer mode: `{ node, spec }` → `{ started }` forces a connection attempt to a neighbor on one medium (`lan`, `wifi-direct`, `wifi-aware`, `ble:1m`, `ble:coded`), ignoring existing links and initiator rules (BLE connects to recent scan hits, since a scan hit has no node tag); `{ node, medium }` closes that medium's links |
| `getBleCaps` | → `{ coded, extended }` (Coded PHY / extended advertising support only, no switch) |
| `usbLog` | `{ text }` → `{ usb }`. Writes the text to logcat (tag `ripplo`) only while the phone is plugged in over USB with USB debugging enabled; otherwise does nothing and returns `usb: false`. Every JS diagnostic line and the "send logs" dump go through it, so a developer with `adb logcat` reads them without any message leaving the phone. When `usb` is true "send logs" skips the recipient |
| `getDiag` / `clearDiag` / `getTransports` | Android developer mode: the in-memory diagnostic log (600 lines, same lines as logcat tag `ripplo`), clear it, and `{ transports: [{ name, running, unsupported }] }` |
| `drainInbox` | → `{ packets: [{ packet, from }] }` — packets received while JS was not attached |
| `getDbKey` | → `{ key }` 32 bytes, created once, stored with Keystore / Keychain |
| `selfHash` | → `{ sha256 }` hex of the installed APK (Android only) |
| `fromPlay` | → `{ play }` true when the installer package is `com.android.vending` (Android). Then JS skips update checks and the integrity check, turns `setAutoUpdate` off and Settings → Updates shows only the current version (§10) |
| `installUpdate` | `{ url, sha256, prompt? }` → `{ status }` — download, verify SHA-256 + signing cert, install. Rejects `install_permission` (before downloading) when "install unknown apps" is not allowed for Ripplo; with `prompt` it opens that settings screen |
| `requestBatteryExemption` | – (Android) |
| `startRing` / `stopRing` | – (Android) — ring and vibrate an incoming call following the system sound settings (§13) |
| `takeShare` | → `{ share? }` — pending Android share-sheet content, cleared after reading |
| `setAutoUpdate` | `{ enabled }` — Android: stores the setting and schedules / cancels the background update job (§10) |
| `checkPermissions` / `requestPermissions` | aliases `bluetooth`, `wifi`, `notifications`, `microphone` (Android `RECORD_AUDIO`, requested explicitly with the others and again before a call, not required to enter the app); the result also has `battery` (`granted` when exempt from battery optimization, Android only; not required to continue) |
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
JS-originated traffic), `neighbor` `{ node, up, medium, kbps }`, `updateProgress` `{ progress }`, `share` `{}` (a share arrived, call `takeShare`).

Share target (Android): `MainActivity` accepts `ACTION_SEND` for `text/plain`, `image/*`, `video/*`, `audio/*`. The
plugin reads it on start and on `onNewIntent`, accepts only `content://` URIs of other apps (never `file://` or
Ripplo's own provider), copies the stream (≤ 20 MiB) into `cache/share` and keeps one pending share;
`takeShare` → `{ share?: { kind: text|image|video|voice, text | mime + path } }` returns and clears it. JS shows
"Send to…" (chats and groups, not pending requests) once the app is unlocked; picking a chat sends the text or
attachment right away and opens that chat. Nothing is sent without that pick. iOS has no share extension yet.

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
- Background updates (Android, setting "Update automatically", on by default): `UpdateJobService`
  (`JobScheduler`, every 6 h, unmetered network, battery not low, persisted over reboot; re-scheduled by
  `UpdatedReceiver`) runs `UpdateEngine.background` in native code even when the app is closed. It skips
  while the app is in the foreground, reads the latest release, and when it is newer than the installed
  `versionName` downloads the APK, verifies SHA-256 and signing certificate and installs via
  `PackageInstaller`, once per version (`attempted`) and gives up on a version after 3 failed attempts. It
  re-checks that the app is still in the background right before the install. Notices use their own
  "Updates" channel. Without the "install unknown apps" permission it only
  posts a notification "Ripplo X is available. Open the app to update." (once per version). If the system
  asks for confirmation (`STATUS_PENDING_USER_ACTION`) with no UI around, `InstallReceiver` posts
  "Update ready. Tap to install." whose tap opens the system confirmation.
- Google Play build (`./gradlew bundlePlay`, CI job `play`): `src/play/AndroidManifest.xml` removes `REQUEST_INSTALL_PACKAGES`. When `fromPlay` is true the app never contacts GitHub for updates or integrity and hides everything in Updates except the current version; Play delivers updates.
- In the app: on start and on resume (at most every 10 min) JS checks for a release; when one is newer it
  shows a dialog "Update X available. Update now? / Later" (at most once per 6 h), regardless of the
  automatic-update setting. Android installs from the dialog; other platforms open the release page.
- After a self-update the system kills the app. `UpdatedReceiver` (`MY_PACKAGE_REPLACED`) relaunches
  `MainActivity` after every update of the package. Android 10+ may block starting an
  activity from the background, so it also posts a "Ripplo was updated. Tap to open." notification,
  removed on the next resume.
- Only one install runs at a time: native rejects a second `installUpdate` with `busy`, and the UI disables
  Install while checking or installing (two parallel downloads shared `update.apk` and made the progress jump).
- The GitHub API allows only 60 unauthenticated requests per hour per IP, shared by every phone on the same network, so the app keeps each
  answer in `localStorage` (`gh:<url>`, fresh for 30 min; "Check now" accepts a minute-old answer; the integrity lookup is fresh for a day)
  and revalidates stale ones with `If-None-Match` (a 304 costs nothing against the limit). On a 403 or 429 it stores a back-off until
  `x-ratelimit-reset` (at least a minute), serves the cached answer meanwhile and, if there is none, shows "GitHub is limiting requests from this
  network. Try again after HH:MM." instead of the bare status.
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
written at most once per 24 h when the app is opened. Both automatic and "Back up now" (when a folder is set) write
the single file `Ripplo-backup.rbk` and replace the previous one: the new copy is written to `Ripplo-backup.rbk.tmp`
first, then the old file is deleted and the temp file renamed (iOS: `replaceItemAt`), so a failed write never
destroys the last good backup. Without a folder "Back up now" opens "Save as" and creates a timestamped file.
Timestamped files from older versions are left alone.

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


## 13. Voice calls (direct links only, Android first)

Signalling is a Signal-encrypted message (normal DATA path, from a contact that is not a pending request):
`{ "t": "call", "k": "offer"|"accept"|"decline"|"end", "id": <b64 8 bytes>, "key"?: <b64 32 bytes>, "r"?: "busy" }`.
Only `offer` carries `key`, a random 32-byte call key, so relays never see it. The callee rings for 45 s
(`missed` afterwards); `decline` with `r: "busy"` answers an offer while already in a call (two phones calling each
other at once both get "Busy"). An offer carries `ts`; one older than 120 s is ignored (an offer that sat in the inbox does not ring late). Calls are accepted only
from contacts you added, accepted, or have written to; a stranger who only wrote first cannot ring you. Both sides write a
system line in the chat (missed call, declined, duration).

Media goes as link-local APP packets to the neighbor whose hello card is the contact, so the call needs a direct
link (LAN, Wi-Fi Direct/Aware, L2CAP, BLE); the Call button says so otherwise. Payload (first byte `0x01`, JSON APP
payloads start with `{`):
`0x01 | callId(8) | seq u32 | AES-256-GCM(callKey, nonce = role(1) 0 0 0 | seq u32 | 0 0 0 0, AAD = callId | seq, frames)`
with `role` 0 = caller, 1 = callee (so the two directions never reuse a nonce) and
`frames = count u8 | (len u16 | opus)*`, at most 8 frames of at most 1275 bytes. The receiver decrypts with the
peer's role, then accepts each `seq` once inside a 64-packet window; anything unauthenticated, from another call, a replay or
malformed is dropped silently.

Audio (JS, WebCodecs): microphone with echo cancellation, noise suppression and AGC at 48 kHz, an `AudioWorklet`
(`public/call-worklet.js`) cuts 20 ms frames, `AudioEncoder` Opus 16 kb/s, three frames per packet (about 17
packets and 4.5 kB/s each way), `AudioDecoder` and a 100 ms jitter buffer on the playback side; frames that would
queue more than 400 ms ahead are dropped. Once a second the call engine reports the peak level of the captured and of the decoded audio. For 4 s of silence on the local microphone
(while not muted) the screen warns "your microphone seems silent"; frames arriving but decoding to silence gives "sound is arriving but silent";
no frame at all 4 s after the call went live gives "no sound has arrived yet". Starting or answering a call first checks the microphone
permission and asks for it natively, because the WebView otherwise may hand over a silent stream. The encoder and decoder are rebuilt after an error and the PCM format is read as delivered, so one bad frame cannot silence a call for good; the call screen shows
sent / received / played / error frame counts for diagnosis. If the microphone stays silent for 4 s the engine first retries once without voice processing (no echo cancellation, noise suppression
or automatic gain), a common cause of silent capture on some phones, and only then shows the warning. The stats line also shows the
track state, the audio context state and the number of captured frames. Muting disables the track, so silence is still sent and keeps the link alive. The call
ends with `lost` after 6 s without an authenticated frame (30 s before the first one, while the peer's microphone permission
prompt may be open) or when no neighbor for the call has been present for 8 s. The neighbor is found by its hello card, by the node the call's
authenticated frames came from (bound on the first frame), or by the node remembered on the contact (`contact.node`, saved when a hello card arrives)
so a call answered right after the app was reopened, before any hello was exchanged, is not cut off.

Ringing (Android, `Ringer`) follows the phone's own settings instead of the app volume: ringer mode normal = the default ringtone
on the ring stream (`USAGE_NOTIFICATION_RINGTONE`, looping) plus vibration; vibrate mode = vibration only; silent mode, or Do Not Disturb /
any interruption filter other than "all" = neither sound nor vibration, only the call screen. Other platforms fall back to a WebAudio tone.

Not yet: ringing while the app is closed, calls across several phones, iOS (the WebCodecs path is untested there).
iOS can never ring a closed app without Apple push, which needs a server.


## 14. Notifications and calls while the app is closed (Android)

A DATA packet for this phone that arrives while JS is not attached (app closed or screen off) used to be stored raw and shown as a
generic "New message". Now the engine opens it itself (`Opener`, process-wide `SignalCore` from `Shared`, the same Keystore-wrapped keys
as the app), so it can show who wrote and what, or ring for a call. The decrypted message is consumed from the ratchet, so it is
stored as a record sealed with the DB key (AES-GCM, AAD `inbox`) as inbox item `~<callId>`; the app receives it as `{ opened }`
(`drainInbox`, or the `opened` event) and skips decryption. If the native open or the DB key fails the raw packet is stored and the
generic notification shown, exactly as before. A crash between the decrypt and the inbox write loses that one message.

Notification content, from the contacts store read natively (vault format of section 12.1) or, for a stranger, the name in the card that
travels with the message: a text message shows `name` / excerpt (200 characters; groups `group: name`, only when the sender is a member
of the stored group), a photo "Sent a photo", any other attachment "Sent an attachment", an invitation "You have an invitation to contacts
from name". Messages from a pending request, invitations from strangers while hidden, and everything that is not a message, invitation
or call are silent. When app lock is on the text is the generic "New message"; on the lock screen the public version is always generic.
The record carries `notified`, so the app does not show a second notification. Tapping a notification opens that chat.

Calls: an offer from a contact you added, accepted or wrote to, not older than 120 s, with a well-formed id and key, and no other native call
ringing (a ring state expires after 45 s even if the caller's `end` never arrives), raises a full-screen notification on the `calls` channel and
rings with `Ringer` for 45 s following the system sound modes; the lock-screen version of the notification is generic ("Incoming call"), and
with app lock on the name is replaced by "Ripplo" everywhere. The full-screen target is `CallActivity`, a small native screen (caller, Answer,
Decline) that may show over the lock screen; `MainActivity` never does, so chats stay behind the lock. Answer does not ask for the unlock: it starts `MainActivity` with `ripplo.chat` and a random one-time token created natively for this
ring (`ripplo.answer`), and `MainActivity` shows over the lock screen only when that token is valid right now (`Opener.peek`; the notification's
Answer action sets `setAuthenticationRequired(false)`). The app then enters locked-call mode (`state.lockedCall`, entered when `isLocked()` is true at
that moment): only the call screen is rendered, no chats, tabs, dialogs, toasts or app-lock overlay, the screen is kept on for the call
(`keepAwake`), and when the call ends the activity is finished and removed (`endLockedCall`, also `setShowWhenLocked(false)`), returning to the lock
screen. If the user unlocks the phone during the call the app simply continues normally; a call that never appears closes the mode after 25 s.
The plugin turns the token into the call id only if it matches the current ring (`Opener.redeem`); the app accepts a call automatically only
when its call id equals that value and the call is ringing within 20 s, so another app that fires the exported activity cannot trigger an
answer. `ripplo.chat` is accepted only when it looks like a ripploId or a group id. Decline silences the ring and removes the offer from the
inbox, so the caller simply gets no answer. An `end` for the same call cancels the ring and posts "Missed call". Needs notifications and, on
Android 14+, the full-screen-intent special access, which the permission screen asks for; without it a heads-up banner with the same actions
appears. Opening the app takes over: it silences the native ring and the app rings itself while the call is still ringing. The engine
checks for inbox room before it decrypts anything (200 slots are reserved for opened records so attachment chunks cannot starve them), writes
the inbox with a temporary file and a rename, keeps the DB key in memory, delivers records to the app off the main thread (a record is put back
when the key is temporarily unavailable) and drains once more 1.5 s after the app attaches. Opening still happens inside the router lock, so a
slow open delays other routing for that moment. Native notifications repeat the app's own rules (no media from strangers, id and length checks,
control and bidi characters stripped, a sender's card name accepted only when its key hashes to the sender, one invitation notice per sender per
day) so nothing is shown that the app would discard. iOS has no equivalent: without Apple push, which needs a server, a closed iOS app cannot ring.
