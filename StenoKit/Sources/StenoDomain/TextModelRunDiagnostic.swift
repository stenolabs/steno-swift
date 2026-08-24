/// Inhaltssicherer Befund zu einem gescheiterten Textmodell-Aufruf: keine
/// Transkript-, Notiz- oder Antwortinhalte, nur Metadaten ueber den Fehlschlag
/// selbst (welcher Dialekt, welche Phase, welcher HTTP-Status). Ein
/// ``ProcessingRun`` traegt diesen Befund optional, damit ein gescheiterter
/// Lauf mehr sagt als nur "fehlgeschlagen", ohne je Meeting-Inhalt zu
/// persistieren.
public struct TextModelRunDiagnostic: Codable, Equatable, Sendable {
    public let dialect: String
    public let stage: String
    public let requestIndex: Int?
    public let httpStatus: Int?
    public let providerCode: String?
    public let finishReason: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let responseBytes: Int?
    public let parsingFailure: String?
    public let transportRetryCount: Int
    public let adaptiveRetryCount: Int

    public init(
        dialect: String,
        stage: String,
        requestIndex: Int? = nil,
        httpStatus: Int? = nil,
        providerCode: String? = nil,
        finishReason: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        responseBytes: Int? = nil,
        parsingFailure: String? = nil,
        transportRetryCount: Int = 0,
        adaptiveRetryCount: Int = 0
    ) {
        self.dialect = dialect
        self.stage = stage
        self.requestIndex = requestIndex
        self.httpStatus = httpStatus
        self.providerCode = providerCode
        self.finishReason = finishReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.responseBytes = responseBytes
        self.parsingFailure = parsingFailure
        self.transportRetryCount = transportRetryCount
        self.adaptiveRetryCount = adaptiveRetryCount
    }
}
