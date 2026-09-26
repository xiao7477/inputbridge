import Foundation

enum RecognitionProvider: String, Codable, CaseIterable {
    case apple, doubao

    var title: String {
        switch self {
        case .apple: "Apple 本地识别"
        case .doubao: "豆包语音 2.0"
        }
    }
}

enum ModelSelectionMode: String, Codable, CaseIterable {
    case automatic, manual

    var title: String { self == .automatic ? "自动" : "手动" }
}

struct ModelRequest: Codable, Equatable {
    let mode: ModelSelectionMode
    let preferred: RecognitionProvider
    let controllerHasDoubaoKey: Bool
}

struct ModelCapability: Codable, Equatable {
    let preferred: RecognitionProvider
    let hasDoubaoKey: Bool
    let resourceID: String
}

struct ModelDecision: Codable, Equatable {
    let provider: RecognitionProvider
    let explanation: String
}

enum SpeechModelSelection {
    static func decide(request: ModelRequest,
                       receiverPreferred: RecognitionProvider,
                       receiverHasDoubaoKey: Bool) -> ModelDecision {
        switch request.mode {
        case .automatic:
            if request.preferred == .doubao,
               request.controllerHasDoubaoKey,
               receiverHasDoubaoKey {
                return ModelDecision(provider: .doubao,
                                     explanation: "自动：两端均已配置豆包，B 使用豆包语音 2.0")
            }
            if request.preferred == .doubao {
                return ModelDecision(provider: .apple,
                                     explanation: "自动：豆包未在两端配置完整，B 改用 Apple 本地识别")
            }
            return ModelDecision(provider: .apple,
                                 explanation: "自动：B 使用 Apple 本地识别")
        case .manual:
            if receiverPreferred == .doubao && receiverHasDoubaoKey {
                return ModelDecision(provider: .doubao,
                                     explanation: "手动：B 使用自己选择的豆包语音 2.0")
            }
            return ModelDecision(provider: .apple,
                                 explanation: receiverPreferred == .doubao
                                     ? "手动：B 未配置豆包，使用 Apple 本地识别"
                                     : "手动：B 使用自己选择的 Apple 本地识别")
        }
    }
}
