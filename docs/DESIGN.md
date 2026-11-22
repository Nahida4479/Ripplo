# Ripplo UI design

🇬🇧 English | [🇵🇱 Polski](DESIGN.pl.md)

Messenger look (Signal / WhatsApp), mobile-first, dark by default. Icons: `lucide-vue-next`,
1.75 stroke, 22 px. Font: system stack (`-apple-system, "SF Pro Text", Roboto, Inter, sans-serif`).
UI strings live in `src/i18n.js` (`en`, `pl`; device language, fallback `en`).

## Tokens (CSS custom properties on `:root`)

| token | dark | light |
|-------|------|-------|
| `--bg` | `#0b0b0c` | `#ffffff` |
| `--surface` | `#161617` | `#f4f4f6` |
| `--surface-2` | `#1f1f21` | `#ebebef` |
| `--border` | `#2a2a2d` | `#e2e2e7` |
| `--text` | `#f2f2f3` | `#111114` |
| `--text-2` | `#a1a1a6` | `#6b6b73` |
| `--warn` | `#f5b544` | `#b7791f` |
| `--danger` | `#ef5350` | `#d32f2f` |
| `--ok` | `#3ecf8e` | `#1f9d63` |

`--accent` (user choice) and `--on-accent` (white or `#111` by WCAG luminance of the accent).
`--accent-soft` = accent at 16 % alpha (active tab, selected rows).
`--glow` = background gradient color (or transparent): every page has
`background: linear-gradient(180deg, color-mix(in srgb, var(--glow) 55%, transparent) 0, transparent 340px), var(--bg)`.

Accent swatches: green `#22c55e`, teal `#14b8a6`, blue `#4f9cf9` (default), lavender `#a78bfa`,
pink `#e467b0`, coral `#ea6a5f`, orange `#e67e22`, gray `#9ca3af`, custom (rainbow conic swatch →
native `<input type="color">`).
Gradient swatches: none (diagonal slash), purple `#5b2ea6`, navy `#1e3a8a`, teal `#0f5257`,
plum `#7a1f4f`, brown `#6b3a0a`, slate `#3d4552`.
Theme mode: segmented pill `System | Dark | Light`, selected segment filled with accent.
Selected swatch: 2 px ring in `--text` with 3 px gap. All theme prefs in localStorage.

Radius: cards 14, rows 12, bubbles 18 (tail corner 6), pills 999. Spacing scale 4/8/12/16/24.
Safe areas: `env(safe-area-inset-*)` on header and tab bar.

## Shell

- Large-title header per tab (28/700): left = own avatar (opens profile/QR), right = icon buttons.
- Floating pill tab bar at the bottom (surface, 1 px border, blur): **Chats**, **People**,
  **Settings**. Active item: accent icon + `--accent-soft` pill behind it. Settings shows a red dot
  when an update is available or the integrity check failed.
- Permission gate (blocking, full screen before anything else): logo, one-line why, list of
  required permissions with status chips (Bluetooth, Nearby Wi-Fi / location, Notifications) and
  one **Grant permissions** button, which also opens the system battery-exemption prompt after the other permissions (the "Allow background relay" row shows its state but never blocks). The list also has a Microphone row and, on Android 14+, an "Incoming call screen on the lock screen" row (the full-screen-intent special access); the same button requests them, and none of them blocks. The screen also appears once at the next start for people who already have the required permissions but lack one of these extras; then a "Not now" button lets them continue, and after that it is not shown again for the extras.
- Onboarding: name field + generate identity ("Your keys are created on this phone and never leave it").

## Chats tab

Header icons: QR (scan/add), pencil (new chat / new group). Search pill below title.
Optional "Pinned" section. Row 68 px: avatar 48 (initials on hashed hue, group icon for groups),
name 16/600, preview 14 `--text-2` (voice: mic icon + "Voice message"), time 12 right, unread badge
(accent, `--on-accent`). Unverified contacts get a small amber shield on the avatar.
Under the search pill, when someone invited you, a **Requests · n** section: avatar with amber shield, name,
"wants to add you", **Decline** (ghost) and **Accept**.
Empty state: illustration of ripples + "Add a friend by QR code or invite link".

## Chat view

- Header: back, avatar, name, sub-line = verification + route: `✓ Verified · LAN` / `⚠ Not verified`
  / `Out of range`. Tap → contact page.
- Amber banner under the header while unverified: text from ARCHITECTURE §5 + three buttons
  (Verify with QR / Retry over mesh / I'm sure it's them). Red variant for key-substitution warning.
- Bubbles: incoming `--surface-2`, outgoing `--accent` with `--on-accent` text, max 78 % width,
  12/16 padding, time 11 inside bottom-right. Day separators as centered pills.
- Outgoing status under/inside the bubble (icon + label on tap):
  encrypting (lock spinning), sending (single tick + `%` for attachments), delivered (double tick,
  "via 3 phones"), out_of_range (red cloud-off + "Out of mesh range" + **Retry**), failed.
- Typing: while the other person types, an incoming-style bubble with three dots (7 px, 1.2 s staggered bounce, still under reduced motion) sits at the end of the log.
- Media: images/video thumbnails 240 max, rounded 14; voice note = play button + waveform bars +
  duration. Incoming media appears only when complete.
- Reply: drag a message sideways (either direction, 56 px) and let go; a reply icon fades in, the bubble springs back and a reply bar
  (author + excerpt + X) appears above the composer. The reply bubble shows a quote block (author, two lines) and tapping it scrolls to
  and flashes the original.
- Attachments: `+` picks up to 10 photos or videos (multi-select); they wait as 64 px thumbnails with an X above the composer and
  nothing is sent until Send. The text field then becomes the caption of the last item; a reply goes with the first.
- Composer pill: `+` (photo/video, max 20 MB), text area auto-grow (counter `n/1000` appears from
  900, red at 1000), mic button when empty (tap to record; while recording: cancel, red dot with timer, live level bars, send), send button when text.
- Every chat shows a lock line at the top: "Messages are end-to-end encrypted with the Signal protocol."

## People tab

Header: refresh icon (spins while DISCOVER runs), "Last refreshed 03:12 · next tonight".
Sections: **Nearby** (direct neighbors, live, with one chip per detected medium (`BLE`, `LAN`, `Wi-Fi Direct`, ...), the link in use marked with a check, and
speed), **In mesh range** (DISCOVER replies, with hop count). A search field (exact full name or ID, hash only on the wire) sits above the sections; results replace the mesh list and an X restores it.
Row action: **Invite** → confirm sheet
("They get a request and can accept or decline"). After sending the row shows an **Invited** chip (**Retry** if
delivery failed); someone who invited you shows **Accept**. Contacts already added show a check.

## Call screen

A phone button in the chat header (hidden for groups and pending requests, disabled during a call) starts a call; it
needs a direct link. Full-screen sheet over everything: avatar 112, name, status (Calling… / Incoming call /
Connecting… / timer / ended reason), then round 68 px buttons: incoming = red Decline and green Answer (ringtone and
vibration following the phone's sound mode; only the screen when it is silent or in Do Not Disturb), otherwise Mute toggle and red End. The ended state stays for 2.5 s.

## Share sheet ("Send to…")

Appears when another app shares text, a photo, a video or audio to Ripplo (system share menu → Ripplo). Preview line
(text excerpt or media type), scrollable list of chats and groups with avatars, Cancel. Tapping a chat sends
immediately and opens that chat.

## Add contact sheet

Tabs: **My code** (animated QR of the invite link, about 6 frames of 700 ms with progress dots and a hint to keep the other phone on it until it finishes, + ripploId + Invite a friend button (shares text + web link; a hint line says the contact is added unverified) via Web Share API /
copy), **Scan** (camera viewfinder with rounded mask; continuous automatic detection, native `BarcodeDetector` when it works, otherwise ZXing compiled to WebAssembly (jsQR only while it loads); no button to press. A match closes the sheet at once with "Keys verified successfully" or "Added to contacts" and a short vibration), **Paste link**.

## Contact page

When the key is verified (and there is no conflict) the safety number, its QR and the Verify / Retry buttons are hidden; they
reappear if verification is lost or a conflict is flagged. A **Media** section lists every photo and video of the chat (3-column
grid, newest first, video tiles with a play icon); tapping opens a full-screen viewer.

Avatar, name, ripploId, verification card (state + method + date), safety number (12×5 digits
monospace) + QR of it, actions: Verify with QR, Retry nearby, I'm sure it's them, Delete contact.

## Settings (list of grouped cards, like the music app reference)

- **Profile**: "Visible in Find people" switch, tapping the name edits it in place (Save / Cancel; there is no separate button), tappable avatar (pick a photo, cropped square; when set, a small **Clear photo** button sits centered right under it), name, ripploId, My QR. Photos show in chat list, chat header, contact page, People and New chat; initials otherwise.
- **Appearance**: mode segmented control, Accent color swatches, Background gradient swatches,
  Language.
- **Network**: live list of transports with state + measured speed; Background relay toggle
  (Android foreground service); "Relayed messages are never shown". The battery exemption is asked only on the permission screen.
- **Security**: app integrity (Official build ✓ / Modified ✗ / Not checked yet), DB encryption
  status, Signal protocol info.
- **Updates**: current version, latest version, Check now (accent-colored button so it is easy to see; the label changes to "Checking…" for at least 0.8 s and there is no "up to date" line), Auto-update toggle (Android), progress.
- **About**: app name + tagline, version (tapping this row 5 times within 2 s toggles **developer mode**, which adds a **Developer** card with transport states, the BLE Coded PHY switch (with phone support shown), a row per neighbor to force a connection with one standard (LAN, Wi-Fi Direct, Wi-Fi Aware, BLE 1M / Coded PHY) or close it, the diagnostic log and Refresh / Copy log / Clear log), GitHub link, License, **Contributors** cards: avatar
  (GitHub avatar when online, initials offline), login bold, "GitHub profile" sub-text, external-link
  icon on the right; card = `--surface`, 1 px border, radius 14.

## Notifications

Android: the status-bar glyph is the monochrome `ic_stat_ripplo` tinted with the accent color, and the full-color app icon (`ic_notification_large`,
rendered from `public/icon.svg` by `scripts/icons.sh`) is the large icon of every notification, native and local. iOS always shows the app icon
(`AppIcon`, the same artwork as `public/icon_ios.png`), which cannot be changed per notification.
Titles are the sender's name (groups: "group: name"), the body is the message text, "Sent a photo" or "Sent an attachment"; invitations read
"Contact invitation"; incoming calls use a small native full-screen call screen (name, Answer, Decline) that can appear over the lock screen without exposing the chats; Answer connects at once without unlocking: only the call screen is shown over the lock screen (the screen stays on) and the chats stay hidden until the phone is unlocked. On the lock screen messages show only "New message".
