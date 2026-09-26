import Foundation

@main
struct TransportSmoke {
    @MainActor
    static func main() async throws {
        let token = "local-test-token"
        let sampleNetstat = "tcp4 0 0 192.168.0.20.5900 192.168.0.11.54321 ESTABLISHED"
        precondition(ScreenSharingMonitor.parseRemoteAddresses(sampleNetstat,
                                                                direction: .incoming) == ["192.168.0.11"])
        let outgoingNetstat = "tcp4 0 0 192.168.0.20.54321 192.168.0.11.5900 ESTABLISHED"
        precondition(ScreenSharingMonitor.parseRemoteAddresses(outgoingNetstat,
                                                                direction: .outgoing) == ["192.168.0.11"])
        precondition(TargetResolver.addresses(for: "127.0.0.1") == ["127.0.0.1"])
        let controllerA = UUID()
        let controllerB = UUID()
        let server = TextTransportServer()
        let clientA = TextTransportClient()
        let clientB = TextTransportClient()
        var messageContinuation: AsyncStream<(TextMessage, UUID)>.Continuation!
        let messages = AsyncStream<(TextMessage, UUID)> { messageContinuation = $0 }
        var replyContinuation: AsyncStream<TextMessage>.Continuation!
        let replies = AsyncStream<TextMessage> { replyContinuation = $0 }
        server.onMessage = { messageContinuation.yield(($0, $1)) }
        server.onStatus = { FileHandle.standardError.write(Data("server: \($0)\n".utf8)) }
        server.onPeersChanged = { FileHandle.standardError.write(Data("peers: \($0.count)\n".utf8)) }
        clientA.onStatus = { FileHandle.standardError.write(Data("clientA: \($0)\n".utf8)) }
        clientA.onMessage = { replyContinuation.yield($0) }
        clientB.onStatus = { FileHandle.standardError.write(Data("clientB: \($0)\n".utf8)) }
        try server.start(port: 54839, token: token)
        try await Task.sleep(nanoseconds: 200_000_000)

        try await clientA.connect(host: "127.0.0.1", port: 54839, token: "",
                                  deviceID: controllerA, deviceName: "Mac A")
        try await clientB.connect(host: "127.0.0.1", port: 54839, token: "different-code",
                                  deviceID: controllerB, deviceName: "Mac B")
        precondition(server.peers.count == 2)
        precondition(Set(server.peers.values.map(\.name)) == ["Mac A", "Mac B"])
        precondition(Set(server.peers.values.map(\.address)) == ["127.0.0.1"])

        let sessionA = UUID()
        let sessionB = UUID()
        let audioPacket = Data(repeating: 0x2A, count: 2_048)
        let modelRequest = ModelRequest(mode: .automatic, preferred: .doubao,
                                        controllerHasDoubaoKey: true)
        let sent = [
            TextMessage(sessionId: sessionA, type: .audioStart, token: token,
                        senderID: controllerA, senderName: "Mac A", modelRequest: modelRequest),
            TextMessage(sessionId: sessionA, type: .audioChunk, audio: audioPacket,
                        token: token, senderID: controllerA, senderName: "Mac A"),
            TextMessage(sessionId: sessionA, type: .audioEnd, token: token,
                        senderID: controllerA, senderName: "Mac A"),
            TextMessage(sessionId: sessionB, type: .audioStart, token: token,
                        senderID: controllerB, senderName: "Mac B"),
            TextMessage(sessionId: sessionB, type: .audioEnd, token: token,
                        senderID: controllerB, senderName: "Mac B")
        ]
        for message in sent.prefix(3) { try clientA.send(message) }
        for message in sent.suffix(2) { try clientB.send(message) }

        var iterator = messages.makeAsyncIterator()
        var received: [TextMessage] = []
        var connectionForA: UUID?
        for _ in sent {
            guard let (message, connectionID) = await iterator.next() else { fatalError("未收到消息") }
            precondition(server.peers[connectionID]?.deviceID == message.senderID)
            if message.senderID == controllerA { connectionForA = connectionID }
            received.append(message)
        }
        precondition(received.filter { $0.senderID == controllerA }.map(\.type) == [
            .audioStart, .audioChunk, .audioEnd
        ])
        precondition(received.first { $0.type == .audioChunk }?.audio == audioPacket)
        precondition(received.first { $0.type == .audioStart && $0.senderID == controllerA }?.modelRequest == modelRequest)
        precondition(received.filter { $0.senderID == controllerB }.map(\.type) == [
            .audioStart, .audioEnd
        ])

        guard let connectionForA else { fatalError("找不到操作端连接") }
        let modelDecision = ModelDecision(provider: .apple, explanation: "B 未配置豆包")
        try server.send(
            TextMessage(sessionId: sessionA, type: .audioReady, token: token,
                        senderID: UUID(), senderName: "Mac 接收端",
                        modelDecision: modelDecision),
            to: connectionForA
        )
        var replyIterator = replies.makeAsyncIterator()
        let reply = await replyIterator.next()
        precondition(reply?.type == .audioReady)
        precondition(reply?.sessionId == sessionA)
        precondition(reply?.modelDecision == modelDecision)

        let capability = ModelCapability(preferred: .apple, hasDoubaoKey: false,
                                         resourceID: "volc.seedasr.sauc.duration")
        try server.send(TextMessage(sessionId: UUID(), type: .modelCapability, token: token,
                                    senderID: UUID(), senderName: "B", modelCapability: capability),
                        to: connectionForA)
        let capabilityReply = await replyIterator.next()
        precondition(capabilityReply?.modelCapability == capability)

        // Startup failure must reach A even before audioReady; completion and progress
        // remain in order and are delivered without a second pairing handshake.
        for kind in [MessageKind.audioStatus, .audioError, .audioComplete] {
            try server.send(TextMessage(sessionId: sessionA, type: kind, token: token,
                                        senderID: UUID(), senderName: "B",
                                        reason: "B 输入框未变化"), to: connectionForA)
            let reply = await replyIterator.next()
            precondition(reply?.type == kind)
            precondition(reply?.reason == "B 输入框未变化")
        }

        clientA.disconnect()
        clientB.disconnect()
        server.stop()

        server.pairingAuthorization = { _, _, _ in "不是当前屏幕共享操作端" }
        try server.start(port: 54840, token: token)
        try await Task.sleep(nanoseconds: 200_000_000)
        let rejected = TextTransportClient()
        do {
            try await rejected.connect(host: "127.0.0.1", port: 54840, token: "",
                                       deviceID: UUID(), deviceName: "错误来源")
            fatalError("非当前屏幕共享来源不应配对成功")
        } catch {
            precondition(error.localizedDescription.contains("不是当前屏幕共享操作端"))
        }
        server.stop()
        print("PASS: 多操作端 PCM、就绪/进度/早期失败/完成回执与拒绝原因反馈正确")
    }
}
