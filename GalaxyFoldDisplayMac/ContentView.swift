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
    @State private var isAdvancedExpanded = false
    @State private var isNetworkDetailsExpanded = false
    @State private var isScrcpyExpanded = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            preview
        }
        .frame(minWidth: 1040, minHeight: 660)
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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                appHeader
                foldConnectionView
            }
            .padding(20)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    directDisplayView
                    transmissionView
                    statusView
                    advancedView
                }
                .padding(20)
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 390)
        .background(.regularMaterial)
    }

    private var appHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("Galaxy Fold Display")
                    .font(.title3.weight(.semibold))
                Text("Macの仮想画面をFoldへ表示します")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var foldConnectionView: some View {
        sectionContainer {
            stepHeader(number: "1", title: "Foldに接続", systemImage: "qrcode.viewfinder")

            Label(capture.serverStatusText, systemImage: "network")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let viewerURL = capture.primaryViewerURL {
                Text("Galaxy Foldのカメラで読み取ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QRCodeView(text: viewerURL)
                    .frame(width: 158, height: 158)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)

                Text(viewerURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))

                if capture.viewerURLs.count > 1 {
                    DisclosureGroup(isExpanded: $isNetworkDetailsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("白画面になる場合だけ、下の別URLも試してください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(capture.viewerURLs.dropFirst(), id: \.self) { url in
                                Text(url)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("別URLを表示")
                            .font(.caption.weight(.semibold))
                    }
                }
            } else {
                Text("Fold接続用URLを準備しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var directDisplayView: some View {
        sectionContainer {
            HStack(alignment: .firstTextBaseline) {
                stepHeader(number: "2", title: "表示する画面", systemImage: "display")

                Spacer()

                Button {
                    capture.refreshDirectDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("BetterDisplayで仮想画面を作った後や、解像度を変えた後に押します。")
            }

            Label(capture.directDisplayRefreshSummary, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(capture.directDisplays) { display in
                    directDisplayButton(display)
                }
            }

            Text("Fold用は「Galaxy Fold候補」を選びます。3440 x 1440の横長画面は、実物の外部モニターの可能性が高いです。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transmissionView: some View {
        sectionContainer {
            stepHeader(number: "3", title: "配信", systemImage: "dot.radiowaves.left.and.right")

            Picker("表示設定", selection: $capture.capturePreset) {
                ForEach(CapturePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Text(capture.capturePreset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    Task { await capture.startSelectedDirectDisplay() }
                } label: {
                    Label("配信開始", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(capture.selectedDirectDisplayID == nil || capture.isRunning)

                Button {
                    Task { await capture.stop() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!capture.isRunning)
            }

            Label(capture.directCaptureStatusText, systemImage: capture.isRunning ? "checkmark.circle.fill" : "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(capture.isRunning ? .green : .secondary)

            if capture.isRunning {
                Text("表示設定の変更は、停止して再開すると反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusView: some View {
        sectionContainer {
            Label(capture.statusText, systemImage: capture.isRunning ? "checkmark.circle.fill" : "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(capture.isRunning ? .green : .secondary)

            Text("初回起動時に画面収録の許可が出たら許可してください。許可後はアプリの再起動が必要になることがあります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedView: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    capture.startWithSystemPicker()
                } label: {
                    Label("標準画面選択で開始", systemImage: "rectangle.on.rectangle")
                }

                manualDisplayView
                scrcpyView
            }
            .padding(.top, 8)
        } label: {
            Label("詳細設定", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var manualDisplayView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手動で共有する画面")
                .font(.subheadline.weight(.semibold))

            Button {
                Task { await capture.refreshDisplays() }
            } label: {
                Label("画面一覧を手動更新", systemImage: "arrow.clockwise")
            }

            if capture.displays.isEmpty {
                ContentUnavailableView(
                    "画面一覧は未取得です",
                    systemImage: "display",
                    description: Text("通常は上のFold用画面を使います。必要な場合だけ手動更新します。")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
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

                Button {
                    Task { await capture.startSelectedDisplay() }
                } label: {
                    Label("手動プレビュー開始", systemImage: "play.fill")
                }
                .disabled(capture.selectedDisplayID == nil || capture.isRunning)
            }
        }
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
                .font(.subheadline.weight(.semibold))
        }
    }

    private func directDisplayButton(_ display: DirectDisplay) -> some View {
        let isSelected = capture.selectedDirectDisplayID == display.id

        return Button {
            capture.selectedDirectDisplayID = display.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
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
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .primary)
    }

    private var preview: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .black),
                    Color(nsColor: .windowBackgroundColor).opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            CapturePreviewView(model: capture)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .padding(28)

            VStack {
                HStack {
                    statusBadge
                    Spacer()
                }
                Spacer()
            }
            .padding(20)

            if !capture.isRunning {
                VStack(spacing: 10) {
                    Image(systemName: "display")
                        .font(.system(size: 44))
                    Text("配信する画面を選んで開始")
                        .font(.headline)
                    Text("Foldへ送る映像がここに表示されます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var statusBadge: some View {
        Label(capture.isRunning ? "配信中" : "待機中", systemImage: capture.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(.black.opacity(0.36), in: Capsule())
    }

    private func sectionContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stepHeader(number: String, title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
