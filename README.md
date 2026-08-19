# Steno Swift

Private beta source for the native Steno apps on macOS, iPhone, and iPad.
Steno records meetings, transcribes and diarizes them locally, and generates minutes.

## Repository layout

- `StenoKit/` contains the shared Swift package.
- `App/` contains the macOS app.
- `iOS/App/` and `iOS/StenoiOSKit/` contain the iOS and iPadOS app.

## Build and test

Xcode 26 and XcodeGen are required.

```sh
swift test --package-path StenoKit
scripts/build-app.sh
scripts/build-ios.sh
```

For a simulator that is already running:

```sh
scripts/build-ios.sh --simulator
```

For a physical device, provide your Apple Developer team locally instead of committing it:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/build-ios.sh --device
```

## Private test data

The checked-in fixtures are synthetic.
Do not attach recordings, transcripts, raw diagnostic logs, or other personal meeting data to GitHub issues.
