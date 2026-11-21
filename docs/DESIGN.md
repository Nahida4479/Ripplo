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
  one **Grant permissions** button, which also opens the system battery-exemption prompt after the other permissions (the "Allow background relay" row shows its state but never blocks).
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
- Media: images/video thumbnails 240 max, rounded 14; voice note = play button + waveform bars +
  duration. Incoming media appears only when complete.
- Composer pill: `+` (photo/video, max 20 MB), text area auto-grow (counter `n/1000` appears from
  900, red at 1000), mic button when empty (tap to record; while recording: cancel, red dot with timer, live level bars, send), send button when text.
- Every chat shows a lock line at the top: "Messages are end-to-end encrypted with the Signal protocol."

## People tab

Header: refresh icon (spins while DISCOVER runs), "Last refreshed 03:12 · next tonight".
Sections: **Nearby** (direct neighbors, live, with medium chips `BLE`, `LAN`, `Wi-Fi Direct` and
speed), **In mesh range** (DISCOVER replies, with hop count). A search field (exact full name or ID, hash only on the wire) sits above the sections; results replace the mesh list and an X restores it.
Row action: **Invite** → confirm sheet
("They get a request and can accept or decline"). After sending the row shows an **Invited** chip (**Retry** if
delivery failed); someone who invited you shows **Accept**. Contacts already added show a check.

## Call screen

A phone button in the chat header (hidden for groups and pending requests, disabled during a call) starts a call; it
needs a direct link. Full-screen sheet over everything: avatar 112, name, status (Calling… / Incoming call /
Connecting… / timer / ended reason), then round 68 px buttons: incoming = red Decline and green Answer (ringtone and
vibration), otherwise Mute toggle and red End. The ended state stays for 2.5 s.

## Share sheet ("Send to…")

Appears when another app shares text, a photo, a video or audio to Ripplo (system share menu → Ripplo). Preview line
(text excerpt or media type), scrollable list of chats and groups with avatars, Cancel. Tapping a chat sends
immediately and opens that chat.

## Add contact sheet

Tabs: **My code** (large QR of invite link + ripploId + Share link button via Web Share API /
copy), **Scan** (camera viewfinder with rounded mask; continuous automatic detection, native `BarcodeDetector` when present, jsQR otherwise; no button to press), **Paste link**.

## Contact page

When the key is verified (and there is no conflict) the safety number, its QR and the Verify / Retry buttons are hidden; they
reappear if verification is lost or a conflict is flagged. A **Media** section lists every photo and video of the chat (3-column
grid, newest first, video tiles with a play icon); tapping opens a full-screen viewer.

Avatar, name, ripploId, verification card (state + method + date), safety number (12×5 digits
monospace) + QR of it, actions: Verify with QR, Retry nearby, I'm sure it's them, Delete contact.

## Settings (list of grouped cards, like the music app reference)

- **Profile**: "Visible in Find people" switch, Change name (inline field, Save / Cancel), tappable avatar (pick a photo, cropped square; Remove button when set), name, ripploId, My QR. Photos show in chat list, chat header, contact page, People and New chat; initials otherwise.
- **Appearance**: mode segmented control, Accent color swatches, Background gradient swatches,
  Language.
- **Network**: live list of transports with state + measured speed; Background relay toggle
  (Android foreground service) and battery exemption button; "Relayed messages are never shown".
- **Security**: app integrity (Official build ✓ / Modified ✗ / Not checked yet), DB encryption
  status, Signal protocol info.
- **Updates**: current version, latest version, Check now, Auto-update toggle (Android), progress.
- **About**: app name + tagline, version, GitHub link, License, **Contributors** cards: avatar
  (GitHub avatar when online, initials offline), login bold, "GitHub profile" sub-text, external-link
  icon on the right; card = `--surface`, 1 px border, radius 14.
