import Foundation

/// Woher ein Modell kommt. Der Unterschied ist nicht kosmetisch: Apple
/// liefert ueber die Systemschnittstelle, FluidAudio ueber einen fremden
/// Host, den ein Behoerdennetz sperren oder protokollieren kann.
public enum ModelSource: String, Sendable, Equatable, CaseIterable {
    case appleSystemAssets
    case huggingFace

    public var displayHost: String {
        switch self {
        case .appleSystemAssets: "Apple"
        case .huggingFace: "huggingface.co"
        }
    }
}

public struct ModelBundleID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let legacy = Self(rawValue: "legacy.unspecified")
    public static let appleSpeech = Self(rawValue: "apple.transcription-language")
    public static let speakerSeparation = Self(rawValue: "fluidaudio.speaker-separation")
    public static let parakeetTDTv3 = Self(rawValue: "fluidaudio.parakeet-tdt-v3")
}

public struct ModelBundleDescription: Sendable, Equatable {
    public let id: ModelBundleID
    public let title: String
    public let source: ModelSource
    public let approximateBytes: Int

    public init(
        id: ModelBundleID = .legacy,
        title: String,
        source: ModelSource,
        approximateBytes: Int
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.approximateBytes = approximateBytes
    }
}

/// Arbeitsfaehigkeit ist keine einzelne Ja-Nein-Antwort: ASR-Assets sind an
/// die Sprache gebunden, die Antwort kippt also beim Sprachwechsel.
public struct ModelReadiness: Sendable, Equatable {
    public let installed: Set<Locale>
    /// Was noch fehlt, benannt wie in der Oberflaeche. Hier stehen die Titel
    /// der Bundles, keine Dateinamen: die Liste wird angezeigt, und ein
    /// Dateiname sagt einem Nutzer nichts.
    public let missing: [Locale: [String]]

    public init(installed: Set<Locale>, missing: [Locale: [String]]) {
        self.installed = installed
        self.missing = missing
    }

    public func isReady(for locale: Locale) -> Bool {
        installed.contains(locale)
    }

    public func missingNames(for locale: Locale) -> [String] {
        missing[locale] ?? []
    }
}

public struct ModelInstallProgress: Sendable, Equatable {
    public let fraction: Double
    public let title: String
    /// Zaehlt hoch, sobald derselbe Titel von vorn anfaengt - etwa wenn der
    /// Installer eine verfaelschte Datei loescht und erneut laedt.
    ///
    /// Ohne diese Nummer bliebe der Balken stehen: die Oberflaeche verwirft
    /// einen kleineren Anteil beim gleichen Titel, weil sich die Rueckrufe
    /// ueberholen koennen. Ein Neuanfang ist aber kein ueberholter Rueckruf,
    /// und beides sieht ohne Laufnummer gleich aus.
    public let attempt: Int

    public init(fraction: Double, title: String, attempt: Int = 0) {
        self.fraction = fraction
        self.title = title
        self.attempt = attempt
    }

    /// Ob diese Meldung die bisherige ersetzen darf.
    ///
    /// Die Regel steht hier und nicht in der Ansicht, weil sie zwei Faelle
    /// unterscheiden muss, die leicht zu verwechseln sind: ein **ueberholter**
    /// Rueckruf aus einem aelteren Anlauf ist immer zu verwerfen, auch wenn
    /// sein Anteil hoeher ist - sonst springt der Balken beim Reparaturlauf
    /// auf einen alten Wert oder sogar vorzeitig auf 100 Prozent. Innerhalb
    /// desselben Anlaufs zaehlt dagegen der Anteil, weil sich die Rueckrufe
    /// beim Sprung auf den Hauptaktor ueberholen koennen.
    public func supersedes(_ other: ModelInstallProgress?) -> Bool {
        guard let other, other.title == title else { return true }
        if attempt != other.attempt { return attempt > other.attempt }
        return fraction >= other.fraction
    }
}

public protocol ModelInstalling: Sendable {
    /// Bewusst nicht `description`: dieser Name kollidiert mit
    /// `CustomStringConvertible` und liefert bei jedem versehentlichen
    /// String-Interpolieren stillschweigend etwas anderes.
    var bundleDescription: ModelBundleDescription { get }
    func readiness(for locales: [Locale]) async -> ModelReadiness
    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws
    /// Bricht eine laufende Installation bei Widerruf oder einer ausdruecklich
    /// foreground-only gefuehrten App-Lifecycle-Grenze ab. Ein geschlossenes
    /// Fenster allein bricht nichts ab. Ohne diese Anforderung waere
    /// `cancelInstall()` nur ueber den konkreten Typ erreichbar, nicht ueber
    /// `any ModelInstalling` - der Widerruf haette die laufende Installation
    /// dann nicht erwischt.
    func cancelInstall() async
}
