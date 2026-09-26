import AppKit
import WebKit
import ApplicationServices

/// Runs only against disposable controls owned by this test process. Never sends Return.
@main
struct RemoteKeyboardIntegration {
    @MainActor static func main() {
        guard AXIsProcessTrusted() else {
            print("SKIP: 此测试程序未获辅助功能授权，无法验证系统事件投递。")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let runner = Runner()
        app.delegate = runner
        app.run()
        withExtendedLifetime(runner) {}
    }
}

@MainActor
final class Runner: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var native: NSTextView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 240, width: 700, height: 350),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "语音输入共享：临时输入链路测试"
        native = NSTextView(frame: NSRect(x: 0, y: 240, width: 700, height: 110))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 230))
        web.navigationDelegate = self
        window.contentView?.addSubview(native)
        window.contentView?.addSubview(web)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.loadHTMLString("""
        <textarea id='plain' placeholder='灰色提示词' style='width:90%;height:60px'></textarea>
        <div id='rich' contenteditable='true' role='textbox' style='border:1px solid;width:90%;height:100px'></div>
        """, baseURL: nil)
        Task { try? await Task.sleep(for: .seconds(25)); finish("FAIL: 测试超时", code: 1) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
                let writer = try RemoteKeyboardWriter()
                window.makeFirstResponder(native)
                try await send("前文：你好", writer)
                guard native.string == "前文：你好" else { throw failure("native", native.string) }
                try writer.post(51, unicode: nil, to: getpid())
                try await send("们 Codex", writer)
                guard native.string == "前文：你们 Codex" else { throw failure("native revision", native.string) }
                print("PASS: 原生控件输入与尾句修订")

                window.makeFirstResponder(web)
                _ = try await web.evaluateJavaScript("document.getElementById('plain').focus(); true")
                try await send("中文 Codex", writer)
                let plain = try await web.evaluateJavaScript("document.getElementById('plain').value") as? String
                guard plain == "中文 Codex" else { throw failure("textarea", plain ?? "nil") }
                print("PASS: 网页 textarea 输入，无占位文字污染")

                _ = try await web.evaluateJavaScript("document.getElementById('rich').focus(); true")
                try await send("原文保留，你好", writer)
                try writer.post(51, unicode: nil, to: getpid())
                try await send("们 Claude 👋", writer)
                let rich = try await web.evaluateJavaScript("document.getElementById('rich').textContent") as? String
                guard rich == "原文保留，你们 Claude 👋" else { throw failure("contenteditable", rich ?? "nil") }
                finish("PASS: 网页 contenteditable 中文、英文、emoji 与流式修订", code: 0)
            } catch { finish("FAIL: \(error.localizedDescription)", code: 1) }
        }
    }

    func send(_ text: String, _ writer: RemoteKeyboardWriter) async throws {
        for character in text {
            try writer.post(0, unicode: String(character), to: getpid())
            try await Task.sleep(for: .milliseconds(3))
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    func failure(_ target: String, _ actual: String) -> Error {
        NSError(domain: "RemoteKeyboardIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(target): 实际测试内容 [\(actual)]"])
    }
    func finish(_ result: String, code: Int32) -> Never {
        print(result)
        fflush(stdout)
        window?.orderOut(nil)
        exit(code)
    }
}
