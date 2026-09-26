import Foundation

enum MessageKind: String, Codable {
    case hello, welcome, rejected
    case audioStart, audioReady, audioChunk, audioEnd, audioError, audioStatus, audioComplete
    case modelProbe, modelCapability
}

struct TextMessage: Codable {
    static let version = 5
    let version: Int
    let sessionId: UUID
    let type: MessageKind
    let text: String
    let audio: Data?
    let token: String
    let senderID: UUID
    let senderName: String
    let reason: String?
    let modelRequest: ModelRequest?
    let modelDecision: ModelDecision?
    let modelCapability: ModelCapability?

    init(sessionId: UUID, type: MessageKind, text: String = "", audio: Data? = nil, token: String,
         senderID: UUID, senderName: String, reason: String? = nil,
         modelRequest: ModelRequest? = nil, modelDecision: ModelDecision? = nil,
         modelCapability: ModelCapability? = nil) {
        self.version = Self.version
        self.sessionId = sessionId
        self.type = type
        self.text = text
        self.audio = audio
        self.token = token
        self.senderID = senderID
        self.senderName = senderName
        self.reason = reason
        self.modelRequest = modelRequest
        self.modelDecision = modelDecision
        self.modelCapability = modelCapability
    }
}

enum BridgeError: LocalizedError {
    case invalidPort, missingToken, noConnection, noFocusedText, unsupportedLocale
    case permission(String), transport(String), injection(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: "端口必须是 1–65535 之间的数字。"
        case .missingToken: "配对信息无效，请重新配对当前电脑。"
        case .noConnection: "尚未连接接收端。"
        case .noFocusedText: "请先在接收端点选可编辑输入框。"
        case .unsupportedLocale: "当前语言未提供设备端语音识别。请更换语言或检查系统语音资源。"
        case .permission(let detail): detail
        case .transport(let detail): detail
        case .injection(let detail): detail
        }
    }
}
