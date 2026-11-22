# Projekt interfejsu Ripplo

[🇬🇧 English](DESIGN.md) | 🇵🇱 Polski

Wygląd komunikatora (Signal / WhatsApp), podejście mobile-first, domyślnie ciemny. Ikony: `lucide-vue-next`,
obrys 1.75, 22 px. Czcionka: stos systemowy (`-apple-system, "SF Pro Text", Roboto, Inter, sans-serif`).
Teksty interfejsu są w `src/i18n.js` (`en`, `pl`; język urządzenia, domyślnie `en`).

## Tokeny (zmienne CSS w `:root`)

| token | ciemny | jasny |
|-------|--------|-------|
| `--bg` | `#0b0b0c` | `#ffffff` |
| `--surface` | `#161617` | `#f4f4f6` |
| `--surface-2` | `#1f1f21` | `#ebebef` |
| `--border` | `#2a2a2d` | `#e2e2e7` |
| `--text` | `#f2f2f3` | `#111114` |
| `--text-2` | `#a1a1a6` | `#6b6b73` |
| `--warn` | `#f5b544` | `#b7791f` |
| `--danger` | `#ef5350` | `#d32f2f` |
| `--ok` | `#3ecf8e` | `#1f9d63` |

`--accent` (wybór użytkownika) i `--on-accent` (biały lub `#111`, zależnie od luminancji akcentu wg WCAG).
`--accent-soft` = akcent z 16 % przezroczystości (aktywna zakładka, zaznaczone wiersze).
`--glow` = kolor gradientu tła (lub przezroczysty): każda strona ma
`background: linear-gradient(180deg, color-mix(in srgb, var(--glow) 55%, transparent) 0, transparent 340px), var(--bg)`.

Próbki akcentu: zielony `#22c55e`, morski `#14b8a6`, niebieski `#4f9cf9` (domyślny), lawendowy `#a78bfa`,
różowy `#e467b0`, koralowy `#ea6a5f`, pomarańczowy `#e67e22`, szary `#9ca3af`, własny (tęczowa stożkowa próbka →
natywne `<input type="color">`).
Próbki gradientu: brak (ukośna kreska), fioletowy `#5b2ea6`, granatowy `#1e3a8a`, morski `#0f5257`,
śliwkowy `#7a1f4f`, brązowy `#6b3a0a`, łupkowy `#3d4552`.
Tryb motywu: segmentowa pigułka `Systemowy | Ciemny | Jasny`, wybrany segment wypełniony akcentem.
Wybrana próbka: obwódka 2 px w `--text` z odstępem 3 px. Wszystkie preferencje motywu w localStorage.

Promienie: karty 14, wiersze 12, dymki 18 (narożnik z ogonkiem 6), pigułki 999. Skala odstępów 4/8/12/16/24.
Strefy bezpieczne: `env(safe-area-inset-*)` w nagłówku i pasku zakładek.

## Powłoka

- Nagłówek z dużym tytułem na każdej zakładce (28/700): z lewej własny awatar (otwiera profil/QR), z prawej przyciski z ikonami.
- Pływający pasek zakładek w kształcie pigułki na dole (surface, obramowanie 1 px, rozmycie): **Czaty**, **Ludzie**,
  **Ustawienia**. Aktywny element: ikona w kolorze akcentu + pigułka `--accent-soft` za nią. Ustawienia pokazują
  czerwoną kropkę, gdy dostępna jest aktualizacja lub kontrola integralności się nie powiodła.
- Bramka uprawnień (blokująca, pełny ekran przed wszystkim innym): logo, jednozdaniowe wyjaśnienie po co, lista
  wymaganych uprawnień z plakietkami statusu (Bluetooth, Wi-Fi w pobliżu / lokalizacja, Powiadomienia) i
  jeden przycisk **Przyznaj uprawnienia**, który po pozostałych uprawnieniach otwiera też systemowe okno zwolnienia z optymalizacji baterii (wiersz „Zezwól na przekazywanie w tle” pokazuje stan, ale nigdy nie blokuje). Na liście są też wiersz Mikrofon i, na Androidzie 14+, wiersz „Ekran połączenia na ekranie blokady” (specjalny dostęp do powiadomień pełnoekranowych); prosi o nie ten sam przycisk i żaden nie blokuje. Ekran pojawia się też raz przy następnym starcie u osób, które mają już wymagane uprawnienia, ale brakuje im któregoś z tych dodatków; wtedy przycisk „Nie teraz” pozwala przejść dalej i potem nie wraca już dla dodatków.
- Onboarding: pole na imię + utworzenie tożsamości („Twoje klucze powstają na tym telefonie i nigdy go nie opuszczają”).

## Zakładka Czaty

Ikony w nagłówku: QR (skanuj/dodaj), ołówek (nowy czat / nowa grupa). Pigułka wyszukiwania pod tytułem.
Opcjonalna sekcja „Przypięte”. Wiersz 68 px: awatar 48 (inicjały na kolorze z hasha, ikona grupy dla grup),
nazwa 16/600, podgląd 14 `--text-2` (głosowa: ikona mikrofonu + „Wiadomość głosowa”), czas 12 po prawej, znaczek nieprzeczytanych
(akcent, `--on-accent`). Niezweryfikowane kontakty mają mały bursztynowy znaczek tarczy na awatarze.
Pod pigułką wyszukiwania, gdy ktoś cię zaprosił, sekcja **Zaproszenia · n**: awatar z bursztynową tarczą, nazwa,
„chce cię dodać”, **Odrzuć** (ghost) i **Akceptuj**.
Stan pusty: ilustracja fal + „Dodaj znajomego kodem QR lub linkiem zaproszenia”.

## Widok czatu

- Nagłówek: wstecz, awatar, nazwa, podlinia = weryfikacja + trasa: `✓ Zweryfikowano · LAN` / `⚠ Niezweryfikowany`
  / `Poza zasięgiem`. Stuknięcie → strona kontaktu.
- Bursztynowy baner pod nagłówkiem, dopóki kontakt jest niezweryfikowany: tekst z ARCHITECTURE §5 + trzy przyciski
  (Zweryfikuj kodem QR / Ponów przez sieć / Jestem pewien, że to ta osoba). Czerwony wariant dla ostrzeżenia o podmianie klucza.
- Dymki: przychodzące `--surface-2`, wychodzące `--accent` z tekstem `--on-accent`, maks. 78 % szerokości,
  wypełnienie 12/16, czas 11 wewnątrz w prawym dolnym rogu. Separatory dni jako wyśrodkowane pigułki.
- Status wychodzącej pod/wewnątrz dymka (ikona + etykieta po stuknięciu):
  encrypting (obracająca się kłódka), sending (pojedynczy ptaszek + `%` dla załączników), delivered (podwójny ptaszek,
  „przez 3 telefony”), out_of_range (czerwona chmura-off + „Poza zasięgiem sieci” + **Ponów**), failed.
- Pisanie: gdy druga osoba pisze, na końcu logu jest dymek jak przychodzący z trzema kropkami (7 px, naprzemienne podskoki co 1,2 s, nieruchome przy ograniczonym ruchu).
- Multimedia: miniatury obrazów/wideo maks. 240, zaokrąglone 14; wiadomość głosowa = przycisk odtwarzania + słupki fali +
  czas trwania. Przychodzące multimedia pojawiają się dopiero po otrzymaniu w całości.
- Odpowiedź: przeciągnij wiadomość w bok (w dowolną stronę, 56 px) i puść; pojawia się ikona odpowiedzi, dymek sprężynuje z powrotem, a nad
  polem pisania pasek odpowiedzi (autor + fragment + X). Dymek odpowiedzi pokazuje blok cytatu (autor, dwie linie), a stuknięcie w niego
  przewija do oryginału i go podświetla.
- Załączniki: `+` wybiera do 10 zdjęć lub filmów (wielokrotny wybór); czekają jako miniatury 64 px z X nad polem pisania i nic nie jest wysyłane
  do czasu Wyślij. Pole tekstowe staje się wtedy podpisem ostatniego elementu; odpowiedź idzie z pierwszym.
- Pole pisania w kształcie pigułki: `+` (zdjęcie/wideo, maks. 20 MB), pole tekstowe z automatycznym powiększaniem (licznik `n/1000` pojawia się od
  900, czerwony przy 1000), przycisk mikrofonu przy pustym polu (stuknij, by nagrywać; podczas nagrywania: anuluj, czerwona kropka z czasem, kreski poziomu na żywo, wyślij), przycisk wysyłania przy tekście.
- Każdy czat pokazuje na górze linię z kłódką: „Wiadomości są szyfrowane end-to-end protokołem Signal.”

## Zakładka Ludzie

Nagłówek: ikona odświeżania (kręci się podczas DISCOVER), „Ostatnio odświeżono 03:12 · następne dziś w nocy”.
Sekcje: **W pobliżu** (bezpośredni sąsiedzi, na żywo, z jedną plakietką na każde wykryte medium (`BLE`, `LAN`, `Wi-Fi Direct`, ...), używane łącze oznaczone ptaszkiem, i
prędkością), **W zasięgu sieci** (odpowiedzi DISCOVER, z liczbą przeskoków). Nad sekcjami jest pole szukania (pełna nazwa lub ID, w sieci tylko skrót); wyniki zastępują listę z meshu, a X ją przywraca.
Akcja w wierszu: **Zaproś** → arkusz potwierdzenia
(„Osoba dostanie prośbę i może ją przyjąć lub odrzucić”). Po wysłaniu wiersz pokazuje plakietkę **Zaproszono** (**Ponów**, gdy
doręczenie się nie udało); osoba, która cię zaprosiła, ma **Akceptuj**. Kontakty już dodane pokazują ptaszek.

## Ekran połączenia

Przycisk słuchawki w nagłówku czatu (ukryty dla grup i oczekujących próśb, zablokowany podczas rozmowy) zaczyna
połączenie; wymaga łącza bezpośredniego. Arkusz na cały ekran nad wszystkim: awatar 112, nazwa, stan (Dzwonię… /
Połączenie przychodzące / Łączenie… / licznik / powód zakończenia), potem okrągłe przyciski 68 px: przychodzące = czerwony
Odrzuć i zielony Odbierz (dzwonek i wibracja zgodnie z trybem dźwięku telefonu; tylko ekran, gdy jest cichy lub w trybie Nie przeszkadzać), w innym razie przełącznik Wycisz i czerwony Zakończ. Stan zakończenia
zostaje 2,5 s.

## Arkusz udostępniania („Wyślij do…”)

Pojawia się, gdy inna aplikacja udostępni Ripplo tekst, zdjęcie, wideo lub dźwięk (menu udostępniania systemu → Ripplo).
Linia podglądu (fragment tekstu lub rodzaj multimediów), przewijana lista czatów i grup z awatarami, Anuluj. Stuknięcie
czatu wysyła od razu i otwiera ten czat.

## Arkusz dodawania kontaktu

Zakładki: **Mój kod** (animowany QR linku zaproszenia, około 6 klatek po 700 ms z kropkami postępu i podpowiedzią, by trzymać drugi telefon na nim do końca, + ripploId + przycisk Zaproś znajomego (udostępnia tekst i link webowy; linijka podpowiedzi mówi, że kontakt zostanie dodany jako niezweryfikowany) przez Web Share API /
kopiowanie), **Skanuj** (wizjer kamery z zaokrągloną maską; ciągłe automatyczne wykrywanie, natywny `BarcodeDetector`, gdy działa, w przeciwnym razie ZXing skompilowany do WebAssembly (jsQR tylko podczas ładowania); bez przycisku. Trafienie od razu zamyka arkusz z komunikatem „Klucze zostały poprawnie zweryfikowane” lub „Dodano do kontaktów” i krótką wibracją), **Wklej link**.

## Strona kontaktu

Gdy klucz jest zweryfikowany (i nie ma konfliktu), numer bezpieczeństwa, jego QR oraz przyciski Zweryfikuj / Ponów są ukryte;
wracają, gdy weryfikacja zniknie lub oznaczony zostanie konflikt. Sekcja **Multimedia** wypisuje wszystkie zdjęcia i filmy
z czatu (siatka 3 kolumny, najnowsze pierwsze, kafelki wideo z ikoną odtwarzania); stuknięcie otwiera podgląd na cały ekran.

Awatar, nazwa, ripploId, karta weryfikacji (stan + metoda + data), numer bezpieczeństwa (12×5 cyfr
czcionką monospace) + jego QR, akcje: Zweryfikuj kodem QR, Ponów sprawdzenie w pobliżu, Jestem pewien, że to ta osoba, Usuń kontakt.

## Ustawienia (lista zgrupowanych kart, jak w referencyjnej aplikacji muzycznej)

- **Profil**: przełącznik „Widoczność w Znajdź osoby”, stuknięcie w nazwę edytuje ją w miejscu (Zapisz / Anuluj; nie ma osobnego przycisku), awatar do kliknięcia (wybór zdjęcia, kadr do kwadratu; gdy ustawione, mały przycisk **Wyczyść profilowe** wyśrodkowany tuż pod nim), imię, ripploId, Mój QR. Zdjęcia widać na liście czatów, w nagłówku czatu, na stronie kontaktu, w Szukaj osób i Nowy czat; inaczej inicjały.
- **Wygląd**: kontrolka segmentowa trybu, próbki Koloru akcentu, próbki Tła (gradient),
  Język.
- **Sieć**: lista transportów na żywo ze stanem + zmierzoną prędkością; przełącznik Przekazywania w tle
  (usługa pierwszoplanowa Androida); „Przekazywane wiadomości nigdy nie są wyświetlane”. Zwolnienie z optymalizacji baterii jest pytane tylko na ekranie uprawnień.
- **Bezpieczeństwo**: integralność aplikacji (Oficjalna wersja ✓ / Zmodyfikowana wersja ✗ / Jeszcze nie sprawdzono), stan
  szyfrowania bazy danych, informacje o protokole Signal.
- **Aktualizacje**: obecna wersja, najnowsza wersja, Sprawdź teraz (przycisk w kolorze akcentu, żeby był dobrze widoczny; napis zmienia się na „Sprawdzanie…” na co najmniej 0,8 s, bez linii „masz najnowszą wersję”), przełącznik Aktualizuj automatycznie (Android), postęp.
- **O aplikacji**: nazwa aplikacji + hasło, wersja (5 stuknięć w ten wiersz w ciągu 2 s włącza lub wyłącza **tryb dewelopera**, który dodaje kartę **Dla deweloperów** ze stanem transportów, informacją o obsłudze BLE Coded PHY w telefonie (bez przełącznika), wierszem dla każdego sąsiada do wymuszenia połączenia jednym standardem (LAN, Wi-Fi Direct, Wi-Fi Aware, BLE 1M / Coded PHY) lub jego zamknięcia, dziennikiem diagnostycznym i przyciskami Odśwież / Kopiuj log / Wyczyść log), link do GitHuba, Licencja, karty **Współtwórcy**: awatar
  (awatar z GitHuba online, inicjały offline), login pogrubiony, podtekst „Profil GitHub”, ikona linku zewnętrznego
  po prawej; karta = `--surface`, obramowanie 1 px, promień 14.

## Powiadomienia

Android: glif na pasku stanu to jednobarwne `ic_stat_ripplo` w kolorze akcentu, a kolorowa ikona aplikacji (`ic_notification_large`, wyrenderowana z
`public/icon.svg` przez `scripts/icons.sh`) jest dużą ikoną każdego powiadomienia, natywnego i lokalnego. iOS zawsze pokazuje ikonę aplikacji (`AppIcon`,
ta sama grafika co `public/icon_ios.png`), której nie można zmienić dla pojedynczego powiadomienia.
Tytuł to nazwa nadawcy (grupy: „grupa: nazwa”), treść to tekst wiadomości, „Wysłano zdjęcie” lub „Wysłano załącznik”; zaproszenia mają
„Zaproszenie do kontaktów”; połączenia przychodzące używają małego natywnego pełnoekranowego ekranu połączenia (nazwa, Odbierz, Odrzuć), który może pojawić się nad ekranem blokady bez odsłaniania czatów; Odbierz łączy od razu bez odblokowywania: nad blokadą widać tylko ekran rozmowy (ekran zostaje włączony), a czaty zostają ukryte do odblokowania telefonu. Na ekranie blokady wiadomości pokazują tylko „Nowa wiadomość”.
