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
    @StateObject private var scrcpy = ScrcpyManager()
    @State private var isScrcpyExpanded = false

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
        ScrollView(.vertical) {
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

                foldConnectionView

                directDisplayView

                manualDisplayView

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
                scrcpyView
            }
            .padding(20)
        }
        .scrollIndicators(.visible)
        .frame(width: 360)
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

    private var manualDisplayView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await capture.refreshDisplays() }
            } label: {
                Label("画面一覧を手動更新", systemImage: "arrow.clockwise")
            }

            Text("手動で共有する画面")
                .font(.headline)

            if capture.displays.isEmpty {
                ContentUnavailableView(
                    "画面一覧は未取得です",
                    systemImage: "display",
                    description: Text("通常は上の標準画面選択を使ってください。必要な場合だけ手動更新します。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 6) {
                    ForEach(capture.displays) { display in
                        Button {
                            capture.selectedDisplayID = display.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(display.name)
                                    .font(.body.weight(.medium))
                                Text(display.detail)
                                    .font(.caption)
                                    .foregroundStyle(capture.selectedDisplayID == display.id ? .white.opacity(0.85) : .secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                capture.selectedDisplayID == display.id ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(capture.selectedDisplayID == display.id ? .white : .primary)
                    }
                }
            }
        }
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

    private var directDisplayView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BetterDisplayの仮想画面")
                .font(.headline)

            Label(capture.directDisplayRefreshSummary, systemImage: "arrow.clockwise.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(capture.directDisplays) { display in
                    directDisplayButton(display)
                }
            }

            HStack {
                Button {
                    capture.refreshDirectDisplays()
                } label: {
                    Label("画面候補を再読み込み", systemImage: "arrow.clockwise")
                }
                .help("BetterDisplayで仮想画面を作った後や、解像度を変えた後に押します。")

                Button {
                    Task { await capture.startSelectedDirectDisplay() }
                } label: {
                    Label("直接配信開始", systemImage: "play.fill")
                }
                .disabled(capture.selectedDirectDisplayID == nil || capture.isRunning)
            }

            Text("3440 x 1440のような横長画面は、実物の外部モニターである可能性が高いです。Fold用は「Galaxy Fold候補」を選びます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(capture.directCaptureStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func directDisplayButton(_ display: DirectDisplay) -> some View {
        let isSelected = capture.selectedDirectDisplayID == display.id

        return Button {
            capture.selectedDirectDisplayID = display.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(display.name)
                        .font(.body.weight(.semibold))
                    if display.isRecommended {
                        Text("おすすめ")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isSelected ? .white.opacity(0.22) : Color.green.opacity(0.18), in: Capsule())
                    }
                }

                Text(display.detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.88) : .secondary)

                Text(display.helpText)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .primary)
    }

    private var scrcpyView: some View {
        DisclosureGroup(isExpanded: $isScrcpyExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Android内の仮想画面を作る実験用です。通常のFold表示には使いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        scrcpy.checkDevice()
                    } label: {
                        Label("接続確認", systemImage: "magnifyingglass")
                    }

                    Button {
                        scrcpy.startVirtualDisplay()
                    } label: {
                        Label("仮想画面起動", systemImage: "play.rectangle")
                    }
                    .disabled(scrcpy.isRunning)

                    Button {
                        scrcpy.stopVirtualDisplay()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .disabled(!scrcpy.isRunning)
                }

                Text(scrcpy.statusText)
                    .font(.caption.weight(.semibold))

                Text(scrcpy.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 6)
        } label: {
            Label("scrcpy検証", systemImage: "cable.connector")
                .font(.headline)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var foldConnectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(capture.serverStatusText, systemImage: "network")
                .foregroundStyle(.secondary)

            if let viewerURL = capture.primaryViewerURL {
                Text("FoldのカメラでQRを読み取ると表示できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QRCodeView(text: viewerURL)
                    .frame(width: 156, height: 156)
                    .frame(maxWidth: .infinity)

                Text(viewerURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))

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
