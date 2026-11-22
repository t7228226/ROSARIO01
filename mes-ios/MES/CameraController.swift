import AVFoundation
import UIKit

/// Used on the capture queue. The preview reads only the session reference.
private final class CameraHardware {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var device: AVCaptureDevice?

    func configure(_ mode: CameraController.Mode,
                   delegate: AVCapturePhotoCaptureDelegate & AVCaptureMetadataOutputObjectsDelegate) throws -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw MESError.message("找不到後置相機。")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw MESError.message("無法啟用相機。") }
        let scanning = mode == .qr || mode == .linear
        session.sessionPreset = scanning ? .high : .photo
        session.addInput(input)
        device = camera
        if scanning {
            guard session.canAddOutput(metadataOutput) else { throw MESError.message("無法啟用掃描。") }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(delegate, queue: .main)
            let linear: [AVMetadataObject.ObjectType] = [.code39, .code39Mod43, .code93, .code128, .ean8, .ean13, .upce, .interleaved2of5, .itf14, .codabar]
            let desired: [AVMetadataObject.ObjectType] = mode == .qr ? [.qr] : linear
            let formats = desired.filter(metadataOutput.availableMetadataObjectTypes.contains)
            guard !formats.isEmpty else { throw MESError.message("此裝置無法讀取所選條碼格式。") }
            metadataOutput.metadataObjectTypes = formats
        } else {
            guard session.canAddOutput(photoOutput) else { throw MESError.message("無法開啟拍照。") }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = mode == .document ? .quality : .balanced
            if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        return camera.hasTorch
    }

    func capture(_ settings: AVCapturePhotoSettings, delegate: AVCapturePhotoCaptureDelegate) {
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    func toggleLamp() throws -> Bool? {
        guard let device, device.hasTorch, device.isTorchAvailable, session.isRunning else { return nil }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let enable = device.torchMode != .on
        device.torchMode = enable ? .on : .off
        return enable
    }
}

final class CameraController: UIViewController, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate {
    enum Mode: Sendable { case document, batch, single, qr, linear }
    nonisolated private let mode: Mode
    private let onPhoto: (Data) -> Void
    private let onFinish: (String, String?) -> Void
    private let captureQueue = DispatchQueue(label: "MES.camera")
    private let hardware = CameraHardware()
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: hardware.session)
    private let status = UILabel()
    private let shutter = UIButton(type: .system)
    private let lamp = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private var ready = false
    private var finished = false
    private var ending = false
    private var taking = false
    private var pendingPhotoID: Int64?
    private var captured = 0
    private var reviewed = 0

    init(mode: Mode, onPhoto: @escaping (Data) -> Void, onFinish: @escaping (String, String?) -> Void) {
        self.mode = mode
        self.onPhoto = onPhoto
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("CameraController uses programmatic layout") }

    private var scanning: Bool { mode == .qr || mode == .linear }
    private var titleText: String {
        switch mode {
        case .document: return "拍攝 BOM"
        case .batch: return "連續拍照核對"
        case .single: return "拍攝物料"
        case .qr: return "掃描工單 QR"
        case .linear: return "掃描一維條碼"
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(previewLayer)

        let safe = view.safeAreaLayoutGuide
        let headingLabel = UILabel()
        headingLabel.text = titleText
        headingLabel.font = .preferredFont(forTextStyle: .headline)
        headingLabel.textColor = .white
        headingLabel.adjustsFontForContentSizeCategory = true
        status.textColor = .white
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.text = "正在啟用相機…"
        let heading = UIStackView(arrangedSubviews: [headingLabel, status])
        heading.axis = .vertical
        heading.spacing = 5
        heading.layoutMargins = UIEdgeInsets(top: 11, left: 15, bottom: 11, right: 15)
        heading.isLayoutMarginsRelativeArrangement = true
        heading.backgroundColor = UIColor(red: 0.06, green: 0.23, blue: 0.19, alpha: 0.94)

        configure(lamp, title: "照明", action: #selector(toggleLamp))
        configure(shutter, title: mode == .batch ? "拍一張" : "拍攝", action: #selector(capturePhoto), prominent: true)
        configure(done, title: mode == .batch ? "完成拍攝" : "取消", action: #selector(finish))
        lamp.isEnabled = false
        shutter.isEnabled = false
        let controls = UIStackView(arrangedSubviews: scanning ? [lamp, done] : [lamp, shutter, done])
        controls.spacing = 7
        controls.distribution = .fillEqually
        controls.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        controls.isLayoutMarginsRelativeArrangement = true
        controls.backgroundColor = heading.backgroundColor
        for stack in [heading, controls] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                                         stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor)])
        }
        NSLayoutConstraint.activate([heading.topAnchor.constraint(equalTo: safe.topAnchor),
                                     controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                                     controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 68)])
        startSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    private func configure(_ button: UIButton, title: String, action: Selector, prominent: Bool = false) {
        var style = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        style.title = title
        style.baseBackgroundColor = prominent ? UIColor(red: 0.72, green: 0.93, blue: 0.81, alpha: 1) : .white
        style.baseForegroundColor = prominent ? .black : .white
        button.configuration = style
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func startSession() {
        captureQueue.async { [weak self, hardware, mode] in
            guard let self else { return }
            do {
                let torch = try hardware.configure(mode, delegate: self)
                hardware.session.startRunning()
                let started = hardware.session.isRunning
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.finished else { return }
                    guard started else { self.complete(error: "相機無法啟動。"); return }
                    self.ready = true
                    self.lamp.isEnabled = torch
                    self.updateControls()
                    self.view.setNeedsLayout()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.complete(error: error.localizedDescription) }
            }
        }
    }

    @objc private func capturePhoto() {
        guard ready, !ending, !taking, captured < 30 else { return }
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = mode == .document ? .quality : .balanced
        pendingPhotoID = settings.uniqueID
        taking = true
        updateControls()
        captureQueue.async { [weak self, hardware, settings] in
            guard let self else { return }
            hardware.capture(settings, delegate: self)
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<Data, Error> = Result {
            if let error { throw error }
            guard let data = photo.fileDataRepresentation() else { throw MESError.message("無法取得照片。") }
            return try ImageRecognition.jpeg(data, maxDimension: mode == .document ? 2400 : 1800)
        }
        handlePhotoResult(result, id: photo.resolvedSettings.uniqueID)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { handlePhotoResult(.failure(error), id: resolvedSettings.uniqueID) }
    }

    nonisolated private func handlePhotoResult(_ result: Result<Data, Error>, id: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished, self.pendingPhotoID == id else { return }
            self.pendingPhotoID = nil
            self.taking = false
            if self.ending && self.mode != .batch { self.complete(); return }
            switch result {
            case .success(let data):
                self.captured += 1
                self.onPhoto(data)
                guard !self.finished else { return }
                if self.ending || self.mode != .batch { self.complete() }
                else { self.updateControls() }
            case .failure:
                if self.ending { self.complete(error: "最後一張未能拍下。") }
                else {
                    self.updateControls()
                    self.status.text = "拍攝失敗，請重拍。"
                }
            }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let values = Set(objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            if values.count == 1, let value = values.first { self.complete(value: value) }
            else if values.count > 1 { self.status.text = "畫面有多個條碼，請只對準目標。" }
            else { self.updateControls() }
        }
    }

    func updateReviewed(_ count: Int) {
        guard mode == .batch, !finished else { return }
        reviewed = max(reviewed, count)
        updateControls()
    }

    private func updateControls() {
        shutter.isEnabled = ready && !taking && !ending && !finished && captured < 30
        done.isEnabled = !ending
        if mode == .batch {
            let suffix = taking ? " · 正在拍攝…" : captured >= 30 ? " · 已達 30 張" : ""
            status.text = "已拍 \(captured) 張 · 已核對 \(reviewed) 張" + suffix
        } else if mode == .document {
            status.text = taking ? "正在拍攝…" : "請拍清楚工單編號、序號與整欄料號。"
        } else if scanning {
            status.text = "將目標條碼放在畫面中央。"
        } else {
            status.text = taking ? "正在拍攝…" : "請將料號標籤拍清楚。"
        }
    }

    @objc func finish() {
        guard !finished, !ending else { return }
        ending = true
        if taking && mode == .batch { updateControls() }
        else { complete() }
    }

    func finishWithError(_ message: String) {
        complete(error: message)
    }

    @objc private func toggleLamp() {
        captureQueue.async { [weak self, hardware] in
            guard let enabled = try? hardware.toggleLamp() else { return }
            DispatchQueue.main.async { [weak self] in self?.lamp.configuration?.title = enabled ? "關照明" : "照明" }
        }
    }

    private func complete(value: String = "", error: String? = nil) {
        guard !finished else { return }
        finished = true
        captureQueue.async { [hardware] in hardware.session.stopRunning() }
        dismiss(animated: true) { [onFinish] in onFinish(value, error) }
    }
}
