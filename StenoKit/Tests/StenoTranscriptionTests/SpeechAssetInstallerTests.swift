import Testing
import Foundation
@testable import StenoTranscription

@Suite("Speech asset installer")
struct SpeechAssetInstallerTests {
    @Test("installing is never attempted without being asked")
    func neverInstallsByItself() async {
        let gateway = RecordingGateway(installedLocales: [])
        let installer = SpeechAssetInstaller(assets: gateway)
        let readiness = await installer.readiness(for: [Locale(identifier: "de-DE")])
        #expect(!readiness.isReady(for: Locale(identifier: "de-DE")))
        // Was fehlt, wird angezeigt: der Bundletitel, kein Bezeichner.
        #expect(
            readiness.missingNames(for: Locale(identifier: "de-DE"))
                == [installer.bundleDescription.title]
        )
        #expect(await gateway.installCount == 0)
    }

    @Test("readiness distinguishes languages")
    func readinessPerLanguage() async {
        let gateway = RecordingGateway(installedLocales: [Locale(identifier: "de-DE")])
        let installer = SpeechAssetInstaller(assets: gateway)
        let readiness = await installer.readiness(
            for: [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
        )
        #expect(readiness.isReady(for: Locale(identifier: "de-DE")))
        #expect(!readiness.isReady(for: Locale(identifier: "en-US")))
    }

    @Test("two concurrent requests lead to exactly one installation")
    func concurrentRequestsCollapse() async throws {
        let gateway = RecordingGateway(installedLocales: [])
        let installer = SpeechAssetInstaller(assets: gateway)
        async let first: Void = installer.install(for: Locale(identifier: "de-DE")) { _ in }
        async let second: Void = installer.install(for: Locale(identifier: "de-DE")) { _ in }
        _ = try await (first, second)
        #expect(await gateway.installCount == 1)
    }

    @Test("the advertised download size matches the measured catalog entry")
    func advertisedSizeMatchesCatalog() {
        let gateway = RecordingGateway(installedLocales: [])
        let installer = SpeechAssetInstaller(assets: gateway)
        let description = installer.bundleDescription

        #expect(description.source == .appleSystemAssets)
        // Gemessen, nicht geschaetzt: rund 136 MiB fuer das deutsche
        // Transkriptionsasset aus Apples Assetkatalog.
        #expect(description.approximateBytes == SpeechAssetBytes.germanTranscriptionDownload)
        // Derselbe Denkfehler wie auf der Diarisierungsseite lauert hier
        // oberhalb, nicht unterhalb: der verwechselbare Wert ist
        // `_UnarchivedSize` (182_657_024, der entpackte Platzbedarf) statt
        // `_DownloadSize` (142_606_336, die uebertragene Menge). Eine untere
        // Plausibilitaetsschranke koennte eine Uebertreibung nie fangen,
        // deshalb ein Fenster um den gemessenen Wert.
        #expect(description.approximateBytes > 130_000_000)
        #expect(description.approximateBytes < 150_000_000)
    }
}

actor RecordingGateway: SpeechAssetGateway {
    private var installed: Set<String>
    private(set) var installCount = 0

    init(installedLocales: [Locale]) {
        installed = Set(installedLocales.map(\.identifier))
    }

    func isInstalled(locale: Locale) async -> Bool {
        installed.contains(locale.identifier)
    }

    func install(locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws {
        installCount += 1
        try await Task.sleep(for: .milliseconds(20))
        installed.insert(locale.identifier)
        progress(1)
    }
}
