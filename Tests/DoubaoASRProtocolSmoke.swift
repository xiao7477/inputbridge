import Foundation

@main
struct DoubaoASRProtocolSmoke {
    static func main() throws {
        let initFrame = try DoubaoASRProtocol.configuration()
        precondition(Array(initFrame.prefix(4)) == [0x11, 0x10, 0x10, 0x00])
        let config = try JSONSerialization.jsonObject(with: initFrame.dropFirst(8)) as! [String: Any]
        let request = config["request"] as! [String: Any]
        precondition(request["enable_nonstream"] as? Bool == true)
        precondition(request["result_type"] as? String == "full")

        let audio = DoubaoASRProtocol.audio(Data([1, 2, 3]))
        precondition(Array(audio.prefix(8)) == [0x11, 0x20, 0x00, 0x00, 0, 0, 0, 3])
        let last = DoubaoASRProtocol.audio(Data(), last: true)
        precondition(Array(last.prefix(8)) == [0x11, 0x22, 0x00, 0x00, 0, 0, 0, 0])

        let floats: [Float] = [-1, 0, 1]
        let floatData = floats.withUnsafeBytes { Data($0) }
        precondition(DoubaoASRProtocol.pcm16(fromFloat32: floatData) ==
                     Data([0x01, 0x80, 0, 0, 0xff, 0x7f]))

        func response(_ json: [String: Any], flags: UInt8 = 0) throws -> DoubaoASRResponse {
            let payload = try JSONSerialization.data(withJSONObject: json)
            var frame = Data([0x11, 0x90 | flags, 0x10, 0x00])
            if flags & 1 != 0 { frame.append(contentsOf: [0, 0, 0, 1]) }
            let size = UInt32(payload.count)
            frame.append(contentsOf: [UInt8(truncatingIfNeeded: size >> 24),
                                      UInt8(truncatingIfNeeded: size >> 16),
                                      UInt8(truncatingIfNeeded: size >> 8),
                                      UInt8(truncatingIfNeeded: size)])
            frame.append(payload)
            return try DoubaoASRProtocol.decode(frame)
        }
        let partial = try response(["code": 0, "payload_msg": ["result": ["text": "你好"]]])
        precondition(partial.text == "你好" && !partial.isLast)
        let final = try response(["code": 0, "is_last_package": true,
                                  "payload_msg": ["result": ["text": "你好，世界。"]]], flags: 1)
        precondition(final.text == "你好，世界。" && final.isLast)
        let listResult = try response(["code": 0,
                                       "payload_msg": ["result": [["text": "测试"]]]])
        precondition(listResult.text == "测试")
        let failure = try response(["code": 401, "message": "unauthorized"])
        precondition(failure.error?.contains("unauthorized") == true)
        do {
            _ = try DoubaoASRProtocol.decode(Data([0x00]))
            fatalError("坏帧不应通过")
        } catch {}
        print("PASS: 豆包初始化、PCM、结束包与流式响应解析")
    }
}
