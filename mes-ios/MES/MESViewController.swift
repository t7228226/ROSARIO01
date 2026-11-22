import AVFoundation
import UIKit
import WebKit

private typealias Reply = (Any?, String?) -> Void

private final class MessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var receiver: MESViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        Task { @MainActor [weak receiver] in
            guard let receiver else { replyHandler(nil, "App 已關閉。"); return }
            receiver.receive(message, reply: replyHandler)
        }
    }
}

final class MESViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let io = DispatchQueue(label: "MES.storage-and-recognition", qos: .userInitiated)
    private var web: WKWebView?
    private var entry: URL?
    private var camera: CameraController?
    private var cameraOpening = false
    private var captures: [String: Data] = [:]
    private var captureBytes = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.92, green: 0.95, blue: 0.93, alpha: 1)
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets"),
              let script = Bundle.main.url(forResource: "ios-bridge", withExtension: "js", subdirectory: "WebAssets"),
              let bridge = try? String(contentsOf: script, encoding: .utf8) else {
            let label = UILabel(frame: view.bounds.insetBy(dx: 20, dy: 20))
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.text = "找不到離線巡檢資源，請重新安裝。"
            label.numberOfLines = 0
            label.textAlignment = .center
            view.addSubview(label)
            return
        }
        entry = index
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let messageHandler = MessageHandler()
        messageHandler.receiver = self
        config.userContentController.addScriptMessageHandler(messageHandler, contentWorld: .page, name: "mesIOS")
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        let page = WKWebView(frame: .zero, configuration: config)
        page.navigationDelegate = self
        page.uiDelegate = self
        web = page
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([page.topAnchor.constraint(equalTo: safe.topAnchor),
                                     page.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                                     page.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                                     page.trailingAnchor.constraint(equalTo: safe.trailingAnchor)])
        page.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let trusted = navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == entry
        decisionHandler(trusted ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        camera?.finish()
        captures.removeAll()
        captureBytes = 0
        if let entry { webView.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent()) }
    }

    fileprivate func receive(_ message: WKScriptMessage, reply: @escaping Reply) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url == entry,
              let body = message.body as? [String: Any], let action = body["action"] as? String else {
            reply(nil, "無效的原生請求。")
            return
        }
        switch action {
        case "scan":
            let mode: CameraController.Mode = body["mode"] as? String == "QR" ? .qr : .linear
            openCamera(mode, reply: reply)
        case "capture":
            let mode: CameraController.Mode = body["document"] as? Bool == true ? .document : .batch
            openCamera(mode, reply: reply)
        case "singlePhoto":
            openCamera(.single, reply: reply)
        case "finishCapture":
            camera?.finish()
            reply("", nil)
        case "progress":
            if let count = body["count"] as? Int { camera?.updateReviewed(count) }
            reply("", nil)
        case "captureData", "releaseCapture":
            let token = body["token"] as? String ?? ""
            let data = captures.removeValue(forKey: token)
            captureBytes -= data?.count ?? 0
            if action == "releaseCapture" { reply("", nil) }
            else if let data { reply(data.base64EncodedString(), nil) }
            else { reply(nil, "無法讀取相機照片。") }
        default:
            io.async {
                let result = Result { try BridgeWorker.process(action, body: body) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let value): reply(value, nil)
                    case .failure(let error): reply(nil, error.localizedDescription)
                    }
                }
            }
        }
    }

    private func openCamera(_ mode: CameraController.Mode, reply: @escaping Reply) {
        guard !cameraOpening, camera == nil, presentedViewController == nil else {
            reply(nil, "相機正在使用中。")
            return
        }
        cameraOpening = true
        func presentIfAllowed(_ allowed: Bool) {
            cameraOpening = false
            guard allowed else {
                reply(nil, "未授予相機權限，可改從相簿選取或在「設定」開啟權限。")
                return
            }
            let stream = mode == .batch || mode == .document
            let receiver = mode == .document ? "__mesBomCapture" : "__mesCameraEvent"
            var still: Data?
            let controller = CameraController(mode: mode, onPhoto: { [weak self] data in
                if stream { self?.sendCapture(data, receiver: receiver) }
                else { still = data }
            }, onFinish: { [weak self] value, error in
                self?.camera = nil
                if stream { self?.emit(receiver, event: "finished", value: error ?? "") }
                else if let error { reply(nil, error) }
                else if mode == .single { reply(still?.base64EncodedString() ?? "", nil) }
                else { reply(value, nil) }
            })
            camera = controller
            present(controller, animated: true)
            if stream { reply("", nil) }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: presentIfAllowed(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                DispatchQueue.main.async { presentIfAllowed(allowed) }
            }
        default: presentIfAllowed(false)
        }
    }

    private func sendCapture(_ data: Data, receiver: String) {
        guard captureBytes + data.count <= 60 * 1024 * 1024 else {
            camera?.finishWithError("暫存照片過多，請重新開啟相機。")
            return
        }
        let token = UUID().uuidString
        captures[token] = data
        captureBytes += data.count
        emit(receiver, event: "photo", value: token)
    }

    private func emit(_ receiver: String, event: String, value: String) {
        web?.callAsyncJavaScript("window[receiver]?.(event, value); return null;",
                                 arguments: ["receiver": receiver, "event": event, "value": value],
                                 in: nil, contentWorld: .page, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        showDialog(message: message, cancel: nil) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        showDialog(message: message, cancel: { completionHandler(false) }) { _ in completionHandler(true) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        showDialog(message: prompt, text: defaultText ?? "", cancel: { completionHandler(nil) }, accept: completionHandler)
    }

    private func showDialog(message: String, text: String? = nil, cancel: (() -> Void)?, accept: @escaping (String?) -> Void) {
        guard presentedViewController == nil else {
            if let cancel { cancel() } else { accept(nil) }
            return
        }
        let alert = UIAlertController(title: "MES 巡檢", message: message, preferredStyle: .alert)
        if let text { alert.addTextField { $0.text = text } }
        if let cancel { alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in cancel() }) }
        alert.addAction(UIAlertAction(title: "確認", style: .default) { [weak alert] _ in accept(alert?.textFields?.first?.text) })
        present(alert, animated: true)
    }
}

private enum BridgeWorker {
    static func process(_ action: String, body: [String: Any]) throws -> String {
        let fm = FileManager.default
        let records = LocalStore(root: try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("MES", isDirectory: true))
        func text(_ key: String, max: Int = 2048) throws -> String {
            guard let value = body[key] as? String, value.utf8.count <= max else {
                throw MESError.message("原生輸入資料格式錯誤或過大。")
            }
            return value
        }
        func bytes() throws -> Data {
            let value = try text("data", max: 4 * ((ImageRecognition.maxPayload + 2) / 3))
            guard let data = Data(base64Encoded: value), data.count <= ImageRecognition.maxPayload else {
                throw MESError.message("原生輸入資料無法解析。")
            }
            return data
        }
        switch action {
        case "recognize":
            return try ImageRecognition.recognize(text("data", max: 40 * 1024 * 1024), mode: text("mode"))
        case "inflate":
            return try ImageRecognition.inflate(bytes()).base64EncodedString()
        case "get":
            return try records.read(text("group"), text("key"))
        case "put":
            try records.write(text("group"), text("key"), text("value", max: 32 * 1024 * 1024))
        case "removePhotos":
            guard let keys = body["keys"] as? [String] else { throw MESError.message("照片清單格式錯誤。") }
            try records.removePhotos(keys)
        case "save":
            let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let exports = documents.appendingPathComponent("MES 匯出", isDirectory: true)
            _ = try LocalStore.writeExport(text("name"), data: bytes(), directory: exports)
            return "saved"
        default:
            throw MESError.message("不支援的原生操作。")
        }
        return ""
    }
}
