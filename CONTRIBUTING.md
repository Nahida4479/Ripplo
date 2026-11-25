# Contributing to Ripplo

### Dart app (`lib/`)

```
lib/
├── main.dart                         # Entry point: picks the native or the desktop mesh, starts the app
├── app_shell.dart                    # Root widget, tabs, theme and navigation wiring
├── navigation_stack.dart             # Route stack (RipploRouter): chat, contact, tabs
├── translations.dart                 # UI strings in English and Polish, t('key')
├── contributor_logins.dart           # GitHub logins shown in the About card
│
├── core/                             # App logic, no widgets
│   ├── app_instances.dart            # The single state, mesh and core instances and the api functions the UI calls
│   ├── app_state.dart                # RipploState: profile, contacts, chats, neighbors, settings
│   ├── observable_collections.dart   # ObsMap / ObsList that notify the UI on change
│   ├── messenger_core.dart           # Core class: init, profile, hello, settings, sending
│   ├── messenger_contacts.dart       # Part of Core: contacts, invites, links, verification, incoming app packets
│   ├── messenger_messages.dart       # Part of Core: text, attachments, groups, receipts, deletes
│   ├── call_manager.dart             # Voice call state machine: ring, accept, end, signalling
│   ├── call_audio_engine.dart        # Microphone capture, Opus encode/decode, playback
│   └── diagnostic_log.dart           # In-memory log, forwarded to USB logcat
│
├── crypto/                           # Dart-side crypto (the Signal protocol itself is native)
│   ├── contact_card_codec.dart       # Contact card and invite link encode / check, ids, name cleaning
│   ├── database_vault.dart           # Seals database values with the DB key
│   ├── attachment_encryption.dart    # AES-GCM encryption of files, chunking, key pointer
│   └── call_frame_encryption.dart    # Encrypted voice call frames
│
├── data/                             # Storage
│   ├── app_database.dart             # Db over RawStore: native, file and in-memory backends
│   ├── backup_metadata.dart          # Meta record written into backups
│   ├── attachment_file_cache.dart    # Decrypted video and voice files, only while playing (cache/att)
│   ├── theme_language_prefs.dart     # Theme and language in shared preferences
│   └── github_api_cache.dart         # Cached GitHub release lookups with rate-limit backoff
│
├── mesh/                             # Talking to the transports and routing
│   ├── native_mesh_bridge.dart       # Mesh interface and MeshBridge over the ripplo/mesh channel
│   ├── mesh_packet.dart              # Packet encode / decode
│   ├── mesh_router.dart              # Flooding router with learned routes (same rules as Kotlin and Swift)
│   └── dev/                          # Desktop simulator only
│       ├── desktop_loopback_mesh.dart       # Mesh over UDP on 127.0.0.1
│       └── desktop_plaintext_signal.dart    # Plaintext stand-in for Signal, NO security
│
├── services/                         # Background helpers started by the app
│   ├── app_lock.dart                 # Biometric / device credential lock
│   ├── app_updater.dart              # Checks and installs updates
│   ├── call_ringtone.dart            # Ringtone and vibration for incoming calls
│   ├── deep_link_handler.dart        # ripplo:// links
│   ├── incoming_share_check.dart     # Files and text shared into the app
│   ├── local_notifications.dart      # Local message notifications
│   ├── neighbor_range_refresh.dart   # Rate-limited refresh of who is in range
│   ├── notification_open_intent.dart # Opening a chat or a call from a notification
│   ├── people_refresh_scheduler.dart # Timer and lifecycle trigger for refreshing people
│   └── runtime_permissions.dart      # Bluetooth, Wi-Fi, notification permission checks
│
├── util/                             # Small helpers without app state
│   ├── avatar_image_processing.dart  # Avatar validation, resize, initials
│   ├── byte_encoding.dart            # base64, hex, utf8, concat, random bytes
│   ├── coded_link_check.dart         # Is a link a BLE Coded PHY link
│   ├── js_compat.dart                # truthy, cut, now: helpers ported from the old JS code
│   ├── qr_multipart_codec.dart       # Splits and joins multi-part QR payloads
│   └── refresh_slot_schedule.dart    # Time slots that spread refreshes between phones
│
└── ui/
    ├── design_tokens.dart            # Colors, spacing, text styles
    ├── theme.dart                    # ThemeData built from the tokens
    ├── shared_widgets.dart           # Buttons, rows, fields, pages used everywhere
    ├── lucide_icons.dart             # Generated icon set (tool/gen_icons.dart)
    ├── avatar_widget.dart            # Avatar circle with photo or initials
    ├── qr_code_encoder.dart          # QR code generation
    ├── ui_request_state.dart         # Open sheets, toasts, share and confirm requests
    ├── components/                   # Sheets, cards and overlays
    │   ├── add_contact_sheet.dart
    │   ├── app_icon.dart             # App logo
    │   ├── backup_card.dart          # Backup and recovery code card in Settings
    │   ├── call_overlay.dart
    │   ├── confirm_sheet.dart
    │   ├── fractional_text_and_section_head.dart  # Text with sub-pixel offset, section headings
    │   ├── lock_overlay.dart
    │   ├── new_chat_sheet.dart
    │   ├── qr_scanner.dart
    │   └── share_sheet.dart
    └── views/                        # Whole screens
        ├── chat_list_view.dart       # Chats tab: list of conversations
        ├── conversation_view.dart    # One open chat: messages and composer
        ├── contact_profile_view.dart # One contact: verification, safety number, actions
        ├── nearby_people_view.dart   # People tab: neighbors and people seen through the mesh
        ├── onboarding_view.dart      # First start: create identity or restore a backup
        ├── permissions_gate_view.dart # Permission requests before the app opens
        └── settings_view.dart        # Settings, developer panel
```

### Android native (`android/app/src/main/java/io/github/nahida4479/ripplo/`)

```
ripplo/
├── MainActivity.kt                   # Flutter activity
├── bridge/                           # ripplo/mesh channel
│   ├── RipploMeshPlugin.kt           # All channel methods
│   └── Call.kt                       # Method call wrapper
├── mesh/                             # Engine that owns transports and links
│   ├── MeshEngine.kt                 # Starts transports, links, pings, force connect
│   ├── MeshService.kt                # Foreground service that keeps the engine alive
│   ├── Router.kt                     # Router (same rules as Dart and Swift)
│   └── Packet.kt                     # Packet format
├── transport/                        # One folder per medium
│   ├── Transport.kt, Link.kt, StreamLink.kt
│   ├── ble/ (BleTransport.kt, coded/, l2cap/)
│   ├── lan/
│   ├── wifiaware/
│   └── wifidirect/                   # Raw Wi-Fi P2P; the Play flavor uses Nearby instead
├── crypto/                           # libsignal wrapper and key files
├── data/                             # Native store, backup engine and format
├── calls/                            # Call screen, ringer, audio
├── platform/                         # Notifications, app lock, opening messages
└── update/                           # Update download and install
```

The Play flavor adds `android/app/src/play/.../transport/nearby/NearbyTransport.kt`, which provides the `wifi-direct` medium.

### iOS native (`ios/Runner/`)

Same roles as Android: `RipploMeshPlugin.swift`, `MeshEngine.swift`, `Router.swift`, the transports (`BleTransport.swift`, `LanTransport.swift`, `MultipeerTransport.swift`), `SignalCore.swift`, `BackupEngine.swift`.

