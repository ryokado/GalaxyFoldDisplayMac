import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import ScreenCaptureKit
import SwiftUI

struct CaptureDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let detail: String
    let source: SCDisplay
}

enum CapturePreset: String, CaseIterable, Identifiable {
    case speed
    case balanced
    case quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: "速さ"
        case .balanced: "標準"
        case .quality: "画質"
        }
    }

    var detail: String {
        switch self {
        case .speed: "遅延を下げます"
        case .balanced: "見やすさと軽さを両立します"
        case .quality: "文字を読みやすくします"
        }
    }

    var maxWidth: Int {
        switch self {
        case .speed: 1280
        case .balanced: 1600
        case .quality: 1920
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .speed: 24
        case .balanced: 30
        case .quality: 30
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .speed: 0.50
        case .balanced: 0.68
        case .quality: 0.82
        }
    }
}

private final class FrameEncodingSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var quality: CGFloat = CapturePreset.balanced.jpegQuality

    func update(quality: CGFloat) {
        lock.lock()
        self.quality = quality
        lock.unlock()
    }

    func jpegQuality() -> CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return quality
    }
}

@MainActor
final class ScreenCaptureModel: NSObject, ObservableObject {
    @Published var displays: [CaptureDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var capturePreset: CapturePreset = .balanced {
        didSet {
            encodingSettings.update(quality: capturePreset.jpegQuality)
        }
    }
    @Published var isRunning = false
    @Published var statusText = "待機中"
    @Published var serverStatusText = "Fold配信: 準備中"
    @Published var viewerURLs: [String] = []
    var primaryViewerURL: String? { viewerURLs.first }
    @Published var isShowingError = false
    @Published var errorMessage = ""

    weak var previewLayer: AVSampleBufferDisplayLayer?

    private let frameStore = SharedFrameStore()
    private var stream: SCStream?
    private var webServer: DisplayWebServer?
    nonisolated private let encodingSettings = FrameEncodingSettings()
    private let sampleQueue = DispatchQueue(label: "GalaxyFoldDisplayMac.ScreenCapture")
    private var isPickerConfigured = false

    override init() {
        super.init()

        let server = DisplayWebServer(frameStore: frameStore)
        server.onStatusChange = { [weak self] status, urls in
            self?.serverStatusText = status
            self?.viewerURLs = urls
        }
        webServer = server
        server.start()
    }

    func refreshDisplays() async {
        do {
            _ = requestScreenRecordingPermissionIfNeeded()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let nextDisplays = content.displays.map { display in
                CaptureDisplay(
                    id: display.displayID,
                    name: displayName(for: display),
                    detail: "\(display.width) x \(display.height)",
                    source: display
                )
            }

            displays = nextDisplays
            if selectedDisplayID == nil || !nextDisplays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = nextDisplays.first?.id
            }
            statusText = nextDisplays.isEmpty ? "画面が見つかりません" : "画面を選択できます"
        } catch {
            showError(
                """
                画面一覧を取得できませんでした。
                システム設定で画面収録を許可済みでも、Mac側の許可情報が壊れているか、反映待ちになっている可能性があります。

                まずGalaxyFoldDisplayMacとXcodeを終了し、Xcodeを開き直して再生してください。
                それでも同じ場合は、システム設定の画面収録でGalaxyFoldDisplayMacを一度オフにして、もう一度オンにしてください。
                """,
                error
            )
        }
    }

    func startSelectedDisplay() async {
        guard let selectedDisplayID,
              let display = displays.first(where: { $0.id == selectedDisplayID })?.source else {
            statusText = "画面を選択してください"
            return
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        await startCapture(
            filter: filter,
            width: display.width,
            height: display.height,
            label: displayName(for: display)
        )
    }

    func startWithSystemPicker() {
        guard #available(macOS 14.0, *) else {
            errorMessage = "このMacでは標準画面選択を使えません。画面一覧から選んでください。"
            isShowingError = true
            return
        }

        configureSystemPickerIfNeeded()
        statusText = "Mac標準の画面選択を開いています"
        SCContentSharingPicker.shared.present(using: .display)
    }

    private func startCapture(filter: SCContentFilter, width: Int, height: Int, label: String) async {
        await stop()

        do {
            let preset = capturePreset
            let dimensions = scaledDimensions(width: width, height: height, maxWidth: preset.maxWidth)
            let configuration = SCStreamConfiguration()
            configuration.width = dimensions.width
            configuration.height = dimensions.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.framesPerSecond))
            configuration.queueDepth = 6
            configuration.showsCursor = true
            configuration.capturesAudio = false

            let nextStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try nextStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await nextStream.startCapture()

            stream = nextStream
            isRunning = true
            statusText = "\(label) をプレビュー中（\(preset.title)）"
        } catch {
            showError("画面プレビューを開始できませんでした。", error)
        }
    }

    func stop() async {
        guard let activeStream = stream else {
            isRunning = false
            return
        }

        do {
            try await activeStream.stopCapture()
        } catch {
            showError("画面プレビューの停止中にエラーが起きました。", error)
        }

        stream = nil
        isRunning = false
        statusText = "停止しました"
        previewLayer?.flushAndRemoveImage()
    }

    private func displayName(for display: SCDisplay) -> String {
        return "Display \(display.displayID)"
    }

    private func scaledDimensions(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard width > maxWidth else {
            return (width, height)
        }

        let scale = Double(maxWidth) / Double(width)
        let scaledHeight = max(1, Int(Double(height) * scale))
        return (maxWidth, scaledHeight)
    }

    @available(macOS 14.0, *)
    private func configureSystemPickerIfNeeded() {
        guard !isPickerConfigured else { return }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay]
        configuration.allowsChangingSelectedContent = true
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }

        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true
        isPickerConfigured = true
    }

    private func requestScreenRecordingPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    private func showError(_ message: String, _ error: Error) {
        errorMessage = "\(message)\n\n\(error.localizedDescription)\n\n\(appIdentityText())"
        isShowingError = true
        statusText = "エラー"
        isRunning = false
    }

    private func appIdentityText() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "不明"
        let appPath = Bundle.main.bundleURL.path
        return """
        許可確認用:
        アプリID: \(bundleID)
        起動中の場所: \(appPath)
        """
    }
}

extension ScreenCaptureModel: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.showError("画面プレビューが停止しました。", error)
            self.stream = nil
        }
    }
}

@available(macOS 14.0, *)
extension ScreenCaptureModel: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            self.statusText = "画面選択をキャンセルしました"
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            await self.startCapture(
                filter: filter,
                width: 1920,
                height: 1200,
                label: "選択した画面"
            )
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.showError("Mac標準の画面選択を開始できませんでした。", error)
        }
    }
}

extension ScreenCaptureModel: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let jpegData = makeJPEGData(from: sampleBuffer)

        Task { @MainActor in
            if let jpegData {
                self.frameStore.update(frame: jpegData)
            }

            guard let layer = self.previewLayer else { return }
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sampleBuffer)
        }
    }

    nonisolated private func makeJPEGData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: imageBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let quality = encodingSettings.jpegQuality()
        return CIContext().jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
