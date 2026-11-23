import AVFoundation
import PhotosUI
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

final class MESViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, PHPickerViewControllerDelegate {
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
        case "shareReport":
            shareReport(body, reply: reply)
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
                if mode == .document && value == CameraController.openGallery {
                    self?.chooseBomPhoto()
                } else if stream {
                    if mode == .document && error == nil && !value.isEmpty {
                        self?.emit(receiver, event: "qr", value: value)
                    }
                    self?.emit(receiver, event: "finished", value: error ?? "")
                }
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

    private func chooseBomPhoto() {
        guard presentedViewController == nil else {
            emit("__mesBomCapture", event: "finished", value: "無法開啟相簿。")
            return
        }
        var settings = PHPickerConfiguration()
        settings.filter = .images
        settings.selectionLimit = 1
        let picker = PHPickerViewController(configuration: settings)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else {
            emit("__mesBomCapture", event: "finished", value: "")
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            let image = (object as? UIImage)?.jpegData(compressionQuality: 0.95)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let image {
                    self.sendCapture(image, receiver: "__mesBomCapture")
                    self.emit("__mesBomCapture", event: "finished", value: "")
                } else { self.emit("__mesBomCapture", event: "finished", value: "無法讀取相簿照片。") }
            }
        }
    }

    private func shareReport(_ body: [String: Any], reply: @escaping Reply) {
        guard let encoded = body["images"] as? String, encoded.utf8.count <= 28 * 1024 * 1024 else {
            reply(nil, "回報圖片資料過大，請改用匯出完整報告。")
            return
        }
        let name = (body["name"] as? String ?? "MES核對回報")
            .replacingOccurrences(of: "[^\\p{L}0-9_-]", with: "_", options: .regularExpression)
            .prefix(80)
        io.async { [weak self] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let result = Result { () throws -> [URL] in
                let entries = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
                guard (1...40).contains(entries.count) else { throw MESError.message("圖片頁數有誤。") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return try entries.enumerated().map { index, entry in
                    guard let image = Data(base64Encoded: entry), image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                        throw MESError.message("無效的 PNG 圖片。")
                    }
                    let filename = "\(name)_\(index + 1).png"
                    let file = directory.appendingPathComponent(filename)
                    try image.write(to: file, options: .atomic)
                    return file
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentedViewController == nil, self.view.window != nil else {
                    try? FileManager.default.removeItem(at: directory)
                    reply(nil, "無法開啟系統分享選單。")
                    return
                }
                switch result {
                case .success(let files):
                    let share = UIActivityViewController(activityItems: files, applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.view
                    share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
                    self.present(share, animated: true) { reply("opened", nil) }
                case .failure(let error):
                    try? FileManager.default.removeItem(at: directory)
                    reply(nil, error.localizedDescription)
                }
            }
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
                                 in: nil, in: .page, completionHandler: nil)
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
