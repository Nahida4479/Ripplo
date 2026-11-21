# Ripplo

<p align="center"><img src="./public/icon_android.png" width="120"></p>

<p align="center" style="text-align: center; font-weight: bold;">An offline, end-to-end encrypted mesh messenger. No servers, no accounts, no internet: messages hop from phone to phone over Bluetooth and Wi-Fi.</p>

<div align="center">
<img src="https://img.shields.io/badge/Ripplo-Offline_Mesh_Messenger-blue">
<img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
<img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
<img src="https://img.shields.io/badge/Vue-3-4FC08D?logo=vue.js&logoColor=white" alt="Vue 3">
<img src="https://img.shields.io/badge/Capacitor-8-119EFF?logo=capacitor&logoColor=white" alt="Capacitor 8">
<img src="https://img.shields.io/badge/Signal-protocol-3A76F0?logo=signal&logoColor=white" alt="Signal protocol">
<a href="./LICENSE"><img src="https://img.shields.io/github/license/Nahida4479/Ripplo"></a>
<img src="https://github.com/Nahida4479/Ripplo/actions/workflows/build.yml/badge.svg">
</div>

> [!NOTE]
> Ripplo is in early development (v0.1.0). The native transports (Kotlin / Swift) have not been field-tested yet. Expect rough edges.

# Features

- No servers, no accounts, no phone numbers, no internet connection needed.
- Phones form a mesh: every phone in range can relay messages for others.
- End-to-end encryption with the Signal protocol (X3DH + Double Ratchet) for chats, groups, voice notes, photos and videos.
- Sealed sender: relays cannot see who wrote a message.
- Encrypted local database, key held by the Android Keystore / iOS Keychain.
- Several transports at once (BLE, Bluetooth L2CAP, LAN, Wi-Fi Direct, Wi-Fi Aware, Apple Multipeer). The fastest live link is always used.
- Add friends with a QR code, an invite link (no server involved) or the People tab.
- Key verification: nearby proof, QR comparison in person, or manual.
- Delivery stages: encrypting, sending, delivered ("via k phones"), out of mesh range.
- Relaying keeps working with the screen off (native foreground service on Android).
- Relays never see plaintext and never notify you about relayed messages.
- Group chats, voice notes, photos and videos (up to 20 MB).
- Dark / light / system theme, accent colors and background gradients.
- Signed releases with `SHA256SUMS`; the app verifies its own APK and can auto-update on Android.
- Languages: English and Polish (device language, fallback English).

# How to use?
1. [Install Ripplo](#install) on two or more phones.
2. Create your profile (name only). Your keys are generated on the phone and never leave it.
3. Grant the permissions (Bluetooth, nearby Wi-Fi / location, notifications) and, on Android, allow the background relay.
4. Add a friend: open the QR icon in **Chats** and scan their code, paste their invite link, or pick them in the **People** tab.
5. [Verify the key](#verifying-a-contact) of the person you added.
6. Write a message. If your friend is out of direct range, other Ripplo phones in between relay it.

# How it works

## Transports

Every transport carries the same byte stream, so one neighbor can be reachable over several links at the same time (for example BLE and LAN). Every minute the app measures the speed of each link and always sends through the fastest live one, falling back to the next if it fails.

| Medium | Android | iOS | Android <-> iOS | Discovery |
|---|---|---|---|---|
| BLE (GATT) | yes | yes | yes | Ripplo GATT service |
| Bluetooth L2CAP (BLE CoC) | yes (Android 10+) | yes | yes | PSM read over GATT |
| LAN | yes | yes | yes | DNS-SD `_ripplo._tcp` on the current Wi-Fi / hotspot |
| Wi-Fi Direct | yes | no | no | Wi-Fi P2P DNS-SD |
| Wi-Fi Aware | yes (Android 8+, needs hardware support) | no | no | NAN service `ripplo` |
| Apple Multipeer | no | yes | no | MultipeerConnectivity |

Classic Bluetooth RFCOMM is not used (iOS cannot use it without MFi); L2CAP is the cross-platform Bluetooth fast path.

## Encryption

- **Signal protocol** (X3DH + Double Ratchet) for every message: text, attachments, group updates. Groups are encrypted pairwise for every member.
- **Sealed sender**: the sender identity is wrapped in an extra layer only the recipient can open, so relays do not learn who is talking to whom.
- **Attachments** (voice notes, photos, videos) are encrypted once with a random key, split into 32 KiB chunks and sent separately. The key travels in a Signal-encrypted message after all chunks were acknowledged, and the recipient verifies the hash before decrypting.
- **At rest**: the local database is AES-GCM encrypted with a key held by the OS keystore.

Relays only forward opaque packets. They cannot read, decrypt or attribute anything. Only the recipient decrypts.

## Adding friends

- **QR code**: scan the code shown in **My code**.
- **Invite link**: `ripplo://add/...` contains your name and public keys. It is shared like any text, no server ever sees it.
- **People tab**: asks the whole mesh who is around. This floods the mesh, so it refreshes automatically once a day between 02:00 and 05:00, or when you tap refresh.

People added from the People tab or an invite link are unverified (a relay could have swapped the card) and get a warning until you verify them.

## Verifying a contact

| Level | Meaning |
|---|---|
| Nearby | A challenge-response proof over a direct link: the key's owner is physically in range. |
| QR | You scanned the person's safety QR in person. |
| Manual | You vouched yourself (e.g. compared the safety number in another messenger). |

After adding a contact, the app looks for them as a direct neighbor for 60 seconds and runs the nearby proof. If it fails you can verify with a QR code, retry over the mesh, or confirm "I'm sure it's them". A neighbor announcing the same name with a different key raises a red "possible key substitution" warning.

> [!WARNING]
> A nearby proof shows that the key's owner is physically in range, not who they are. An attacker who swapped your link and stands nearby passes it. Comparing the QR code or the 60-digit safety number with the real person is the strong check.

## How messages travel

- Messages travel hop by hop: every phone forwards a packet to its neighbors, and once a route is learned the following packets go along it.
- Each packet has a TTL of 8 hops.
- Messages cannot loop: every phone forwards a given packet at most once, and duplicates are answered with a "dead end" instead of being forwarded.
- If every path dies, the sender sees "Contact is out of mesh range" and can retry. The app also gives up after 90 seconds without an answer.
- Delivery stages: `encrypting`, `sending`, `delivered` (with the number of phones it passed through), `out of range`.
- Incoming messages are acknowledged as soon as they are stored, so delivery works with the screen off and the app closed.
- Relaying happens natively, so phones keep relaying in the background.
- Relayed messages are never shown and never trigger a notification. Your phone will not tell you that something passed through it.

## Limits

- Text: 1000 characters.
- Attachments: 20 MB (before encryption), sent in chunks.
- Per neighbor: 200 packets/s and 32 MiB queued per link; overflow is dropped.

## Themes

Dark by default. Switch between System, Dark and Light, then pick an accent color (or a custom one) and a background gradient. Preferences are stored on the device.

## Updates and integrity

- Every GitHub release ships `Ripplo-vX.Y.Z.apk`, `Ripplo-vX.Y.Z-unsigned.ipa` and a `SHA256SUMS` file.
- When online, the app checks the latest GitHub release and shows an update badge. On Android with auto-update on, it downloads the APK, verifies the SHA-256 and the signing certificate, and installs it.
- On Android the app hashes its own installed APK and compares it with `SHA256SUMS` of the matching release. This also verifies copies shared via Quick Share / Nearby Share. The result is in Settings > Security.

# Install

## Android

Download `Ripplo-vX.Y.Z.apk` from [Releases](https://github.com/Nahida4479/Ripplo/releases), verify it against `SHA256SUMS`, and install it.

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

## iOS

The release contains an **unsigned** IPA (`Ripplo-vX.Y.Z-unsigned.ipa`). It must be sideloaded or re-signed with your own Apple ID, for example with [AltStore](https://altstore.io/) or [SideStore](https://sidestore.io/).

# Build from source

Requirements: Node.js, plus Android Studio and/or Xcode for the native apps.

```bash
npm install
npm run dev        # web build
npm test           # run the tests
npm run build      # production web build
npx cap sync       # copy the build into the native projects
```

Then open the native project in Android Studio (`android/`) or Xcode (`ios/App`) and run it.

In the web build (`npm run dev`) there is no native layer: open the app in several browser tabs and they form a mesh over `BroadcastChannel`. The database key is then stored in localStorage, which the UI flags as insecure.

# Releases

Pushing a tag `vX.Y.Z` starts the GitHub Actions workflow (`.github/workflows/build.yml`), which builds a signed APK, an unsigned IPA and `SHA256SUMS`, and publishes them in a GitHub release.

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Required repository secrets

| Secret | Description |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Your keystore file, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Alias of the signing key |
| `ANDROID_KEY_PASSWORD` | Password of the signing key |

Create a keystore with `keytool` and encode it (use your own alias and passwords, and never commit the keystore):

```bash
keytool -genkeypair -v -keystore ripplo.jks -alias <your-alias> \
  -keyalg RSA -keysize 2048 -validity 10000
base64 -w0 ripplo.jks   # paste the output into ANDROID_KEYSTORE_BASE64
```

Keep the same keystore for every release: Android only installs updates signed with the same certificate.

# Platform limits

- **iOS background**: only BLE can relay while the app is in the background.
- **Wi-Fi Direct** and **Wi-Fi Aware** are Android only.
- **Apple Multipeer** is iOS only.
- **Android <-> iOS** talk to each other over BLE, L2CAP and LAN.
- Wi-Fi Aware on iOS needs a paid-developer entitlement and is not implemented yet.
- The native transports are not yet field-tested.

# Contributors

- [Nahida4479](https://github.com/Nahida4479)

# License
Released under the [MIT License](./LICENSE) © 2026 [Nahida4479](https://github.com/Nahida4479).
Free to use, modify and share, as long as the license notice is kept. Provided "as is", without warranty.
