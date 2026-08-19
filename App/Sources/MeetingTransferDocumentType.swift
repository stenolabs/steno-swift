import UniformTypeIdentifiers

extension UTType {
    /// Lokale Compile-Time-Konstante für Dateiwähler und Dokumentöffnung.
    /// Die LaunchServices-Registrierung bleibt bis zum physischen Gate 0
    /// bewusst außerhalb dieses Tasks.
    static let stenoMeetingTransfer = UTType(
        exportedAs: "org.steno.meeting-transfer",
        conformingTo: .archive
    )
}
