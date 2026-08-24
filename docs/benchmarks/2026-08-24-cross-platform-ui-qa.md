# Cross-platform UI QA on 24 August 2026

## Scope

The consolidated `codex/ui-modernization` state was checked on macOS, iPhone, and iPad.

Every runtime test using demo data used isolated library and model directories.
The user's real meeting library was neither opened nor changed.

## Measured and directly observed

- iPhone verification used an iPhone 17 Simulator running iOS 26.5.
- iPad verification used a 13-inch M5 iPad Pro Simulator running iPadOS 26.5 in portrait and landscape.
- macOS verification used an isolated temporary library.
- Light and dark appearance were visually checked for the central library, meeting, recording, demo, and settings views.
- The demo library installs three local synthetic meetings, clearly labeled with `DEMO:` and `Demo`, in a dedicated folder.
- The demo detail view identifies its synthetic origin and does not present unconfirmed speakers as real people.
- The iPad confirmation dialog for "Transcribe Again" from the upper-right menu appears centered in the main content rather than in the sidebar.
- The dialog explains the new revision, preservation of the previous transcript and its corrections, new cluster identifiers, and the need to confirm speakers again.
- The action was canceled during UI verification and therefore was not enqueued.
- The installed offline-model row remained under 80 points high at iPhone and iPad sizes and appeared as a normal single-line card at runtime.
- The oversized row was isolated to `LabeledContent` within this dynamic list row.
  Neither its content nor the following status rows caused the height.
  Replacing it with an explicit `HStack` fixed the issue, and a UIKit hierarchy test now guards cell height at both device sizes.
- For the stored German language, both transcription pickers contained exactly Apple Speech Analyzer and FluidAudio Parakeet TDT.
  A picker is therefore appropriate in this configuration.
  Uninstalled or experimentally gated choices remain visible and state their status.
- The German-localized run showed no missing German entries in either app catalog.
- The German-localized external text-model privacy warning names the transmitted data classes, destination, and lack of transport encryption.
- The previous macOS and iOS Steno icon sources were byte-identical.
- Their measured gradient endpoints are `#0DACBD` and `#00717E`.
- In the 1024-pixel original, the white mark occupies x=302 through 786 and y=186 through 809.
- The vectorized S mark reaches 99.313 percent mask intersection-over-union with the raster original.
- The dot remains an exact vector circle.
- Icon Composer, `actool`, both app builds, and visible Simulator rendering were checked with the shared icon document.
- The macOS app, macOS test bundle, iOS Simulator app, iOS test bundle, StenoiOSKit test bundle, and signed device app are all thin ARM64 Mach-O files.
- Signed build `org.steno.Steno`, version 1.0 build 1, was installed on an iPhone 15 Pro and 11-inch iPad Pro and then found in both application lists.

## Complete test runs

- `swift test --package-path StenoKit`: 1,082 tests in 125 suites passed.
- macOS app suite: 319 tests in 31 suites passed.
- iOS app suite: 476 tests in 43 suites passed.
- StenoiOSKit suite: 35 tests in five suites passed.
- Shell checks for Apple-Silicon-only output and iOS build arguments also passed.

The first complete iOS run exposed old tests that hard-coded visible English strings even though the test process ran in German.
The product strings were correctly localized in German.
The expectations were made language-stable and the complete suite then passed.

Claude Fable reviewed the consolidated diff independently.
The main adopted recommendation was to stop recognizing fixed speaker roles from displayed text.
`SpeakerPresentation` now carries these roles as types, confirmed user names such as `Me` remain unchanged, and only the source suffix of opaque cluster identifiers is localized.
The reported possible conversion of `NaN` or infinity into an integer level was rejected after tracing the source and running Swift: `AudioLevel` already normalizes those inputs through its public initializer into the valid range.

## Inferred or deliberately designed

- The roughly 30-percent horizontal extent of the icon gradient is inferred from the measured endpoint colors, not readable as metadata from the old PNG.
- Dark-mode material and the Icon Composer rendition are deliberate design decisions.
- Attribution of the oversized model row to `LabeledContent` rests on the isolated component change and reproducing cell test.
  The internal SwiftUI cause below that component is not publicly observable.

## Not measured

- VoiceOver was checked structurally through accessibility labels and layout tests, but not as a complete spoken session with headphones.
- Both physical installations were verified technically.
  No automated claim is made about visual or interactive acceptance on the physical displays.
- Re-transcription was deliberately not started in isolated iPad verification to avoid unnecessary model work.
