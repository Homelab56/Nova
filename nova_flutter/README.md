# Nova Flutter App — Standalone

Volledig standalone app. Geen server nodig.
Praat rechtstreeks met TMDB en Real-Debrid.

## Vereisten
- Flutter SDK: https://docs.flutter.dev/get-started/install/windows/mobile
- Android Studio (voor Android SDK)

## Bouwen

```bash
cd nova_flutter
flutter pub get
flutter build apk --release
```

APK staat op: `build/app/outputs/flutter-apk/app-release.apk`

## Eerste keer opstarten
De app vraagt automatisch om je TMDB key en RD token.
Alles wordt veilig opgeslagen op het toestel zelf.
