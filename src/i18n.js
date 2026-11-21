import { ref } from 'vue'

const en = {
  chats: 'Chats', people: 'Find people', settings: 'Settings', navigation: 'Navigation', attention: 'Needs attention',
  cancel: 'Cancel', close: 'Close', confirm: 'Confirm', delete: 'Delete', add: 'Add', create: 'Create', back: 'Back', paste: 'Paste', retry: 'Retry', send: 'Send',
  gateWhy: 'Ripplo talks to nearby phones over Bluetooth and Wi-Fi, so it needs these permissions to work without internet.',
  permBluetooth: 'Bluetooth', permWifi: 'Nearby Wi-Fi / location', permNotifications: 'Notifications',
  perm_granted: 'Allowed', perm_denied: 'Denied', perm_prompt: 'Needed',
  grantPermissions: 'Grant permissions', allowBackground: 'Allow background relay', optional: 'Optional, keeps the mesh alive with the screen off',
  welcome: 'Welcome to Ripplo', onboardHint: 'Your keys are created on this phone and never leave it.', yourName: 'Your name', generateIdentity: 'Generate identity',
  updateFound: 'Update {version} available', updateAsk: 'A new version of Ripplo was found. Update now?', updateAskWeb: 'A new version of Ripplo was found. Open the release page?', updateNow: 'Update', later: 'Later', peerVerified: '{name} has already verified your key: {method}', unsend: 'Unsend', unsendTitle: 'Unsend this message?', unsendText: 'It disappears for you and for the other person. If their phone is out of range, it disappears when it is back in range.', you: 'You', callStats: 'Sent {sent} · received {recv} · played {played} · errors {errors}', callAction: 'Call', incomingCall: 'Incoming call', calling: 'Calling…', callConnecting: 'Connecting…', callAnswer: 'Answer', callDecline: 'Decline', callEnd: 'End call', callMute: 'Mute', callUnmute: 'Unmute', call_ended: 'Call ended', call_missed: 'Missed call', call_noanswer: 'No answer', call_declined: 'Call declined', call_busy: 'Busy', call_cancelled: 'Call cancelled', call_lost: 'Connection lost', call_mic: 'Microphone not available', call_unreachable: 'Could not reach the contact', callLog: 'Call, {time}', err_call_busy: 'You are already in a call', err_media_locked: 'You can send photos, videos and voice messages after they reply', err_call_no_contact: 'Calls work with contacts you have accepted or written to', err_call_no_link: 'You can only call phones connected directly to you', err_call_unsupported: 'Calls are not supported on this device',
  findPlaceholder: 'Find by exact name or ID', find: 'Find', findHint: 'The name travels only as a short hash. That hides it from casual observers, not from someone who guesses it. Partial names do not match.', searchResults: 'Search results', noResults: 'Nobody answered to that name or ID', media: 'Media', noMedia: 'No photos or videos in this chat yet', shareTo: 'Send to…', shareTooLong: 'This text is too long to send as one message', noSound: 'No sound was recorded. Check the microphone.', discoverable: 'Visible in Find people', discoverableHint: 'When off, phones nearby and mesh searches do not see you. Your contacts still can.',
  invite: 'Invite', invited: 'Invited', inviteTitle: 'Invite {name}?', inviteText: 'They get a request and can accept or decline. You can chat once they accept.', inviteSent: 'Invitation sent', requests: 'Requests', wantsToAdd: 'wants to add you', inviteNotifyTitle: 'Contact invitation', inviteNotifyBody: 'You have an invitation to contacts from {name}', accept: 'Accept', decline: 'Decline',
  changeName: 'Change name', save: 'Save', err_bad_name: 'Enter a valid name', err_install_permission: 'Allow Ripplo to install apps in the settings that just opened, then tap Install again', upToDate: 'You have the latest version', changePhoto: 'Change profile picture', removePhoto: 'Remove', photoHint: 'Your picture is sent only inside encrypted messages to people you talk to, including those who add you.', err_bad_avatar: 'Could not use this picture',
  profile: 'Profile', search: 'Search', addContact: 'Add contact', newChat: 'New chat', newGroup: 'New group', groupName: 'Group name', noContacts: 'No contacts yet. Add a friend first.',
  emptyChats: 'Add a friend by QR code or invite link', voiceMessage: 'Voice message', photoMessage: 'Photo', videoMessage: 'Video', unread: 'Unread messages',
  myCode: 'My code', scan: 'Scan', pasteLink: 'Paste link', shareLink: 'Share link', copied: 'Link copied', cameraDenied: 'Camera not available',
  scanSafetyHint: "Scan the other person's safety-number QR code, shown on their contact page.",
  verifiedOk: 'Keys verified successfully', verifyMismatch: 'Safety numbers do not match', verifyFailed: 'Could not verify over the mesh',
  err_bad_link: 'This is not a valid Ripplo link', err_bad_checksum: 'The link is damaged or was modified', err_self: 'That is your own code',
  deepLinkConfirm: 'Add the contact from this link? Its key stays unverified until you check it.',
  lastRefreshed: 'Last refreshed {time}', nextTonight: 'next tonight', refresh: 'Refresh', nearby: 'Nearby', inMesh: 'In mesh range',
  nobodyNearby: 'Nobody nearby right now', nobodyInMesh: 'Nobody found yet. Tap refresh.', hops_one: '1 hop away', hops_other: '{n} hops away', inContacts: 'In your contacts',
  addPersonTitle: 'Add {name}?', added: 'Added to contacts',
  unverifiedWarning: "Could not verify this public key. You can't be sure the person on the other side is who you added.",
  conflictWarning: 'Possible key substitution: someone with this name is using a different key. Do not trust this chat until you verify in person.',
  conflict: 'Possible key substitution', verified: 'Verified', notVerified: 'Not verified', outOfRange: 'Out of range',
  method_nearby: 'Proved over a direct link', method_qr: 'Compared by QR code', method_manual: 'Confirmed by you', method_none: '',
  safetyNumber: 'Safety number', safetyHint: 'Compare these digits or the QR code with the other person, in person.',
  verifyQr: 'Verify with QR code', retryNearby: 'Retry nearby check', retryMesh: 'Retry over mesh', imSure: "I'm sure it's them", imSureConfirm: 'Only confirm if you compared the safety number with them another way.',
  checking: 'Checking…', deleteContact: 'Delete contact', deleteContactConfirm: 'The contact and its chat are removed from this phone.',
  members: '{n} members', contactInfo: 'Contact info', encryptedLine: 'Messages are end-to-end encrypted with the Signal protocol.', devCryptoWarn: 'Development build: messages are NOT encrypted',
  image: 'Image', play: 'Play', playFailed: 'Cannot play this voice message', micDenied: 'Microphone not available', fileTooBig: 'File is larger than 20 MB',
  attach: 'Attach photo or video', message: 'Message', recordVoice: 'Record voice message',
  status_encrypting: 'Encrypting', status_sending: 'Sending', status_delivered: 'Delivered', status_failed: 'Failed to send', status_out_of_range: 'Out of mesh range', status_received: '',
  viaPhones_one: 'Delivered via 1 phone', viaPhones_other: 'Delivered via {n} phones', outOfMeshRange: 'Contact is out of mesh range',
  appearance: 'Appearance', themeMode: 'Theme', mode_system: 'System', mode_dark: 'Dark', mode_light: 'Light', accent: 'Accent color', customColor: 'Custom color', background: 'Background', none: 'None', language: 'Language',
  network: 'Network', noNeighbors: 'No phones connected right now', connected: 'Connected', backgroundRelay: 'Background relay', relayHint: 'Relayed messages are never shown',
  security: 'Security', integrity: 'App integrity', integrityOk: 'Official build', integrityBad: 'Modified build', integrityUnknown: 'Not checked yet',
  dbEncryption: 'Database encryption', dbSecure: 'Key kept in the system keystore', dbInsecure: 'Web storage: the key is not protected by the system', signal: 'Signal protocol', signalInfo: 'X3DH + Double Ratchet, end to end',
  updates: 'Updates', currentVersion: 'Current version', latestVersion: 'Latest version', checkNow: 'Check now', install: 'Install update', openRelease: 'Open release page', autoUpdate: 'Update automatically',
  backup: 'Backup', backupWeb: 'Backups are available in the Ripplo app on your phone.', backupIntro: 'Save an encrypted copy of your chats and keys. Only your recovery code can open it.',
  backupEnable: 'Turn on backup', backupNow: 'Back up now', showCode: 'Show recovery code', backupOff: 'Turn off backup', backupOffConfirm: 'This phone forgets the recovery code and the automatic backup folder. Backup files you already saved stay where they are.',
  backupNever: 'No backup yet', backupLast: 'Last backup: {time}', backupFolder: 'Folder: {name}', backupNoFolder: 'No automatic backup folder', chooseFolder: 'Choose automatic backup folder', notNow: 'Not now', backupDone: 'Backup saved',
  codeTitle: 'Your recovery code', codeWarn: 'Keep this code somewhere safe, for example in a password manager. Without it a backup cannot be opened. Fingerprint and face unlock do not move to a new phone: there you restore with this code.',
  codeWritten: 'I wrote it down', codeCheckTitle: 'Check the code', codeCheckHint: 'Type the last group of digits (the sixth) to confirm you saved the code.', codeMismatch: 'That does not match', continue: 'Continue', done: 'Done',
  folderTitle: 'Automatic backup', folderHint: 'Pick a folder and Ripplo saves a fresh backup there when you open the app, at most once a day. Each new backup replaces the previous one, so there is always a single file.',
  restoreFromBackup: 'Restore from backup', restoreHint: 'Enter your 30-digit recovery code, then choose the backup file.', recoveryCode: 'Recovery code', restore: 'Restore',
  bk_bad_code: 'That code does not open this backup', bk_bad_file: 'This is not a valid Ripplo backup, or it is damaged', bk_need_factor: 'This backup needs its second factor — not supported in this version yet', bk_auth_failed: 'Authentication failed', bk_failed: 'Something went wrong',
  appLock: 'App lock', appLockHint: 'Ask for fingerprint, face or screen lock when Ripplo opens, and hide it in the app switcher', unlock: 'Unlock', unlockReason: 'Unlock Ripplo', locked: 'Ripplo is locked',
  undecryptable: "Couldn't decrypt a message from {name} — ask them to resend",
  about: 'About', tagline: 'Offline end-to-end encrypted mesh messenger', license: 'License', contributors: 'Contributors', githubProfile: 'GitHub profile'
}

const pl = {
  chats: 'Czaty', people: 'Znajdź osoby', settings: 'Ustawienia', navigation: 'Nawigacja', attention: 'Wymaga uwagi',
  cancel: 'Anuluj', close: 'Zamknij', confirm: 'Potwierdź', delete: 'Usuń', add: 'Dodaj', create: 'Utwórz', back: 'Wstecz', paste: 'Wklej', retry: 'Ponów', send: 'Wyślij',
  gateWhy: 'Ripplo łączy się z pobliskimi telefonami przez Bluetooth i Wi-Fi, więc potrzebuje tych uprawnień, by działać bez internetu.',
  permBluetooth: 'Bluetooth', permWifi: 'Wi-Fi w pobliżu / lokalizacja', permNotifications: 'Powiadomienia',
  perm_granted: 'Zezwolono', perm_denied: 'Odmówiono', perm_prompt: 'Wymagane',
  grantPermissions: 'Przyznaj uprawnienia', allowBackground: 'Zezwól na przekazywanie w tle', optional: 'Opcjonalne, utrzymuje sieć przy wyłączonym ekranie',
  welcome: 'Witaj w Ripplo', onboardHint: 'Twoje klucze powstają na tym telefonie i nigdy go nie opuszczają.', yourName: 'Twoje imię', generateIdentity: 'Utwórz tożsamość',
  updateFound: 'Dostępna aktualizacja {version}', updateAsk: 'Wykryto nową wersję Ripplo. Zaktualizować teraz?', updateAskWeb: 'Wykryto nową wersję Ripplo. Otworzyć stronę wydania?', updateNow: 'Aktualizuj', later: 'Później', peerVerified: '{name} zweryfikował(a) już twój klucz: {method}', unsend: 'Cofnij wysłanie', unsendTitle: 'Cofnąć wysłanie wiadomości?', unsendText: 'Zniknie u ciebie i u drugiej osoby. Jeśli jej telefon jest poza zasięgiem, zniknie, gdy wróci w zasięg.', you: 'Ty', callStats: 'Wysłano {sent} · odebrano {recv} · odtworzono {played} · błędy {errors}', callAction: 'Zadzwoń', incomingCall: 'Połączenie przychodzące', calling: 'Dzwonię…', callConnecting: 'Łączenie…', callAnswer: 'Odbierz', callDecline: 'Odrzuć', callEnd: 'Zakończ połączenie', callMute: 'Wycisz', callUnmute: 'Włącz mikrofon', call_ended: 'Połączenie zakończone', call_missed: 'Nieodebrane połączenie', call_noanswer: 'Brak odpowiedzi', call_declined: 'Połączenie odrzucone', call_busy: 'Zajęty', call_cancelled: 'Połączenie anulowane', call_lost: 'Utracono połączenie', call_mic: 'Mikrofon niedostępny', call_unreachable: 'Nie udało się połączyć z kontaktem', callLog: 'Połączenie, {time}', err_call_busy: 'Już prowadzisz rozmowę', err_media_locked: 'Zdjęcia, filmy i wiadomości głosowe możesz wysyłać dopiero po odpowiedzi tej osoby', err_call_no_contact: 'Połączenia działają z kontaktami, które zaakceptowałeś/aś lub do których pisałeś/aś', err_call_no_link: 'Możesz dzwonić tylko do telefonów połączonych bezpośrednio z tobą', err_call_unsupported: 'To urządzenie nie obsługuje połączeń',
  findPlaceholder: 'Szukaj po pełnej nazwie lub ID', find: 'Szukaj', findHint: 'Nazwa idzie tylko jako krótki skrót. Ukrywa ją przed przypadkowym obserwatorem, ale nie przed kimś, kto ją zgadnie. Fragmenty nazwy nie pasują.', searchResults: 'Wyniki wyszukiwania', noResults: 'Nikt nie odpowiedział na tę nazwę ani ID', media: 'Multimedia', noMedia: 'W tym czacie nie ma jeszcze zdjęć ani filmów', shareTo: 'Wyślij do…', shareTooLong: 'Ten tekst jest za długi na jedną wiadomość', noSound: 'Nie nagrano dźwięku. Sprawdź mikrofon.', discoverable: 'Widoczność w Znajdź osoby', discoverableHint: 'Po wyłączeniu telefony w pobliżu i wyszukiwanie w meshu cię nie widzą. Twoje kontakty nadal tak.',
  invite: 'Zaproś', invited: 'Zaproszono', inviteTitle: 'Zaprosić {name}?', inviteText: 'Osoba dostanie prośbę i może ją przyjąć lub odrzucić. Napiszesz do niej po akceptacji.', inviteSent: 'Wysłano zaproszenie', requests: 'Zaproszenia', wantsToAdd: 'chce cię dodać', inviteNotifyTitle: 'Zaproszenie do kontaktów', inviteNotifyBody: 'Masz zaproszenie do kontaktów od użytkownika {name}', accept: 'Akceptuj', decline: 'Odrzuć',
  changeName: 'Zmień nazwę', save: 'Zapisz', err_bad_name: 'Podaj prawidłową nazwę', err_install_permission: 'Zezwól Ripplo na instalowanie aplikacji w otwartych ustawieniach, potem znów dotknij Zainstaluj', upToDate: 'Masz najnowszą wersję', changePhoto: 'Zmień zdjęcie profilowe', removePhoto: 'Usuń', photoHint: 'Zdjęcie wysyłane jest tylko w zaszyfrowanych wiadomościach do osób, z którymi piszesz.', err_bad_avatar: 'Nie można użyć tego zdjęcia',
  profile: 'Profil', search: 'Szukaj', addContact: 'Dodaj kontakt', newChat: 'Nowy czat', newGroup: 'Nowa grupa', groupName: 'Nazwa grupy', noContacts: 'Brak kontaktów. Najpierw dodaj znajomego.',
  emptyChats: 'Dodaj znajomego kodem QR lub linkiem zaproszenia', voiceMessage: 'Wiadomość głosowa', photoMessage: 'Zdjęcie', videoMessage: 'Wideo', unread: 'Nieprzeczytane wiadomości',
  myCode: 'Mój kod', scan: 'Skanuj', pasteLink: 'Wklej link', shareLink: 'Udostępnij link', copied: 'Skopiowano link', cameraDenied: 'Kamera niedostępna',
  scanSafetyHint: 'Zeskanuj kod QR numeru bezpieczeństwa z ekranu kontaktu drugiej osoby.',
  verifiedOk: 'Klucze zostały poprawnie zweryfikowane', verifyMismatch: 'Numery bezpieczeństwa się nie zgadzają', verifyFailed: 'Nie udało się zweryfikować przez sieć',
  err_bad_link: 'To nie jest prawidłowy link Ripplo', err_bad_checksum: 'Link jest uszkodzony lub zmodyfikowany', err_self: 'To twój własny kod',
  deepLinkConfirm: 'Dodać kontakt z tego linku? Jego klucz pozostanie niezweryfikowany, dopóki go nie sprawdzisz.',
  lastRefreshed: 'Ostatnio odświeżono {time}', nextTonight: 'następne dziś w nocy', refresh: 'Odśwież', nearby: 'W pobliżu', inMesh: 'W zasięgu sieci',
  nobodyNearby: 'Nikogo teraz w pobliżu', nobodyInMesh: 'Nikogo jeszcze nie znaleziono. Stuknij odśwież.', hops_one: '1 przeskok stąd', hops_few: '{n} przeskoki stąd', hops_many: '{n} przeskoków stąd', inContacts: 'Już w kontaktach',
  addPersonTitle: 'Dodać {name}?', added: 'Dodano do kontaktów',
  unverifiedWarning: 'Nie udało się zweryfikować tego klucza publicznego. Nie masz pewności, że osoba po drugiej stronie jest tą, którą dodałeś/aś.',
  conflictWarning: 'Możliwa podmiana klucza: ktoś o tej nazwie używa innego klucza. Nie ufaj tej rozmowie, dopóki nie sprawdzisz osobiście.',
  conflict: 'Możliwa podmiana klucza', verified: 'Zweryfikowano', notVerified: 'Niezweryfikowany', outOfRange: 'Poza zasięgiem',
  method_nearby: 'Potwierdzono przez bezpośrednie łącze', method_qr: 'Porównano kodem QR', method_manual: 'Potwierdzone przez ciebie', method_none: '',
  safetyNumber: 'Numer bezpieczeństwa', safetyHint: 'Porównaj te cyfry lub kod QR z drugą osobą, spotykając się osobiście.',
  verifyQr: 'Zweryfikuj kodem QR', retryNearby: 'Ponów sprawdzenie w pobliżu', retryMesh: 'Ponów przez sieć', imSure: 'Jestem pewien, że to ta osoba', imSureConfirm: 'Potwierdź tylko, jeśli porównałeś/aś numer bezpieczeństwa inną drogą.',
  checking: 'Sprawdzanie…', deleteContact: 'Usuń kontakt', deleteContactConfirm: 'Kontakt i jego czat zostaną usunięte z tego telefonu.',
  members: 'Członkowie: {n}', contactInfo: 'Informacje o kontakcie', encryptedLine: 'Wiadomości są szyfrowane end-to-end protokołem Signal.', devCryptoWarn: 'Wersja deweloperska: wiadomości NIE są szyfrowane',
  image: 'Obraz', play: 'Odtwórz', playFailed: 'Nie można odtworzyć wiadomości głosowej', micDenied: 'Mikrofon niedostępny', fileTooBig: 'Plik jest większy niż 20 MB',
  attach: 'Dołącz zdjęcie lub film', message: 'Wiadomość', recordVoice: 'Nagraj wiadomość głosową',
  status_encrypting: 'Szyfrowanie', status_sending: 'Wysyłanie', status_delivered: 'Dostarczono', status_failed: 'Nie udało się wysłać', status_out_of_range: 'Poza zasięgiem sieci', status_received: '',
  viaPhones_one: 'Dostarczono przez 1 telefon', viaPhones_few: 'Dostarczono przez {n} telefony', viaPhones_many: 'Dostarczono przez {n} telefonów', outOfMeshRange: 'Kontakt jest poza zasięgiem sieci',
  appearance: 'Wygląd', themeMode: 'Motyw', mode_system: 'Systemowy', mode_dark: 'Ciemny', mode_light: 'Jasny', accent: 'Kolor akcentu', customColor: 'Własny kolor', background: 'Tło', none: 'Brak', language: 'Język',
  network: 'Sieć', noNeighbors: 'Brak połączonych telefonów', connected: 'Połączono', backgroundRelay: 'Przekazywanie w tle', relayHint: 'Przekazywane wiadomości nigdy nie są wyświetlane',
  security: 'Bezpieczeństwo', integrity: 'Integralność aplikacji', integrityOk: 'Oficjalna wersja', integrityBad: 'Zmodyfikowana wersja', integrityUnknown: 'Jeszcze nie sprawdzono',
  dbEncryption: 'Szyfrowanie bazy danych', dbSecure: 'Klucz w systemowym magazynie kluczy', dbInsecure: 'Pamięć przeglądarki: klucz nie jest chroniony przez system', signal: 'Protokół Signal', signalInfo: 'Szyfrowanie end-to-end',
  updates: 'Aktualizacje', currentVersion: 'Obecna wersja', latestVersion: 'Najnowsza wersja', checkNow: 'Sprawdź teraz', install: 'Zainstaluj aktualizację', openRelease: 'Otwórz stronę wydania', autoUpdate: 'Aktualizuj automatycznie',
  backup: 'Kopia zapasowa', backupWeb: 'Kopie zapasowe są dostępne w aplikacji Ripplo na telefonie.', backupIntro: 'Zapisz zaszyfrowaną kopię rozmów i kluczy. Otworzy ją tylko twój kod odzyskiwania.',
  backupEnable: 'Włącz kopię zapasową', backupNow: 'Utwórz kopię teraz', showCode: 'Pokaż kod odzyskiwania', backupOff: 'Wyłącz kopię zapasową', backupOffConfirm: 'Ten telefon zapomni kod odzyskiwania i folder kopii automatycznych. Zapisane już pliki kopii pozostaną na miejscu.',
  backupNever: 'Brak kopii zapasowej', backupLast: 'Ostatnia kopia: {time}', backupFolder: 'Folder: {name}', backupNoFolder: 'Brak folderu kopii automatycznych', chooseFolder: 'Wybierz folder kopii', notNow: 'Nie teraz', backupDone: 'Zapisano kopię',
  codeTitle: 'Twój kod odzyskiwania', codeWarn: 'Przechowuj te kody w bezpiecznym miejscu, na przykład w menedżerze haseł. Bez nich nie otworzysz kopii zapasowej.',
  codeWritten: 'Zapisałem kod', codeCheckTitle: 'Sprawdź kod', codeCheckHint: 'Wpisz ostatnią grupę cyfr (szóstą), aby potwierdzić, że kod został zapisany.', codeMismatch: 'To się nie zgadza', continue: 'Dalej', done: 'Gotowe',
  folderTitle: 'Kopia automatyczna', folderHint: 'Wybierz folder, a Ripplo zapisze w nim świeżą kopię po otwarciu aplikacji, najwyżej raz dziennie. Każda nowa kopia zastępuje poprzednią, więc zawsze jest jeden plik.',
  restoreFromBackup: 'Przywróć z kopii zapasowej', restoreHint: 'Wpisz 30-cyfrowy kod odzyskiwania, a potem wybierz plik kopii.', recoveryCode: 'Kod odzyskiwania', restore: 'Przywróć',
  bk_bad_code: 'Ten kod nie otwiera tej kopii', bk_bad_file: 'To nie jest prawidłowa kopia Ripplo albo plik jest uszkodzony', bk_need_factor: 'Ta kopia wymaga drugiego składnika — ta wersja jeszcze go nie obsługuje', bk_auth_failed: 'Uwierzytelnienie nie powiodło się', bk_failed: 'Coś poszło nie tak',
  appLock: 'Blokada aplikacji', appLockHint: 'Wymagaj odcisku palca, twarzy lub blokady ekranu przy otwarciu Ripplo i ukryj treść w przełączniku aplikacji', unlock: 'Odblokuj', unlockReason: 'Odblokuj Ripplo', locked: 'Ripplo jest zablokowane',
  undecryptable: 'Nie udało się odszyfrować wiadomości od {name} — poproś o ponowne wysłanie',
  about: 'O aplikacji', tagline: 'Komunikator mesh działający bez internetu, z szyfrowaniem end-to-end', license: 'Licencja', contributors: 'Współtwórcy', githubProfile: 'Profil GitHub'
}

const dict = { en, pl }
const KEY = 'ripplo.lang'
let saved
try { saved = localStorage.getItem(KEY) } catch {}
export const locale = ref(saved || (navigator.language?.startsWith('pl') ? 'pl' : 'en'))

export function setLocale(l) {
  locale.value = l
  try { localStorage.setItem(KEY, l) } catch {}
  document.documentElement.lang = l
}

export function t(key, params = {}) {
  const plural = typeof params.n === 'number' ? `${key}_${new Intl.PluralRules(locale.value).select(params.n)}` : null
  const s = (plural && (dict[locale.value][plural] ?? en[plural])) ?? dict[locale.value][key] ?? en[key] ?? key
  return s.replace(/\{(\w+)\}/g, (_, k) => params[k] ?? '')
}
