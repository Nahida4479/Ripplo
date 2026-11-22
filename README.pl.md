# Ripplo

[🇬🇧 English](README.md) | 🇵🇱 Polski

<p align="center"><img src="./public/icon_android.png" width="120"></p>

<p align="center" style="text-align: center; font-weight: bold;">Komunikator mesh działający offline, z szyfrowaniem end-to-end. Bez serwerów, bez kont, bez internetu: wiadomości przeskakują z telefonu na telefon przez Bluetooth i Wi-Fi.</p>

<div align="center">
<img src="https://img.shields.io/badge/Ripplo-Offline_Mesh_Messenger-blue">
<img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
<img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
<img src="https://img.shields.io/badge/Vue-3-4FC08D?logo=vue.js&logoColor=white" alt="Vue 3">
<img src="https://img.shields.io/badge/Capacitor-8-119EFF?logo=capacitor&logoColor=white" alt="Capacitor 8">
<img src="https://img.shields.io/badge/libsignal-PQXDH-3A76F0?logo=signal&logoColor=white" alt="libsignal PQXDH">
<a href="./LICENSE"><img src="https://img.shields.io/github/license/Nahida4479/Ripplo"></a>
<img src="https://github.com/Nahida4479/Ripplo/actions/workflows/build.yml/badge.svg">
</div>

# Funkcje

- **Bez serwerów, kont i numerów telefonu, nie potrzeba połączenia z internetem.**
- Telefony tworzą sieć mesh: każdy telefon w zasięgu może przekazywać wiadomości innym.
- Szyfrowanie end-to-end oficjalną biblioteką Signal `libsignal` dla czatów, grup, wiadomości głosowych, rozmów, zdjęć i filmów. Ochrona postkwantowa: wymiana kluczy PQXDH (X25519 + Kyber-1024 / ML-KEM).
- Osoby przekazujące wiadomość nie widzą, kto napisał wiadomość.
- Zaszyfrowana lokalna baza danych, klucz przechowywany w Android Keystore / iOS Keychain.
- Kilka transportów naraz (BLE, Bluetooth, LAN, Wi-Fi Direct, Wi-Fi Aware, Apple Multipeer). Zawsze używane jest najszybsze działające łącze.
- Dodawanie znajomych kodem QR, linkiem zaproszenia (bez udziału serwera) lub w zakładce Znajdź osoby.
- Weryfikacja kluczy: porównanie kodów QR osobiście lub potwierdzając ręcznie.
- Przekazywanie działa przy wyłączonym ekranie.
- Zdjęcia i filmy (do 20 MB).
- Różnorodne motywy aplikacji.
- Sprawdzanie sum kontrolnych podczas aktualizacji.
- Język Polski i Angielski.

# Jak używać?
1. [Zainstaluj Ripplo](#instalacja).
2. Podaj nazwę użytkownika. Klucze są generowane na telefonie i nigdy go nie opuszczają.
3. Przyznaj uprawnienia (Bluetooth, Wi-Fi w pobliżu / lokalizacja, powiadomienia), a na Androidzie zezwól na przekazywanie w tle.
4. Dodaj znajomego: otwórz ikonę QR w zakładce **Czaty** i zeskanuj jego kod, wklej link zaproszenia albo wybierz go w zakładce **Znajdź osoby**.
5. [Zweryfikuj klucz](#weryfikacja-kontaktu) dodanej osoby lub poczekaj na automatyczną weryfikację (jeżeli jesteście w pobliżu).
6. Napisz wiadomość. Jeśli znajomy jest poza bezpośrednim zasięgiem, przekażą ją inne telefony z Ripplo znajdujące się pomiędzy wami.

# Jak to działa

## Transporty

Każdy transport przenosi ten sam strumień bajtów, więc jeden sąsiad może być osiągalny jednocześnie przez kilka łączy (na przykład Bluetooth Low Energy i WiFi-Direct). Co minutę aplikacja mierzy prędkość każdego łącza i zawsze wysyła przez najszybciej działające.

| Medium | Android | iOS | Android <-> iOS | Wykrywanie |
|---|---|---|---|---|
| BLE (GATT) | tak | tak | tak | usługa GATT Ripplo |
| Bluetooth L2CAP (BLE CoC) | tak (Android 10+) | tak | tak | PSM odczytywany przez GATT |
| LAN | tak | tak | tak | DNS-SD `_ripplo._tcp` w bieżącej sieci Wi-Fi / hotspocie |
| Wi-Fi Direct | tak | nie | nie | Wi-Fi P2P DNS-SD |
| Wi-Fi Aware | tak (Android 8+, wymaga wsparcia sprzętowego) | nie | nie | usługa NAN `ripplo` |
| Apple Multipeer | nie | tak | nie | MultipeerConnectivity |


## Szyfrowanie

- **Protokół Signal** w oficjalnej bibliotece `libsignal` 0.108.5, używanej natywnie (Java na Androidzie, Swift na iOS): PQXDH (X25519 + Kyber-1024 / ML-KEM) do nawiązywania sesji i potrójny ratchet SPQR (Double Ratchet + ratchet postkwantowy) dla każdej wiadomości: tekstu, załączników, aktualizacji grup. Grupy są szyfrowane parami dla każdego członka. Klucze prywatne nigdy nie trafiają do WebView.
- **Sealed sender**: tożsamość nadawcy jest zapakowana w dodatkową warstwę, którą może otworzyć tylko odbiorca, więc przekaźniki nie dowiadują się, kto z kim rozmawia.
- **Załączniki** (wiadomości głosowe, zdjęcia, filmy) są szyfrowane raz losowym kluczem, dzielone na fragmenty po 32 KiB i wysyłane osobno. Klucz podróżuje w wiadomości zaszyfrowanej protokołem Signal po potwierdzeniu odbioru wszystkich fragmentów, a odbiorca przed odszyfrowaniem sprawdza skrót.
- **Dane w spoczynku**: lokalna baza danych jest szyfrowana AES-GCM kluczem przechowywanym w systemowym magazynie kluczy.

Przekaźniki tylko przekazują nieprzezroczyste pakiety. Nie mogą niczego odczytać, odszyfrować ani przypisać do nadawcy. Odszyfrować może wyłącznie odbiorca.

## Dodawanie znajomych

- **Kod QR**: zeskanuj kod widoczny w **Mój kod**.
- **Link zaproszenia**: `ripplo://add/...` zawiera twoje imię i klucze publiczne (binarna wizytówka v2, około 2,4 KB; kod QR używa poziomu korekcji błędów L). Udostępnia się go jak zwykły tekst, żaden serwer go nie widzi.
- **Zakładka Ludzie**: pyta całą sieć mesh, kto jest w pobliżu. To zalewa sieć mesh pakietami (flood), więc odświeża się automatycznie raz dziennie między 02:00 a 05:00 albo po stuknięciu odśwież.

Osoby dodane z zakładki Ludzie lub z linku zaproszenia są niezweryfikowane (przekaźnik mógł podmienić wizytówkę) i dostają ostrzeżenie, dopóki ich nie zweryfikujesz.

## Weryfikacja kontaktu

| Poziom | Znaczenie |
|---|---|
| W pobliżu (Nearby) | Dowód typu challenge-response przez bezpośrednie łącze: właściciel klucza jest fizycznie w zasięgu. |
| QR | Zeskanowano osobiście kod QR bezpieczeństwa tej osoby. |
| Ręcznie (Manual) | Poręczyłeś/aś sam (np. porównałeś/aś numer bezpieczeństwa w innym komunikatorze). |

Po dodaniu kontaktu aplikacja przez 60 sekund szuka go jako bezpośredniego sąsiada i przeprowadza dowód bliskości. Jeśli się nie powiedzie, możesz zweryfikować kodem QR, ponowić próbę przez sieć mesh albo potwierdzić „Jestem pewien, że to ta osoba”. Sąsiad ogłaszający to samo imię z innym kluczem wywołuje czerwone ostrzeżenie „możliwa podmiana klucza”.

> [!WARNING]
> Dowód bliskości pokazuje, że właściciel klucza jest fizycznie w zasięgu, a nie kim jest. Atakujący, który podmienił twój link i stoi w pobliżu, go przejdzie. Mocną weryfikacją jest porównanie kodu QR lub 60-cyfrowego numeru bezpieczeństwa (safety number) z prawdziwą osobą.

## Jak podróżują wiadomości

- Wiadomości podróżują przeskok po przeskoku: każdy telefon przekazuje pakiet swoim sąsiadom, a gdy trasa zostanie poznana, kolejne pakiety idą już nią.
- Nie ma limitu przeskoków: wiadomość przejdzie przez dowolnie długi łańcuch telefonów.
- Wiadomości nie mogą krążyć w pętli: każdy telefon przekazuje dany pakiet najwyżej raz, a duplikaty są odrzucane odpowiedzią „ślepy zaułek” (dead end) zamiast być przekazywane dalej.
- Jeśli wszystkie ścieżki zawiodą, nadawca widzi „Kontakt jest poza zasięgiem sieci mesh” i może spróbować ponownie. Aplikacja rezygnuje też po 5 minutach bez odpowiedzi.
- Etapy dostarczenia: `encrypting`, `sending`, `delivered` (z liczbą telefonów, przez które przeszła), `out of range`.
- Przychodzące wiadomości są potwierdzane od razu po zapisaniu, więc dostarczanie działa przy wyłączonym ekranie i zamkniętej aplikacji.
- Przekazywanie odbywa się natywnie, więc telefony przekazują wiadomości także w tle.
- Przekazywane wiadomości nigdy nie są wyświetlane i nigdy nie wywołują powiadomienia. Twój telefon nie powie ci, że coś przez niego przeszło.

## Limity

- Tekst: 1000 znaków.
- Załączniki: 20 MB (przed szyfrowaniem), wysyłane we fragmentach.
- Na sąsiada: 200 pakietów/s i 32 MiB w kolejce na łącze; nadmiar jest odrzucany.

## Motywy

Domyślnie ciemny. Przełączaj między Systemowym, Ciemnym i Jasnym, a następnie wybierz kolor akcentu (lub własny) i gradient tła. Preferencje są zapisywane na urządzeniu.

## Aktualizacje i integralność

- Każde wydanie na GitHubie zawiera `Ripplo-vX.Y.Z.apk`, `Ripplo-vX.Y.Z-unsigned.ipa` i plik `SHA256SUMS`.
- Gdy jest internet, aplikacja sprawdza najnowsze wydanie na GitHubie i pokazuje plakietkę aktualizacji. Na Androidzie z włączoną automatyczną aktualizacją pobiera APK, weryfikuje SHA-256 i certyfikat podpisu, a następnie go instaluje.
- Na Androidzie aplikacja liczy skrót własnego zainstalowanego APK i porównuje go z `SHA256SUMS` pasującego wydania. Weryfikuje to także kopie udostępnione przez Quick Share / Nearby Share. Wynik jest w Ustawienia > Bezpieczeństwo.

# Instalacja

## Android

Pobierz `Ripplo-vX.Y.Z.apk` z [Releases](https://github.com/Nahida4479/Ripplo/releases), zweryfikuj go względem `SHA256SUMS` i zainstaluj.

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

## iOS

Wydanie zawiera **niepodpisany** plik IPA (`Ripplo-vX.Y.Z-unsigned.ipa`). Trzeba go zainstalować metodą sideload lub podpisać ponownie własnym Apple ID, na przykład za pomocą [AltStore](https://altstore.io/) lub [SideStore](https://sidestore.io/). Instrukcja krok po kroku dla SideStore: [nahida4479.github.io/Ripplo/pl/#ios](https://nahida4479.github.io/Ripplo/pl/#ios).

# Budowanie ze źródeł

Wymagania: Node.js oraz Android Studio i/lub Xcode dla aplikacji natywnych.

```bash
npm install
npm run dev        # web build
npm test           # run the tests
npm run build      # production web build
npx cap sync       # copy the build into the native projects
```

Następnie otwórz projekt natywny w Android Studio (`android/`) lub Xcode (`ios/App`) i uruchom go.

W wersji webowej (`npm run dev`) nie ma warstwy natywnej: otwórz aplikację w kilku kartach przeglądarki, a utworzą one sieć mesh przez `BroadcastChannel`. Ta wersja używa jawnego zamiennika (`src/mesh/devSignal.js`) zamiast libsignal, więc **nie jest szyfrowana** (interfejs pokazuje czerwone ostrzeżenie), a klucz bazy danych jest przechowywany w localStorage. Używaj jej tylko do rozwoju interfejsu.

# Wydania

Wypchnięcie tagu `vX.Y.Z` uruchamia workflow GitHub Actions (`.github/workflows/build.yml`), który uruchamia testy jednostkowe JVM rdzenia Signal na Androidzie, buduje podpisany APK (tylko arm64-v8a i armeabi-v7a), niepodpisany IPA i `SHA256SUMS`, a następnie publikuje je w wydaniu na GitHubie.

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Wymagane sekrety repozytorium

| Sekret | Opis |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Twój plik keystore zakodowany w base64 |
| `ANDROID_KEYSTORE_PASSWORD` | Hasło do keystore |
| `ANDROID_KEY_ALIAS` | Alias klucza podpisującego |
| `ANDROID_KEY_PASSWORD` | Hasło klucza podpisującego |

Utwórz keystore za pomocą `keytool` i zakoduj go (użyj własnego aliasu i haseł, i nigdy nie commituj keystore):

```bash
keytool -genkeypair -v -keystore ripplo.jks -alias <your-alias> \
  -keyalg RSA -keysize 2048 -validity 10000
base64 -w0 ripplo.jks   # paste the output into ANDROID_KEYSTORE_BASE64
```

Używaj tego samego keystore przy każdym wydaniu: Android instaluje tylko aktualizacje podpisane tym samym certyfikatem.

# Ograniczenia platform

- **iOS w tle**: tylko BLE może przekazywać wiadomości, gdy aplikacja działa w tle.
- **Wi-Fi Direct** i **Wi-Fi Aware** działają tylko na Androidzie.
- **Apple Multipeer** działa tylko na iOS.
- **Android <-> iOS** komunikują się przez BLE, L2CAP i LAN.
- Wi-Fi Aware na iOS wymaga uprawnienia (entitlement) dla płatnego konta deweloperskiego i nie jest jeszcze zaimplementowane.
- Natywne transporty nie były jeszcze testowane w terenie.
- APK zawiera tylko biblioteki `arm64-v8a` i `armeabi-v7a` (bez x86 / x86_64).
- Wersja webowa do developmentu nie ma warstwy natywnej ani prawdziwego szyfrowania.

# Współpraca

- Bez komentarzy w kodzie (JS, Vue, CSS, Java, Swift, Gradle, shell, XML), także bez zakomentowanego kodu. Wyjaśnienia trafiają do `docs/` (po angielsku, z polskim bliźniakiem `*.pl.md`). Jedyny wyjątek to pliki generowane przez narzędzia.
- Nie commituj sekretów: keystore'ów, haseł, `.env`, tokenów ani kluczy prywatnych.

# Współtwórcy

- [Nahida4479](https://github.com/Nahida4479)

# Licencja
Udostępniono na licencji [GNU Affero General Public License v3.0](./LICENSE) (AGPL-3.0-only) © 2026 [nahida4479](https://github.com/Nahida4479).
Możesz używać, modyfikować i udostępniać Ripplo, ale wszystko, co rozpowszechniasz lub udostępniasz innym na jego podstawie, również musi być na AGPL-3.0 z udostępnionym kodem źródłowym. Dostarczane „tak jak jest”, bez gwarancji.
