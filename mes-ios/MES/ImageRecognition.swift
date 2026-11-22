import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import Compression

enum ImageRecognition {
    static let maxPayload = 28 * 1024 * 1024
    static let materialCodes: [VNBarcodeSymbology] = [
        .code39, .code39Checksum, .code93, .code128, .ean8, .ean13, .upce,
        .i2of5, .i2of5Checksum, .itf14, .codabar
    ]

    static func jpeg(_ data: Data, maxDimension: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = thumbnail(source, dimension: maxDimension) else {
            throw MESError.message("無法開啟相機照片。")
        }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MESError.message("無法建立照片檔。")
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw MESError.message("無法完成照片轉換。") }
        return output as Data
    }

    private static func thumbnail(_ source: CGImageSource, dimension: Int) -> CGImage? {
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: dimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func recognize(_ dataURL: String, mode: String) throws -> String {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              data.count <= maxPayload,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = thumbnail(source, dimension: 2400) else {
            throw MESError.message("圖片無法讀取或超出大小限制。")
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if mode == "ocr" || mode == "bomOcr" {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try handler.perform([request])
            let observations = request.results ?? []
            if mode == "ocr" {
                return observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            var tokens: [[Any]] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let string = candidate.string
                let matches = string.split(whereSeparator: \.isWhitespace)
                for word in matches {
                    let range = word.startIndex..<word.endIndex
                    let rectangle = try? candidate.boundingBox(for: range)
                    if let box = rectangle?.boundingBox {
                        tokens.append([String(string[range]), box.minX, 1 - box.midY, box.maxX])
                    } else if matches.count == 1 {
                        let box = observation.boundingBox
                        tokens.append([string, box.minX, 1 - box.midY, box.maxX])
                    }
                }
            }
            return try json(tokens)
        }

        guard mode == "qr" || mode == "barcodes1d" else { throw MESError.message("不支援此辨識模式。") }
        let request = VNDetectBarcodesRequest()
        let available = try request.supportedSymbologies()
        let desired: [VNBarcodeSymbology] = mode == "qr" ? [.qr] : materialCodes
        request.symbologies = desired.filter(available.contains)
        guard !request.symbologies.isEmpty else { return mode == "qr" ? "" : "[]" }
        try handler.perform([request])
        let codes = (request.results ?? []).compactMap { match -> [String: Any]? in
            guard let payload = match.payloadStringValue, !payload.isEmpty else { return nil }
            let box = match.boundingBox
            return ["value": payload, "x": box.midX, "y": 1 - box.midY]
        }
        if mode == "barcodes1d" { return try json(codes) }
        let distinct = Set(codes.compactMap { $0["value"] as? String })
        guard distinct.count <= 1 else { throw MESError.message("照片有多個 QR，請選擇只含一個目標的照片。") }
        return distinct.first ?? ""
    }

    static func inflate(_ input: Data) throws -> Data {
        let bufferSize = 64 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { output.deallocate() }
        // compression_stream_init initializes the uninitialized C struct.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw MESError.message("無法啟動 Excel 解壓縮。")
        }
        defer { compression_stream_destroy(stream) }
        return try input.withUnsafeBytes { source -> Data in
            guard let start = source.bindMemory(to: UInt8.self).baseAddress else {
                throw MESError.message("Excel 壓縮資料為空。")
            }
            stream.pointee.src_ptr = start
            stream.pointee.src_size = input.count
            var result = Data()
            while true {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = bufferSize
                let previous = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let length = bufferSize - stream.pointee.dst_size
                guard result.count + length <= 32 * 1024 * 1024 else {
                    throw MESError.message("Excel 解壓縮資料過大。")
                }
                result.append(output, count: length)
                if status == COMPRESSION_STATUS_END { return result }
                guard status == COMPRESSION_STATUS_OK, length > 0 || previous != stream.pointee.src_size else {
                    throw MESError.message("Excel 壓縮資料已損毀。")
                }
            }
        }
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
