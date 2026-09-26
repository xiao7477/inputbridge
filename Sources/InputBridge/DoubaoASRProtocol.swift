import Foundation

struct DoubaoASRResponse: Equatable {
    let text: String?
    let isLast: Bool
    let error: String?
}

enum DoubaoASRProtocol {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    static func configuration() throws -> Data {
        let payload: [String: Any] = [
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000,
                      "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_nonstream": true,
                        "result_type": "full", "show_utterances": true,
                        "enable_itn": true, "enable_punc": true, "enable_ddc": false]
        ]
        return frame(type: 0x10, flags: 0, serialization: 0x10,
                     payload: try JSONSerialization.data(withJSONObject: payload))
    }

    static func audio(_ payload: Data, last: Bool = false) -> Data {
        frame(type: 0x20, flags: last ? 2 : 0, serialization: 0,
              payload: payload)
    }

    private static func frame(type: UInt8, flags: UInt8,
                              serialization: UInt8, payload: Data) -> Data {
        var data = Data([0x11, type | flags, serialization, 0])
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> DoubaoASRResponse {
        guard data.count >= 8, data[0] >> 4 == 1 else {
            throw BridgeError.transport("豆包返回了无效的协议帧。")
        }
        let headerLength = Int(data[0] & 0x0f) * 4
        guard headerLength >= 4, data.count >= headerLength + 4 else {
            throw BridgeError.transport("豆包协议帧头不完整。")
        }
        let kind = data[1] >> 4
        let flags = data[1] & 0x0f
        let compression = data[2] & 0x0f
        guard compression == 0 else {
            throw BridgeError.transport("豆包返回了未协商的压缩格式。")
        }
        var offset = headerLength
        var errorCode: UInt32?
        if kind == 0x0f {
            errorCode = data.readUInt32(at: offset)
            offset += 4
        } else if flags & 1 != 0 {
            offset += 4 // response sequence
        }
        guard let size = data.readUInt32(at: offset),
              size <= 2_000_000,
              data.count >= offset + 4 + Int(size) else {
            throw BridgeError.transport("豆包返回的识别数据长度无效。")
        }
        let payload = data.subdata(in: offset + 4..<offset + 4 + Int(size))
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        if kind == 0x0f {
            let detail = (json?["message"] as? String) ?? String(data: payload, encoding: .utf8) ?? "未知错误"
            return DoubaoASRResponse(text: nil, isLast: true,
                                     error: "豆包协议错误 \(errorCode ?? 0)：\(detail)")
        }
        guard kind == 0x09, let json else {
            throw BridgeError.transport("豆包返回了未知响应类型。")
        }
        let code = json["code"] as? Int ?? 0
        if code != 0 {
            let detail = json["message"] as? String ?? "未知错误"
            return DoubaoASRResponse(text: nil, isLast: true,
                                     error: "豆包识别失败（\(code)）：\(detail)")
        }
        let body = (json["payload_msg"] as? [String: Any]) ?? json
        let result: [String: Any]?
        if let object = body["result"] as? [String: Any] {
            result = object
        } else {
            result = (body["result"] as? [[String: Any]])?.last
        }
        return DoubaoASRResponse(text: result?["text"] as? String,
                                 isLast: (json["is_last_package"] as? Bool) == true || flags & 2 != 0,
                                 error: nil)
    }

    static func pcm16(fromFloat32 data: Data) -> Data? {
        guard data.count.isMultiple(of: 4) else { return nil }
        var result = Data(capacity: data.count / 2)
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let sample = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
                let integer = Int16(max(-32768, min(32767, Int(clamped * 32767))))
                let bits = UInt16(bitPattern: integer)
                result.append(UInt8(truncatingIfNeeded: bits))
                result.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
        }
        return result
    }
}

private extension Data {
    mutating func appendUInt32(_ number: UInt32) {
        append(UInt8(truncatingIfNeeded: number >> 24))
        append(UInt8(truncatingIfNeeded: number >> 16))
        append(UInt8(truncatingIfNeeded: number >> 8))
        append(UInt8(truncatingIfNeeded: number))
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
