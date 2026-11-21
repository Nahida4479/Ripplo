import { ref } from 'vue'

const en = {
  chats: 'Chats', people: 'People', settings: 'Settings', navigation: 'Navigation', attention: 'Needs attention',
  cancel: 'Cancel', close: 'Close', confirm: 'Confirm', delete: 'Delete', add: 'Add', create: 'Create', back: 'Back', paste: 'Paste', retry: 'Retry', send: 'Send',
  gateWhy: 'Ripplo talks to nearby phones over Bluetooth and Wi-Fi, so it needs these permissions to work without internet.',
  permBluetooth: 'Bluetooth', permWifi: 'Nearby Wi-Fi / location', permNotifications: 'Notifications',
  perm_granted: 'Allowed', perm_denied: 'Denied', perm_prompt: 'Needed',
  grantPermissions: 'Grant permissions', allowBackground: 'Allow background relay', optional: 'Optional, keeps the mesh alive with the screen off',
  welcome: 'Welcome to Ripplo', onboardHint: 'Your keys are created on this phone and never leave it.', yourName: 'Your name', generateIdentity: 'Generate identity',
  profile: 'Profile', search: 'Search', addContact: 'Add contact', newChat: 'New chat', newGroup: 'New group', groupName: 'Group name', noContacts: 'No contacts yet. Add a friend first.',
  emptyChats: 'Add a friend by QR code or invite link', voiceMessage: 'Voice message', photoMessage: 'Photo', videoMessage: 'Video', unread: 'Unread messages',
  myCode: 'My code', scan: 'Scan', pasteLink: 'Paste link', shareLink: 'Share link', copied: 'Link copied', cameraDenied: 'Camera not available',
  scanSafetyHint: "Scan the other person's safety-number QR code, shown on their contact page.",
  verifiedOk: 'Verified', verifyMismatch: 'Safety numbers do not match', verifyFailed: 'Could not verify over the mesh',
  err_bad_link: 'This is not a valid Ripplo link', err_bad_checksum: 'The link is damaged or was modified', err_self: 'That is your own code',
  deepLinkConfirm: 'Add the contact from this link? Its key stays unverified until you check it.',
  lastRefreshed: 'Last refreshed {time}', nextTonight: 'next tonight', refresh: 'Refresh', nearby: 'Nearby', inMesh: 'In mesh range',
  nobodyNearby: 'Nobody nearby right now', nobodyInMesh: 'Nobody found yet. Tap refresh.', hops_one: '1 hop away', hops_other: '{n} hops away', inContacts: 'In your contacts',
  addPersonTitle: 'Add {name}?', added: 'Contact added',
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
  network: 'Network', noNeighbors: 'No phones connected right now', connected: 'Connected', backgroundRelay: 'Background relay', relayHint: 'Relayed messages are never shown', batteryExemption: 'Allow background activity (battery)',
  security: 'Security', integrity: 'App integrity', integrityOk: 'Official build', integrityBad: 'Modified build', integrityUnknown: 'Not checked yet',
  dbEncryption: 'Database encryption', dbSecure: 'Key kept in the system keystore', dbInsecure: 'Web storage: the key is not protected by the system', signal: 'Signal protocol', signalInfo: 'X3DH + Double Ratchet, end to end',
  updates: 'Updates', currentVersion: 'Current version', latestVersion: 'Latest version', checkNow: 'Check now', install: 'Install update', openRelease: 'Open release page', autoUpdate: 'Update automatically',
  about: 'About', tagline: 'Offline end-to-end encrypted mesh messenger', license: 'License', contributors: 'Contributors', githubProfile: 'GitHub profile'
}

const pl = {
  chats: 'Czaty', people: 'Ludzie', settings: 'Ustawienia', navigation: 'Nawigacja', attention: 'Wymaga uwagi',
  cancel: 'Anuluj', close: 'Zamknij', confirm: 'Potwierdź', delete: 'Usuń', add: 'Dodaj', create: 'Utwórz', back: 'Wstecz', paste: 'Wklej', retry: 'Ponów', send: 'Wyślij',
  gateWhy: 'Ripplo łączy się z pobliskimi telefonami przez Bluetooth i Wi-Fi, więc potrzebuje tych uprawnień, by działać bez internetu.',
  permBluetooth: 'Bluetooth', permWifi: 'Wi-Fi w pobliżu / lokalizacja', permNotifications: 'Powiadomienia',
  perm_granted: 'Zezwolono', perm_denied: 'Odmówiono', perm_prompt: 'Wymagane',
  grantPermissions: 'Przyznaj uprawnienia', allowBackground: 'Zezwól na przekazywanie w tle', optional: 'Opcjonalne, utrzymuje sieć przy wyłączonym ekranie',
  welcome: 'Witaj w Ripplo', onboardHint: 'Twoje klucze powstają na tym telefonie i nigdy go nie opuszczają.', yourName: 'Twoje imię', generateIdentity: 'Utwórz tożsamość',
  profile: 'Profil', search: 'Szukaj', addContact: 'Dodaj kontakt', newChat: 'Nowy czat', newGroup: 'Nowa grupa', groupName: 'Nazwa grupy', noContacts: 'Brak kontaktów. Najpierw dodaj znajomego.',
  emptyChats: 'Dodaj znajomego kodem QR lub linkiem zaproszenia', voiceMessage: 'Wiadomość głosowa', photoMessage: 'Zdjęcie', videoMessage: 'Wideo', unread: 'Nieprzeczytane wiadomości',
  myCode: 'Mój kod', scan: 'Skanuj', pasteLink: 'Wklej link', shareLink: 'Udostępnij link', copied: 'Skopiowano link', cameraDenied: 'Kamera niedostępna',
  scanSafetyHint: 'Zeskanuj kod QR numeru bezpieczeństwa z ekranu kontaktu drugiej osoby.',
  verifiedOk: 'Zweryfikowano', verifyMismatch: 'Numery bezpieczeństwa się nie zgadzają', verifyFailed: 'Nie udało się zweryfikować przez sieć',
  err_bad_link: 'To nie jest prawidłowy link Ripplo', err_bad_checksum: 'Link jest uszkodzony lub zmodyfikowany', err_self: 'To twój własny kod',
  deepLinkConfirm: 'Dodać kontakt z tego linku? Jego klucz pozostanie niezweryfikowany, dopóki go nie sprawdzisz.',
  lastRefreshed: 'Ostatnio odświeżono {time}', nextTonight: 'następne dziś w nocy', refresh: 'Odśwież', nearby: 'W pobliżu', inMesh: 'W zasięgu sieci',
  nobodyNearby: 'Nikogo teraz w pobliżu', nobodyInMesh: 'Nikogo jeszcze nie znaleziono. Stuknij odśwież.', hops_one: '1 przeskok stąd', hops_few: '{n} przeskoki stąd', hops_many: '{n} przeskoków stąd', inContacts: 'Już w kontaktach',
  addPersonTitle: 'Dodać {name}?', added: 'Dodano kontakt',
  unverifiedWarning: 'Nie udało się zweryfikować tego klucza publicznego. Nie masz pewności, że osoba po drugiej stronie jest tą, którą dodałeś.',
  conflictWarning: 'Możliwa podmiana klucza: ktoś o tej nazwie używa innego klucza. Nie ufaj tej rozmowie, dopóki nie sprawdzisz osobiście.',
  conflict: 'Możliwa podmiana klucza', verified: 'Zweryfikowano', notVerified: 'Niezweryfikowany', outOfRange: 'Poza zasięgiem',
  method_nearby: 'Potwierdzono przez bezpośrednie łącze', method_qr: 'Porównano kodem QR', method_manual: 'Potwierdzone przez ciebie', method_none: '',
  safetyNumber: 'Numer bezpieczeństwa', safetyHint: 'Porównaj te cyfry lub kod QR z drugą osobą, spotykając się osobiście.',
  verifyQr: 'Zweryfikuj kodem QR', retryNearby: 'Ponów sprawdzenie w pobliżu', retryMesh: 'Ponów przez sieć', imSure: 'Jestem pewien, że to ta osoba', imSureConfirm: 'Potwierdź tylko, jeśli porównałeś numer bezpieczeństwa inną drogą.',
  checking: 'Sprawdzanie…', deleteContact: 'Usuń kontakt', deleteContactConfirm: 'Kontakt i jego czat zostaną usunięte z tego telefonu.',
  members: 'Członkowie: {n}', contactInfo: 'Informacje o kontakcie', encryptedLine: 'Wiadomości są szyfrowane end-to-end protokołem Signal.', devCryptoWarn: 'Wersja deweloperska: wiadomości NIE są szyfrowane',
  image: 'Obraz', play: 'Odtwórz', playFailed: 'Nie można odtworzyć wiadomości głosowej', micDenied: 'Mikrofon niedostępny', fileTooBig: 'Plik jest większy niż 20 MB',
  attach: 'Dołącz zdjęcie lub film', message: 'Wiadomość', recordVoice: 'Nagraj wiadomość głosową',
  status_encrypting: 'Szyfrowanie', status_sending: 'Wysyłanie', status_delivered: 'Dostarczono', status_failed: 'Nie udało się wysłać', status_out_of_range: 'Poza zasięgiem sieci', status_received: '',
  viaPhones_one: 'Dostarczono przez 1 telefon', viaPhones_few: 'Dostarczono przez {n} telefony', viaPhones_many: 'Dostarczono przez {n} telefonów', outOfMeshRange: 'Kontakt jest poza zasięgiem sieci',
  appearance: 'Wygląd', themeMode: 'Motyw', mode_system: 'Systemowy', mode_dark: 'Ciemny', mode_light: 'Jasny', accent: 'Kolor akcentu', customColor: 'Własny kolor', background: 'Tło', none: 'Brak', language: 'Język',
  network: 'Sieć', noNeighbors: 'Brak połączonych telefonów', connected: 'Połączono', backgroundRelay: 'Przekazywanie w tle', relayHint: 'Przekazywane wiadomości nigdy nie są wyświetlane', batteryExemption: 'Zezwól na działanie w tle (bateria)',
  security: 'Bezpieczeństwo', integrity: 'Integralność aplikacji', integrityOk: 'Oficjalna wersja', integrityBad: 'Zmodyfikowana wersja', integrityUnknown: 'Jeszcze nie sprawdzono',
  dbEncryption: 'Szyfrowanie bazy danych', dbSecure: 'Klucz w systemowym magazynie kluczy', dbInsecure: 'Pamięć przeglądarki: klucz nie jest chroniony przez system', signal: 'Protokół Signal', signalInfo: 'X3DH + Double Ratchet, od końca do końca',
  updates: 'Aktualizacje', currentVersion: 'Obecna wersja', latestVersion: 'Najnowsza wersja', checkNow: 'Sprawdź teraz', install: 'Zainstaluj aktualizację', openRelease: 'Otwórz stronę wydania', autoUpdate: 'Aktualizuj automatycznie',
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
