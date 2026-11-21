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
  jeden przycisk **Przyznaj uprawnienia**; plus nieblokujący wiersz „Zezwól na przekazywanie w tle” (bateria).
- Onboarding: pole na imię + utworzenie tożsamości („Twoje klucze powstają na tym telefonie i nigdy go nie opuszczają”).

## Zakładka Czaty

Ikony w nagłówku: QR (skanuj/dodaj), ołówek (nowy czat / nowa grupa). Pigułka wyszukiwania pod tytułem.
Opcjonalna sekcja „Przypięte”. Wiersz 68 px: awatar 48 (inicjały na kolorze z hasha, ikona grupy dla grup),
nazwa 16/600, podgląd 14 `--text-2` (głosowa: ikona mikrofonu + „Wiadomość głosowa”), czas 12 po prawej, znaczek nieprzeczytanych
(akcent, `--on-accent`). Niezweryfikowane kontakty mają mały bursztynowy znaczek tarczy na awatarze.
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
- Multimedia: miniatury obrazów/wideo maks. 240, zaokrąglone 14; wiadomość głosowa = przycisk odtwarzania + słupki fali +
  czas trwania. Przychodzące multimedia pojawiają się dopiero po otrzymaniu w całości.
- Pole pisania w kształcie pigułki: `+` (zdjęcie/wideo, maks. 20 MB), pole tekstowe z automatycznym powiększaniem (licznik `n/1000` pojawia się od
  900, czerwony przy 1000), przycisk mikrofonu przy pustym polu (przytrzymaj lub stuknij, by nagrywać, z anulowaniem), przycisk wysyłania przy tekście.
- Każdy czat pokazuje na górze linię z kłódką: „Wiadomości są szyfrowane end-to-end protokołem Signal.”

## Zakładka Ludzie

Nagłówek: ikona odświeżania (kręci się podczas DISCOVER), „Ostatnio odświeżono 03:12 · następne dziś w nocy”.
Sekcje: **W pobliżu** (bezpośredni sąsiedzi, na żywo, z plakietkami medium `BLE`, `LAN`, `Wi-Fi Direct` i
prędkością), **W zasięgu sieci** (odpowiedzi DISCOVER, z liczbą przeskoków). Akcja w wierszu: **Dodaj** → arkusz potwierdzenia
z ostrzeżeniem o niezweryfikowanym kluczu. Kontakty już dodane pokazują ptaszek.

## Arkusz dodawania kontaktu

Zakładki: **Mój kod** (duży QR linku zaproszenia + ripploId + przycisk Udostępnij link przez Web Share API /
kopiowanie), **Skanuj** (wizjer kamery z zaokrągloną maską, jsQR), **Wklej link**.

## Strona kontaktu

Awatar, nazwa, ripploId, karta weryfikacji (stan + metoda + data), numer bezpieczeństwa (12×5 cyfr
czcionką monospace) + jego QR, akcje: Zweryfikuj kodem QR, Ponów sprawdzenie w pobliżu, Jestem pewien, że to ta osoba, Usuń kontakt.

## Ustawienia (lista zgrupowanych kart, jak w referencyjnej aplikacji muzycznej)

- **Profil**: awatar do kliknięcia (wybór zdjęcia, kadr do kwadratu; przycisk Usuń gdy ustawione), imię, ripploId, Mój QR. Zdjęcia widać na liście czatów, w nagłówku czatu, na stronie kontaktu, w Szukaj osób i Nowy czat; inaczej inicjały.
- **Wygląd**: kontrolka segmentowa trybu, próbki Koloru akcentu, próbki Tła (gradient),
  Język.
- **Sieć**: lista transportów na żywo ze stanem + zmierzoną prędkością; przełącznik Przekazywania w tle
  (usługa pierwszoplanowa Androida) i przycisk zwolnienia z optymalizacji baterii; „Przekazywane wiadomości nigdy nie są wyświetlane”.
- **Bezpieczeństwo**: integralność aplikacji (Oficjalna wersja ✓ / Zmodyfikowana wersja ✗ / Jeszcze nie sprawdzono), stan
  szyfrowania bazy danych, informacje o protokole Signal.
- **Aktualizacje**: obecna wersja, najnowsza wersja, Sprawdź teraz, przełącznik Aktualizuj automatycznie (Android), postęp.
- **O aplikacji**: nazwa aplikacji + hasło, wersja, link do GitHuba, Licencja, karty **Współtwórcy**: awatar
  (awatar z GitHuba online, inicjały offline), login pogrubiony, podtekst „Profil GitHub”, ikona linku zewnętrznego
  po prawej; karta = `--surface`, obramowanie 1 px, promień 14.
