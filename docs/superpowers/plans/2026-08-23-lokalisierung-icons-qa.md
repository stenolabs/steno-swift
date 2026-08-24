# Localization, App Icons, and Final QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship complete English and German UI catalogs, replace the classic raster app icons with one verified multilayer Steno icon, and finish the cross-platform work with reproducible automated and manual QA.

**Architecture:** Keep each app's UI catalog independent while using English source strings and explicit German translations.
Share one Icon Composer document between the two app targets because both apps intentionally use the same Steno mark.
Treat builds and exported renditions as the icon truth, and record simulator, device, and isolated-library observations separately from source-derived facts.

**Tech Stack:** Swift 6, SwiftUI, String Catalogs, XcodeGen, `xcstringstool`, Icon Composer, `ictool`, `actool`, Swift Testing, Simulator, iPhone, iPad

**Spec:** `docs/superpowers/specs/2026-08-23-cross-platform-ui-modernisierung-und-demo-design.md`

## Global Constraints

- English remains the source language and German is the complete second localization.
- Persisted enum values, technical identifiers, filenames, and diagnostic log text are not localized.
- Every user-visible safety, privacy, recovery, destructive-action, and accessibility string is translated.
- The existing Steno mark and brand colors remain recognizable.
- The classic raster icon sets stay in place until the Icon Composer document has built and rendered correctly for both platforms.
- All macOS runtime checks use isolated `STENO_LIBRARY_DIR` and `STENO_MODEL_DIR` paths.
- Device and simulator screenshots never use the operator's real meeting library.
- New pure presentation types introduced by the preceding plans return `LocalizedStringResource` for user-visible text from their first implementation, not raw `String` literals that extraction cannot prove localizable.
- No dependency changes, remote push, merge, or publication.

---

### Task 1: Establish enforceable localization catalogs

**Files:**
- Modify: `project.yml`
- Modify: `iOS/project.yml`
- Create: `App/Resources/Localizable.xcstrings`
- Create: `App/Resources/InfoPlist.xcstrings`
- Create: `iOS/App/Resources/Localizable.xcstrings`
- Create: `iOS/App/Resources/InfoPlist.xcstrings`
- Create: `App/Tests/LocalizationCatalogTests.swift`
- Create: `iOS/App/Tests/LocalizationCatalogTests.swift`

**Interfaces:**
- Consumes: Xcode's SwiftUI string extraction and the generated app bundles.
- Produces: source-language `en` catalogs with complete `de` localizations and localized Info.plist usage descriptions.

- [ ] **Step 1: Write failing catalog contract tests**

In each app test target, decode the two neighboring `.xcstrings` files as JSON.
Assert `sourceLanguage == "en"`, assert every translatable entry has a nonempty German value with state `translated`, and assert the InfoPlist catalog contains every privacy key used by that platform.
For macOS require `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`.
For iOS require `NSMicrophoneUsageDescription` and `NSLocalNetworkUsageDescription`.

- [ ] **Step 2: Regenerate projects and verify RED**

Run:

```bash
xcodegen generate
(cd iOS && xcodegen generate)
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -derivedDataPath .build/ui-modernization/DerivedData-mac -only-testing:StenoTests/LocalizationCatalogTests test
xcodebuild -project iOS/StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath iOS/build/DerivedData -only-testing:StenoTests/LocalizationCatalogTests test
```

Expected: both test targets fail because the catalogs do not exist.

- [ ] **Step 3: Add the minimal catalog and project configuration**

Set XcodeGen's development language to English and known regions to English and German in both project files.
Add format-version `1.0` catalogs with `sourceLanguage` set to `en`.
Keep the English Info.plist values in `project.yml` as the source fallback and put their exact German equivalents in `InfoPlist.xcstrings`.

- [ ] **Step 4: Verify catalog compilation and GREEN**

Run these exact commands from the repository root:

```bash
mkdir -p .build/ui-modernization/strings-compiled/mac .build/ui-modernization/strings-compiled/ios
xcrun xcstringstool compile App/Resources/Localizable.xcstrings --output-directory .build/ui-modernization/strings-compiled/mac --language en --language de
xcrun xcstringstool compile App/Resources/InfoPlist.xcstrings --output-directory .build/ui-modernization/strings-compiled/mac --language en --language de
xcrun xcstringstool compile iOS/App/Resources/Localizable.xcstrings --output-directory .build/ui-modernization/strings-compiled/ios --language en --language de
xcrun xcstringstool compile iOS/App/Resources/InfoPlist.xcstrings --output-directory .build/ui-modernization/strings-compiled/ios --language en --language de
```

Then rerun both focused test commands.
Expected: compilation and both tests pass.

### Task 2: Extract and translate every SwiftUI source key

**Files:**
- Modify: `App/Resources/Localizable.xcstrings`
- Modify: `iOS/App/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: all `.swift` files under `App/Sources` and `iOS/App/Sources`.
- Produces: complete catalog entries for SwiftUI literals without changing persisted or diagnostic strings.

- [ ] **Step 1: Extract the source keys into temporary catalogs**

Regenerate both projects, then use Xcode's localization export so Swift compilation, SwiftUI extraction, modern localized resources, catalog interpolation, and Info.plist strings are evaluated together:

```bash
xcodegen generate
(cd iOS && xcodegen generate)
mkdir -p .build/ui-modernization/localization-export/mac .build/ui-modernization/localization-export/ios
xcodebuild -exportLocalizations -project Steno.xcodeproj -localizationPath .build/ui-modernization/localization-export/mac -defaultLanguage en -exportLanguage de
xcodebuild -exportLocalizations -project iOS/StenoiOS.xcodeproj -localizationPath .build/ui-modernization/localization-export/ios -defaultLanguage en -exportLanguage de
xcrun xcstringstool print App/Resources/Localizable.xcstrings
xcrun xcstringstool print iOS/App/Resources/Localizable.xcstrings
```

Diff every exported XLIFF trans-unit ID against the printed checked-in catalog keys.
Classify technical IDs, log-only strings, and persisted raw values as nontranslatable instead of giving them cosmetic translations.
Treat any user-visible raw `String` in a pure presenter as a defect: convert its producer to `LocalizedStringResource` or `String(localized:)`, then export again until Xcode includes it.

- [ ] **Step 2: Add an intentionally untranslated fixture and verify RED**

Temporarily add one extracted, translatable key without a German localization to each catalog and rerun `LocalizationCatalogTests`.
Expected: each test reports that exact missing key.
Remove the temporary fixture immediately after confirming the test.

- [ ] **Step 3: Populate German translations**

Translate all extracted UI, destructive-action, recovery, privacy, progress, menu, command, accessibility-label, and accessibility-hint keys.
Preserve placeholders and plural substitutions exactly.
Use consistent product vocabulary: `Meeting`, `Transkript`, `Sprecher`, `Teilnehmende`, `Protokoll`, `Erneut transkribieren`, `In den Papierkorb`, `Abbrechen`, and `Erneut versuchen`.

- [ ] **Step 4: Compile and rerun focused tests**

Compile both catalogs with `xcstringstool`, print their keys, and rerun the two focused localization suites.
Expected: every extracted translatable key has a German value and both suites pass.

### Task 3: Localize dynamic presentation text at the call site

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/AudioExportPresentation.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Sources/LegacyImportView.swift`
- Modify: `App/Sources/MeetingDetailView.swift`
- Modify: `App/Sources/MeetingTransferExportView.swift`
- Modify: `App/Sources/MeetingTransferImportView.swift`
- Modify: `App/Sources/ModelStatusView.swift`
- Modify: `App/Sources/NotesSection.swift`
- Modify: `App/Sources/OnboardingView.swift`
- Modify: `App/Sources/RecordingView.swift`
- Modify: `App/Sources/ReportsSection.swift`
- Modify: `App/Sources/TextModelSettingsView.swift`
- Modify: `App/Sources/TranscriptionModelSettingsView.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/AudioReadinessView.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Modify: `iOS/App/Sources/IOSModelInstallationState.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Sources/MeetingNotesSection.swift`
- Modify: `iOS/App/Sources/MeetingParticipantsSection.swift`
- Modify: `iOS/App/Sources/MeetingReportsSection.swift`
- Modify: `iOS/App/Sources/MeetingSidebarView.swift`
- Modify: `iOS/App/Sources/MeetingTransferExportSheet.swift`
- Modify: `iOS/App/Sources/MeetingTransferImportSheet.swift`
- Modify: `iOS/App/Sources/RecordingStrip.swift`
- Modify: `iOS/App/Sources/RecordingView.swift`
- Modify: `iOS/App/Sources/StenoCommands.swift`
- Modify: `iOS/App/Sources/TextModelSettingsView.swift`
- Modify: `iOS/App/Sources/TranscriptionModelSettingsView.swift`
- Modify: `App/Tests/LocalizationCatalogTests.swift`
- Modify: `iOS/App/Tests/LocalizationCatalogTests.swift`

**Interfaces:**
- Consumes: dynamic user-visible `String` values returned by presentation helpers.
- Produces: `LocalizedStringResource` where SwiftUI owns rendering and `String(localized:)` where an API requires a concrete string.

- [ ] **Step 1: Extend tests with dynamic-key fixtures**

Add locale-fixed English and German tests for interpolated meeting titles, endpoint-deletion copy, progress copy, startup failure copy, demo lifecycle copy, and report-sharing disclosure.
Expected RED: the German locale still returns the English dynamic strings.

- [ ] **Step 2: Replace dynamic UI strings with localized resources**

Return `LocalizedStringResource` from pure presentation helpers wherever their consumers accept it.
At boundaries that require `String`, use `String(localized:resource, locale:)` or `String(localized:)` and keep variables as interpolation arguments rather than concatenating translated fragments.
Do not wrap raw errors directly; map them to a stable localized message and keep the technical detail in logs.

- [ ] **Step 3: Re-extract and reconcile catalogs**

Run the extraction commands from Task 2 again.
Add the new interpolation keys and German translations, then verify that no obsolete temporary key remains.

- [ ] **Step 4: Run locale-fixed tests in both app suites**

Run both `LocalizationCatalogTests` classes plus the existing presentation tests touched by the new localized return types.
Expected: English and German literal expectations pass without depending on the host locale.

### Task 4: Reconstruct the Steno mark as a shared Icon Composer document

**Files:**
- Create: `Shared/Resources/AppIcon.icon`
- Modify: `project.yml`
- Modify: `iOS/project.yml`
- Retain until Task 5 passes: `App/Resources/Assets.xcassets/AppIcon.appiconset`
- Retain until Task 5 passes: `iOS/App/Resources/Assets.xcassets/AppIcon.appiconset`

**Interfaces:**
- Consumes: the current teal background, white outlined `S`, and terminal dot from the 1024-pixel iOS source icon.
- Produces: one multilayer `AppIcon.icon` named `AppIcon`, supporting iOS, iPadOS, and macOS Default, Dark, and Monochrome/Tinted appearances.

- [ ] **Step 1: Capture a pre-change visual baseline**

Export the current iOS 1024-pixel icon and current macOS 1024-pixel icon into the task-owned QA directory.
Record canvas size, visible mark bounds, teal color, white mark color, and whether transparency exists.

- [ ] **Step 2: Create vector layers in Icon Composer**

Use separate background, `S`, and dot layers on a 1024 by 1024 canvas.
Convert the mark to outlines and keep it optically centered using the measured source bounds.
Configure Default, Dark, and Monochrome/Tinted variants without baking shadows, corner masks, or unsupported blur into the vector source.
Enable only iOS/iPadOS and macOS platforms in the document.

- [ ] **Step 3: Wire the shared document into both generated projects**

Add `Shared/Resources/AppIcon.icon` to the macOS target and `../Shared/Resources/AppIcon.icon` to the iOS target through the two `project.yml` files.
Keep `ASSETCATALOG_COMPILER_APPICON_NAME` set to `AppIcon` for both targets.
Regenerate both projects.

- [ ] **Step 4: Export deterministic inspection renditions**

Run these exact Xcode 26.6 commands from the repository root:

```bash
mkdir -p .build/ui-modernization/icons/export .build/ui-modernization/icons/actool-mac .build/ui-modernization/icons/actool-ios
'/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool' Shared/Resources/AppIcon.icon --export-image --output-file .build/ui-modernization/icons/export/ios-default.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
'/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool' Shared/Resources/AppIcon.icon --export-image --output-file .build/ui-modernization/icons/export/ios-dark.png --platform iOS --rendition Dark --width 1024 --height 1024 --scale 1
'/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool' Shared/Resources/AppIcon.icon --export-image --output-file .build/ui-modernization/icons/export/ios-tinted-dark.png --platform iOS --rendition TintedDark --width 1024 --height 1024 --scale 1 --tint-color 0.25 --tint-strength 0.75
'/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool' Shared/Resources/AppIcon.icon --export-image --output-file .build/ui-modernization/icons/export/macos-default.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
xcrun actool App/Resources/Assets.xcassets Shared/Resources/AppIcon.icon --compile .build/ui-modernization/icons/actool-mac --output-format human-readable-text --notices --warnings --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 --target-device mac --output-partial-info-plist .build/ui-modernization/icons/actool-mac-info.plist
xcrun actool iOS/App/Resources/Assets.xcassets Shared/Resources/AppIcon.icon --compile .build/ui-modernization/icons/actool-ios --output-format human-readable-text --notices --warnings --app-icon AppIcon --platform iphonesimulator --minimum-deployment-target 26.0 --target-device iphone --target-device ipad --output-partial-info-plist .build/ui-modernization/icons/actool-ios-info.plist
```

Require every command to exit zero and the `actool` output to contain no duplicate-icon, missing-rendition, or asset-name warning before Task 5 may remove the raster sets.
Open all renditions and compare mark alignment, contrast, safe-area breathing room, and the dot's separation from the `S` against the baseline.

### Task 5: Prove the new icon before removing classic icon sets

**Files:**
- Verify: `Shared/Resources/AppIcon.icon`
- Delete only after all checks pass: `App/Resources/Assets.xcassets/AppIcon.appiconset`
- Delete only after all checks pass: `iOS/App/Resources/Assets.xcassets/AppIcon.appiconset`

**Interfaces:**
- Consumes: regenerated Xcode projects and the shared Icon Composer document.
- Produces: app bundles whose primary icon is generated from `AppIcon.icon` with no duplicate-icon warning.

- [ ] **Step 1: Build both apps while classic and composed icons coexist**

Run `scripts/build-app.sh` and `scripts/build-ios.sh`.
Inspect the build logs for Icon Composer, `actool`, duplicate app-icon, missing rendition, and asset-name warnings.
Expected: both apps build and Xcode selects the matching `AppIcon.icon` document.

- [ ] **Step 2: Inspect built bundle metadata and renditions**

Read each built app's `Info.plist` and icon resources.
Confirm the primary icon is named `AppIcon` and the generated resource exists for that platform.

- [ ] **Step 3: Remove only the superseded classic AppIcon sets**

After Steps 1 and 2 pass, remove the two `AppIcon.appiconset` directories while retaining both `Assets.xcassets` containers and all color assets.
Regenerate and rebuild both apps.

- [ ] **Step 4: Check simulator and device appearances**

Install on an iPhone simulator and an iPad simulator.
When a concrete physical-device install is explicitly authorized and the device is available, also inspect at least one selected iOS device; otherwise record physical-device appearance as not measured.
Inspect Home Screen, App Library or search, Settings, macOS Dock, and app switcher in available Default, Dark, and Tinted/Monochrome appearances.
If a platform cannot expose an appearance in the current environment, record it as not measured rather than inferring success.

### Task 6: Run accessibility and layout regression coverage

**Files:**
- Modify: `iOS/App/Tests/RecordingPresentationTests.swift`
- Modify: `iOS/App/Tests/MeetingPresentationTests.swift`
- Modify: `iOS/App/Tests/MeetingInspectorPresentationTests.swift`
- Modify: `iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift`
- Modify: `iOS/App/Tests/TextModelEndpointPresentationTests.swift`
- Modify: `iOS/App/Tests/TranscriptionModelSettingsLayoutTests.swift`
- Modify: `App/Tests/WindowLayoutTests.swift`
- Modify: `App/Tests/MeetingSidebarStateTests.swift`
- Modify: `App/Tests/TextModelSettingsTests.swift`
- Create: `docs/measurements/2026-08-23-cross-platform-ui-qa.md`

**Interfaces:**
- Consumes: the completed UI behavior from all six implementation plans.
- Produces: automated semantic/layout coverage plus a dated measured-versus-inferred QA record.

- [ ] **Step 1: Add regression matrices before final UI polish**

Cover iOS recording duration and level semantics, accessibility-size layout decisions, inspector and visible-action policies, endpoint deletion copy, startup states, and indeterminate progress.
Cover macOS minimum-window layouts, command availability, native-search state, endpoint deletion copy, and Reduce Motion presentation policy.
Fix every test locale explicitly.

- [ ] **Step 2: Run the focused tests and address only real regressions**

Run the touched iOS and macOS test classes with `-only-testing`.
Classify every failure as caused by the change, pre-existing, environment-related, or flaky before modifying code.

- [ ] **Step 3: Perform the isolated simulator matrix**

Use a task-owned temporary library and model directory.
Exercise iPhone standard size and `.accessibility5`, iPad full screen and Split View in both orientations, macOS minimum and normal sizes, Dark Mode, Increase Contrast, Differentiate Without Color, and Reduce Motion.
Capture screenshots only from the simulator or isolated app windows.

- [ ] **Step 4: Perform the device interaction matrix**

On the iPhone and iPad simulator form factors, inspect VoiceOver ordering, duration and level speech, Full Keyboard Access, pointer use, `Cmd-F`, centered alerts, denied-microphone recovery, model cancellation, demo lifecycle, and localized long German copy.
Repeat the hardware-dependent subset on an explicitly authorized selected device when available.
Record SpeechTranscriber or model states as hardware observations, not general guarantees.

- [ ] **Step 5: Write the measurement record**

For each acceptance item, label the result `measured`, `source-verified`, `inferred`, `environment-blocked`, or `not run`.
Record exact simulator/device/OS, build commit, commands, isolated library path, screenshots retained, and any limitation.

### Task 7: Independent review, full suites, cleanup, and local commit

**Files:**
- Verify all files changed by the six implementation plans.
- Finalize: `docs/measurements/2026-08-23-cross-platform-ui-qa.md`

**Interfaces:**
- Consumes: all completed implementation tasks and the Claude Fable design opinion already obtained.
- Produces: reviewed local commits, a clean worktree, and a final evidence-backed handoff without push or merge.

- [ ] **Step 1: Obtain independent implementation reviews**

Review demo deletion and identity exclusion, revision-conflict behavior, cancellation boundaries, startup retry stages, macOS focused commands, localization completeness, and icon-resource selection.
Resolve Critical and Important findings, then request one targeted re-review.

- [ ] **Step 2: Regenerate both projects**

Run:

```bash
xcodegen generate
cd iOS && xcodegen generate
```

Expected: both generated projects include every new source and resource without warnings.

- [ ] **Step 3: Run all four suites exactly once on the final consolidated tree**

Run:

```bash
swift test --package-path StenoKit
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' test
(cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData test)
(cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit -destination 'platform=iOS Simulator,name=iPhone 17' test)
```

Expected: all four suites pass with no silent test-count regression.

- [ ] **Step 4: Inspect the complete diff and clean task-owned artifacts**

Run `git diff --check`, inspect `git status --short`, and review every changed file against the approved spec.
Delete only task-owned build, log, export, and temporary screenshot artifacts that are no longer needed.
Retain the final runnable app build and explicitly requested QA evidence only.

- [ ] **Step 5: Create local commits without pushing or merging**

Stage only files owned by this task, create local commits without a co-author, and verify the final diff from the pre-task commit.
Do not push, merge, publish, or touch production systems.
