import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import ScreenCaptureKit
import SwiftUI

struct DirectDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let displayNumber: Int
    let name: String
    let detail: String
    let helpText: String
    let isRecommended: Bool
    let sortPriority: Int
    let width: Int
    let height: Int
}

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

private enum ScreenRecordingAccessError: LocalizedError {
    case notGranted

    var errorDescription: String? {
        "画面収録の許可をMacがまだ確認できていません。"
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
    @Published var directDisplays: [DirectDisplay] = []
    @Published var selectedDirectDisplayID: CGDirectDisplayID?
    @Published var directDisplayRefreshSummary = "BetterDisplayで仮想画面を作った後に、ここで候補を再読み込みできます。"
    @Published var displays: [CaptureDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var capturePreset: CapturePreset = .balanced {
        didSet {
            encodingSettings.update(quality: capturePreset.jpegQuality)
        }
    }
    @Published var isRunning = false
    @Published var statusText = "待機中"
    @Published var directCaptureStatusText = "直接配信: 未開始"
    @Published var displayPlacementStatusText = "配置: 前回の位置へ戻します。初回はMacBook本体の左側へ自動配置します"
    @Published var serverStatusText = "Fold配信: 準備中"
    @Published var viewerURLs: [String] = []
    var primaryViewerURL: String? { viewerURLs.first }
    @Published var isShowingError = false
    @Published var errorMessage = ""

    weak var previewLayer: AVSampleBufferDisplayLayer?

    private let frameStore = SharedFrameStore()
    private var stream: SCStream?
    private var screenshotTask: Task<Void, Never>?
    private var webServer: DisplayWebServer?
    nonisolated private let encodingSettings = FrameEncodingSettings()
    private let sampleQueue = DispatchQueue(label: "GalaxyFoldDisplayMac.ScreenCapture")
    private var isPickerConfigured = false
    private var isDirectHighSpeedCapture = false
    private var directHighSpeedFrameCount = 0
    private var didRequestScreenRecordingAccess = false

    override init() {
        super.init()
        Self.removeStaleTemporaryImages()

        let server = DisplayWebServer(frameStore: frameStore)
        server.onStatusChange = { [weak self] status, urls in
            self?.serverStatusText = status
            self?.viewerURLs = urls
        }
        webServer = server
        server.start()
        refreshDirectDisplays()
    }

    func refreshDirectDisplays() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let nextDisplays = ids.enumerated().map { index, id in
            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            let bounds = CGDisplayBounds(id)
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let displayDescription = Self.directDisplayDescription(
                id: id,
                width: width,
                height: height,
                bounds: bounds,
                isBuiltin: isBuiltin
            )

            return DirectDisplay(
                id: id,
                displayNumber: index + 1,
                name: displayDescription.name,
                detail: displayDescription.detail,
                helpText: displayDescription.helpText,
                isRecommended: displayDescription.isRecommended,
                sortPriority: displayDescription.sortPriority,
                width: width,
                height: height
            )
        }

        directDisplays = nextDisplays.sorted { left, right in
            if left.sortPriority == right.sortPriority {
                if left.name == right.name {
                    return left.id < right.id
                }
                return left.name < right.name
            }
            return left.sortPriority < right.sortPriority
        }

        if selectedDirectDisplayID == nil || !directDisplays.contains(where: { $0.id == selectedDirectDisplayID }) {
            selectedDirectDisplayID = directDisplays.first(where: \.isRecommended)?.id
                ?? directDisplays.first(where: { !$0.name.contains("MacBook内蔵") })?.id
                ?? directDisplays.first?.id
        }

        updateDirectDisplayRefreshSummary()
        statusText = directDisplays.isEmpty ? "直接選べる画面が見つかりません" : "直接選べる画面を更新しました"
    }

    func refreshDisplays() async {
        do {
            guard requestScreenRecordingPermissionIfNeeded() else {
                showScreenRecordingAccessError()
                return
            }

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

    func startSelectedDirectDisplay() async {
        guard let selectedDirectDisplayID,
              let display = directDisplays.first(where: { $0.id == selectedDirectDisplayID }) else {
            statusText = "直接配信する画面を選択してください"
            return
        }

        await startDirectDisplayCapture(display)
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
        isDirectHighSpeedCapture = false
        directHighSpeedFrameCount = 0

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

    private func startDirectDisplayCapture(_ display: DirectDisplay) async {
        arrangeDirectDisplayLeftOfMacBookIfNeeded(display)

        if await startScreenCaptureKitDirectDisplay(display) {
            return
        }

        await stop()

        let preset = capturePreset
        isRunning = true
        isDirectHighSpeedCapture = false
        directHighSpeedFrameCount = 0
        statusText = "\(display.name) を直接配信中（\(preset.title)）"
        directCaptureStatusText = "直接配信: 低速配信で開始中"
        screenshotTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runScreenshotLoop(displayNumber: display.displayNumber, preset: preset)
        }
    }

    private func startScreenCaptureKitDirectDisplay(_ directDisplay: DirectDisplay) async -> Bool {
        do {
            guard CGPreflightScreenCaptureAccess() else {
                showScreenRecordingAccessError()
                return true
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == directDisplay.id }) else {
                directCaptureStatusText = "直接配信: 高速配信対象が見つからないため低速配信へ切替"
                return false
            }

            await stop()

            let preset = capturePreset
            let dimensions = scaledDimensions(width: display.width, height: display.height, maxWidth: preset.maxWidth)
            let configuration = SCStreamConfiguration()
            configuration.width = dimensions.width
            configuration.height = dimensions.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.framesPerSecond))
            configuration.queueDepth = 6
            configuration.showsCursor = true
            configuration.capturesAudio = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let nextStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try nextStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await nextStream.startCapture()

            stream = nextStream
            isRunning = true
            isDirectHighSpeedCapture = true
            directHighSpeedFrameCount = 0
            statusText = "\(directDisplay.name) を高速配信中（\(preset.title)）"
            directCaptureStatusText = "直接配信: 高速配信中"
            return true
        } catch {
            directCaptureStatusText = "直接配信: 高速配信不可のため低速配信へ切替"
            return false
        }
    }

    func stop() async {
        if let activeScreenshotTask = screenshotTask {
            activeScreenshotTask.cancel()
            screenshotTask = nil
            isRunning = false
            isDirectHighSpeedCapture = false
            directHighSpeedFrameCount = 0
            statusText = "停止しました"
            directCaptureStatusText = "直接配信: 停止"
            previewLayer?.flushAndRemoveImage()
            return
        }

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
        isDirectHighSpeedCapture = false
        directHighSpeedFrameCount = 0
        statusText = "停止しました"
        previewLayer?.flushAndRemoveImage()
    }

    private func displayName(for display: SCDisplay) -> String {
        return "Display \(display.displayID)"
    }

    private func arrangeDirectDisplayLeftOfMacBookIfNeeded(_ display: DirectDisplay) {
        guard CGDisplayIsBuiltin(display.id) == 0 else {
            displayPlacementStatusText = "配置: MacBook本体の画面なので自動配置は行いません"
            return
        }

        let anchorID = Self.builtInDisplayID() ?? CGMainDisplayID()
        guard display.id != anchorID else {
            displayPlacementStatusText = "配置: 基準画面なので自動配置は行いません"
            return
        }

        let anchorBounds = CGDisplayBounds(anchorID)
        let targetBounds = CGDisplayBounds(display.id)
        guard anchorBounds.width > 0, targetBounds.width > 0 else {
            displayPlacementStatusText = "配置: 画面位置を確認できませんでした"
            return
        }

        let savedOrigin = Self.savedDisplayOrigin(for: display)
        let fallbackOrigin = CGPoint(x: anchorBounds.minX - targetBounds.width, y: anchorBounds.minY)
        let nextOrigin = savedOrigin ?? fallbackOrigin
        let nextX = Int32(nextOrigin.x.rounded())
        let nextY = Int32(nextOrigin.y.rounded())
        let placementLabel = savedOrigin == nil ? "MacBook本体の左側" : "前回の位置"

        if Int32(targetBounds.origin.x.rounded()) == nextX,
           Int32(targetBounds.origin.y.rounded()) == nextY {
            Self.saveDisplayOrigin(CGPoint(x: CGFloat(nextX), y: CGFloat(nextY)), for: display)
            displayPlacementStatusText = "配置: Fold画面はすでに\(placementLabel)です"
            return
        }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else {
            displayPlacementStatusText = "配置: 左側への自動配置を開始できませんでした"
            return
        }

        let moveResult = CGConfigureDisplayOrigin(configuration, display.id, nextX, nextY)
        guard moveResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            displayPlacementStatusText = "配置: 左側への自動配置に失敗しました"
            return
        }

        let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
        if completeResult == .success {
            Self.saveDisplayOrigin(CGPoint(x: CGFloat(nextX), y: CGFloat(nextY)), for: display)
            displayPlacementStatusText = "配置: Fold画面を\(placementLabel)へ自動配置しました"
            refreshDirectDisplays()
        } else {
            displayPlacementStatusText = "配置: 左側への自動配置を保存できませんでした"
        }
    }

    private static func builtInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func savedDisplayOrigin(for display: DirectDisplay) -> CGPoint? {
        let defaults = UserDefaults.standard
        let xKey = displayPlacementKey("x", for: display)
        let yKey = displayPlacementKey("y", for: display)
        guard defaults.object(forKey: xKey) != nil,
              defaults.object(forKey: yKey) != nil else {
            return nil
        }

        return CGPoint(
            x: defaults.double(forKey: xKey),
            y: defaults.double(forKey: yKey)
        )
    }

    private static func saveDisplayOrigin(_ origin: CGPoint, for display: DirectDisplay) {
        let defaults = UserDefaults.standard
        defaults.set(origin.x, forKey: displayPlacementKey("x", for: display))
        defaults.set(origin.y, forKey: displayPlacementKey("y", for: display))
    }

    private static func displayPlacementKey(_ axis: String, for display: DirectDisplay) -> String {
        "GalaxyFoldDisplayMac.lastDisplayOrigin.\(display.width)x\(display.height).\(axis)"
    }

    private func updateDirectDisplayRefreshSummary() {
        let timeText = Date.now.formatted(date: .omitted, time: .standard)

        guard !directDisplays.isEmpty else {
            directDisplayRefreshSummary = "\(timeText)に再読み込みしました。画面候補は見つかりませんでした。"
            return
        }

        let foldCandidateCount = directDisplays.filter(\.isRecommended).count
        let selectedName = directDisplays.first(where: { $0.id == selectedDirectDisplayID })?.name ?? "未選択"

        if foldCandidateCount > 0 {
            directDisplayRefreshSummary = "\(timeText)に再読み込み: \(directDisplays.count)件 / Fold候補 \(foldCandidateCount)件 / 選択中: \(selectedName)"
        } else {
            directDisplayRefreshSummary = "\(timeText)に再読み込み: \(directDisplays.count)件。Fold候補がない場合は、BetterDisplayで仮想画面を作ってからもう一度押してください。"
        }
    }

    private static func directDisplayDescription(
        id: CGDirectDisplayID,
        width: Int,
        height: Int,
        bounds: CGRect,
        isBuiltin: Bool
    ) -> (name: String, detail: String, helpText: String, isRecommended: Bool, sortPriority: Int) {
        let aspectRatio = Double(max(width, height)) / Double(max(1, min(width, height)))
        let isVeryWide = aspectRatio >= 1.9
        let isLikelyFoldVirtualDisplay = !isBuiltin && !isVeryWide && width >= 1000 && height >= 1000
        let position = directDisplayPositionText(bounds)
        let mainText = CGMainDisplayID() == id ? " / メイン画面" : ""
        let detail = "\(width) x \(height) / \(position)\(mainText)"

        if isBuiltin {
            return (
                "MacBook内蔵画面",
                detail,
                "MacBook本体の画面です。Fold用の仮想画面ではありません。",
                false,
                3
            )
        }

        if isLikelyFoldVirtualDisplay {
            return (
                "Galaxy Fold候補（BetterDisplay）",
                detail,
                "BetterDisplayで作ったFold用の仮想画面候補です。迷ったらまずこれを選んでください。",
                true,
                0
            )
        }

        if isVeryWide {
            return (
                "外部モニターらしき画面（横長）",
                detail,
                "3440 x 1440などの横長画面は、実物の外部モニターである可能性が高いです。Fold用でなければ選ばなくて大丈夫です。",
                false,
                2
            )
        }

        return (
            "外部/仮想画面",
            detail,
            "外部モニターまたは仮想画面です。BetterDisplayで作った解像度と一致するか確認してください。",
            false,
            1
        )
    }

    private static func directDisplayPositionText(_ bounds: CGRect) -> String {
        let x = Int(bounds.origin.x)
        let y = Int(bounds.origin.y)

        if x == 0 && y == 0 {
            return "基準位置"
        }
        if abs(x) >= abs(y) {
            return x > 0 ? "右側に配置" : "左側に配置"
        }
        return y > 0 ? "下側に配置" : "上側に配置"
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

        guard !didRequestScreenRecordingAccess else {
            return false
        }

        didRequestScreenRecordingAccess = true
        return CGRequestScreenCaptureAccess()
    }

    private func showScreenRecordingAccessError() {
        showError(
            """
            画面収録の許可がまだMacに反映されていません。

            何度も確認画面が出ないように、今回は画面取得を開始しませんでした。

            システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で /Applications/GalaxyFoldDisplayMac.app をオンにしてください。
            すでにオンの場合は、このアプリを完全終了してから開き直してください。
            """,
            ScreenRecordingAccessError.notGranted
        )
    }

    nonisolated private func runScreenshotLoop(displayNumber: Int, preset: CapturePreset) async {
        let delayNanoseconds = switch preset {
        case .speed: UInt64(140_000_000)
        case .balanced: UInt64(200_000_000)
        case .quality: UInt64(300_000_000)
        }

        var failureCount = 0
        var frameCount = 0

        while !Task.isCancelled {
            if let jpegData = Self.captureDisplayImage(displayNumber: displayNumber) {
                failureCount = 0
                frameCount += 1
                let sentFrameCount = frameCount
                let imageSizeText = Self.byteSizeText(jpegData.count)
                await MainActor.run {
                    self.frameStore.update(frame: jpegData)
                    self.directCaptureStatusText = "直接配信: 低速配信で\(sentFrameCount)枚送信中 / 最新 \(imageSizeText)"
                }
            } else {
                failureCount += 1
                if failureCount >= 1 {
                    await MainActor.run {
                        self.screenshotTask = nil
                        self.isRunning = false
                        self.statusText = "直接配信を停止しました"
                        self.directCaptureStatusText = "直接配信: 画像を作れませんでした"
                        self.errorMessage = """
                        直接配信を開始できませんでした。

                        Macの画面収録がまだ許可されていないか、許可ダイアログで拒否されました。
                        繰り返し確認が出ないように配信処理を停止しました。

                        許可する場合は、システム設定の画面収録で /Applications/GalaxyFoldDisplayMac.app を許可してから、アプリを起動し直してください。
                        """
                        self.isShowingError = true
                    }
                    return
                }
            }

            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
    }

    nonisolated private static func captureDisplayImage(displayNumber: Int) -> Data? {
        let fileURL = temporaryImageURL()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", "-tjpg", "-D\(displayNumber)", fileURL.path]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = try Data(contentsOf: fileURL)
            try? FileManager.default.removeItem(at: fileURL)
            return data
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    nonisolated private static func temporaryImageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyFoldDisplayMac-\(UUID().uuidString).jpg")
    }

    nonisolated private static func removeStaleTemporaryImages() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-60 * 10)
        for file in files where file.lastPathComponent.hasPrefix("GalaxyFoldDisplayMac-") && file.pathExtension == "jpg" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if values?.contentModificationDate ?? .distantPast < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    nonisolated private static func byteSizeText(_ byteCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteCount))
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
            self.isDirectHighSpeedCapture = false
            self.directHighSpeedFrameCount = 0
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
                if self.isDirectHighSpeedCapture {
                    self.directHighSpeedFrameCount += 1
                    let imageSizeText = Self.byteSizeText(jpegData.count)
                    self.directCaptureStatusText = "直接配信: 高速配信で\(self.directHighSpeedFrameCount)枚送信中 / 最新 \(imageSizeText)"
                }
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
