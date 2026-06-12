//
//  ContentView.swift
//  GalaxyFoldDisplayMac
//
//  Created for GalaxyFoldDisplayMac.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var capture = ScreenCaptureModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            preview
        }
        .frame(minWidth: 980, minHeight: 620)
        .alert("画面取得エラー", isPresented: $capture.isShowingError) {
            Button("画面収録設定を開く") {
                openScreenRecordingSettings()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(capture.errorMessage)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Galaxy Fold Display")
                    .font(.title2.weight(.semibold))
                Text("Macの画面を選び、FoldのChromeへ表示します。")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            Button {
                capture.startWithSystemPicker()
            } label: {
                Label("標準画面選択で開始", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)

            capturePresetView

            Button {
                Task { await capture.refreshDisplays() }
            } label: {
                Label("画面一覧を手動更新", systemImage: "arrow.clockwise")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("手動で共有する画面")
                    .font(.headline)

                if capture.displays.isEmpty {
                    ContentUnavailableView(
                        "画面一覧は未取得です",
                        systemImage: "display",
                        description: Text("通常は上の標準画面選択を使ってください。必要な場合だけ手動更新します。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    List(capture.displays, selection: $capture.selectedDisplayID) { display in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name)
                                .font(.body.weight(.medium))
                            Text(display.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(display.id)
                    }
                    .frame(minHeight: 220)
                }
            }

            HStack {
                Button {
                    Task { await capture.startSelectedDisplay() }
                } label: {
                    Label("手動プレビュー開始", systemImage: "play.fill")
                }
                .disabled(capture.selectedDisplayID == nil || capture.isRunning)

                Button {
                    Task { await capture.stop() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!capture.isRunning)
            }

            statusView
            foldConnectionView

            Spacer()
        }
        .padding(20)
        .frame(width: 340)
    }

    private var capturePresetView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("表示設定")
                .font(.headline)

            Picker("表示設定", selection: $capture.capturePreset) {
                ForEach(CapturePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Text(capture.capturePreset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if capture.isRunning {
                Text("サイズと更新回数は、停止して再開すると反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(capture.statusText, systemImage: capture.isRunning ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(capture.isRunning ? .green : .secondary)

            Text("初回起動時に画面収録の許可が出たら許可してください。許可後はアプリの再起動が必要になることがあります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var foldConnectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(capture.serverStatusText, systemImage: "network")
                .foregroundStyle(.secondary)

            if let viewerURL = capture.primaryViewerURL {
                Text("MacとFoldを同じWi-Fiにつないでください。プレビュー開始後、このURLをFoldで開くと表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Foldで開くURL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(viewerURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))

                QRCodeView(text: viewerURL)
                    .frame(width: 180, height: 180)
                    .frame(maxWidth: .infinity)

                Text("FoldのカメラでQRを読み取るか、上のURLをChromeで開いてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if capture.viewerURLs.count > 1 {
                    Divider()

                    Text("白画面になる場合は、下の別URLも試してください。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(capture.viewerURLs.dropFirst(), id: \.self) { url in
                        Text(url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                Text("Fold接続用URLを準備しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var preview: some View {
        ZStack {
            Color.black

            CapturePreviewView(model: capture)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .padding(24)

            if !capture.isRunning {
                VStack(spacing: 10) {
                    Image(systemName: "display")
                        .font(.system(size: 44))
                    Text("画面を選んでプレビューを開始")
                        .font(.headline)
                    Text("ここにMac画面のプレビューが表示されます。")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
