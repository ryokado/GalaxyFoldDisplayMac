import Combine
import Foundation

@MainActor
final class ScrcpyManager: ObservableObject {
    @Published var statusText = "未確認"
    @Published var detailText = "Galaxy FoldをUSB接続し、USBデバッグを許可してください。"
    @Published var isDeviceConnected = false
    @Published var isRunning = false

    private var scrcpyProcess: Process?
    private var scrcpyOutputPipe: Pipe?

    private let adbURL = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
    private let scrcpyURL = URL(fileURLWithPath: "/opt/homebrew/bin/scrcpy")
    private let homebrewPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    func checkDevice() {
        guard FileManager.default.isExecutableFile(atPath: adbURL.path) else {
            statusText = "adbが見つかりません"
            detailText = "Homebrewでandroid-platform-toolsをインストールしてください。"
            isDeviceConnected = false
            return
        }

        do {
            let output = try runAndRead(adbURL, arguments: ["devices", "-l"])
            let devices = output
                .split(separator: "\n")
                .dropFirst()
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if devices.contains(where: { $0.contains("device") && !$0.contains("unauthorized") }) {
                statusText = "Galaxy Foldを検出しました"
                detailText = devices.joined(separator: "\n")
                isDeviceConnected = true
            } else if devices.contains(where: { $0.contains("unauthorized") }) {
                statusText = "Fold側の許可待ち"
                detailText = "Galaxy Foldに表示されたUSBデバッグ許可で「許可」を押してください。"
                isDeviceConnected = false
            } else {
                statusText = "Android端末が見つかりません"
                detailText = "USBケーブルを接続し、Fold側でUSBデバッグをオンにしてください。"
                isDeviceConnected = false
            }
        } catch {
            statusText = "adb確認エラー"
            detailText = error.localizedDescription
            isDeviceConnected = false
        }
    }

    func startVirtualDisplay() {
        guard !isRunning else { return }

        guard FileManager.default.isExecutableFile(atPath: scrcpyURL.path) else {
            statusText = "scrcpyが見つかりません"
            detailText = "Homebrewでscrcpyをインストールしてください。"
            return
        }

        checkDevice()
        guard isDeviceConnected else { return }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = scrcpyURL
        process.arguments = [
            "--new-display=1920x1080/420",
            "--no-audio",
            "--max-fps=60",
            "--video-codec=h264",
            "--window-title=Galaxy Fold Virtual Display"
        ]
        process.environment = environmentWithHomebrewPath()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScrcpyTermination()
            }
        }

        do {
            try process.run()
            scrcpyProcess = process
            scrcpyOutputPipe = outputPipe
            isRunning = true
            statusText = "scrcpy起動中"
            detailText = "Android内の仮想ディスプレイをMacに表示しています。"
        } catch {
            statusText = "scrcpy起動エラー"
            detailText = error.localizedDescription
            isRunning = false
        }
    }

    func stopVirtualDisplay() {
        scrcpyProcess?.terminate()
        scrcpyProcess = nil
        scrcpyOutputPipe = nil
        isRunning = false
        statusText = "scrcpy停止"
        detailText = "仮想ディスプレイを停止しました。"
    }

    private func handleScrcpyTermination() {
        let output = readScrcpyOutput()
        scrcpyProcess = nil
        scrcpyOutputPipe = nil
        isRunning = false
        statusText = "scrcpy停止"
        detailText = output.isEmpty ? "仮想ディスプレイを停止しました。" : output
    }

    private func environmentWithHomebrewPath() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = homebrewPath
        return environment
    }

    private func readScrcpyOutput() -> String {
        guard let pipe = scrcpyOutputPipe else { return "" }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runAndRead(_ executableURL: URL, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environmentWithHomebrewPath()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
