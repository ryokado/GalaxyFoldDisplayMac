# GalaxyFoldDisplayMac

Galaxy FoldをMacのサブ画面として使うためのMac側アプリ実験版です。

Macで選んだ画面を、同じWi-Fi上のGalaxy FoldのChromeへ配信します。
Fold側はアプリ不要で、Macアプリに表示されるQRコードを読み取るだけで表示できます。

> 現時点では「拡張ディスプレイ」ではなく「画面配信」です。
> Macの画面をFoldへ映すことはできますが、macOSの外部ディスプレイとして認識させる段階ではありません。

## できること

- Mac標準の画面選択から、共有する画面を選ぶ
- Macアプリ内で共有中の画面をプレビューする
- Galaxy Foldで開くURLを表示する
- Galaxy Foldで読み取るQRコードを表示する
- 選んだ画面をFold向けページへ連続JPEGストリームで配信する
- 表示設定を「速さ」「標準」「画質」から選ぶ

## 仕組み

```text
Macアプリ
  ↓ 画面を取得
Mac内蔵の小さなWebサーバー
  ↓ 同じWi-Fi
Galaxy FoldのChrome
```

Fold側は専用アプリを入れません。
Mac側アプリが画面を画像の連続として配信し、FoldのChromeがそれを表示します。

## 必要なもの

- macOS
- Xcode
- Galaxy FoldなどのAndroid端末
- MacとAndroid端末が同じWi-Fiにつながっていること

## セキュリティ方針

- MacのIPアドレスやQRコード用URLは、アプリ起動中にだけ画面へ表示します。
- IPアドレスやQRコード用URLは、ソースコードやREADMEには保存しません。
- GitHubには、個人のMac名、ユーザー名、ローカルの保存場所を含めない方針です。
- このアプリは同じWi-Fi内で使う前提です。公共Wi-Fiでは使わないでください。
- 使い終わったら、Macアプリ側で停止するかアプリを終了してください。

## 起動方法

Xcodeで以下を開きます。

```text
GalaxyFoldDisplayMac.xcodeproj
```

Xcode左上の再生ボタンで起動してください。

初回は画面収録の許可が必要になることがあります。

```text
システム設定
→ プライバシーとセキュリティ
→ 画面収録
→ GalaxyFoldDisplayMac を許可
```

許可後は、アプリまたはXcodeを一度再起動してください。

## Galaxy Foldで表示する手順

1. MacとGalaxy Foldを同じWi-Fiにつなぐ
2. Macアプリで「表示設定」を選ぶ
3. Macアプリで「標準画面選択で開始」を押す
4. Mac標準の画面選択で共有したい画面を選ぶ
5. Macアプリに表示されたQRコードをGalaxy Foldのカメラで読み取る
6. Galaxy FoldのChromeでページが開いたら表示を確認する

QRコードで開けない場合は、Macアプリに表示されたURLをGalaxy FoldのChromeへ直接入力してください。

## 表示設定

- 速さ: 遅延を下げたい時に使います。画質は少し落ちます。
- 標準: 通常はこちらを使います。
- 画質: 文字を読みやすくしたい時に使います。少し重くなります。

表示中に設定を変えた場合、画質はすぐ反映されます。
サイズと更新回数は、停止してもう一度開始すると反映されます。

## よくある問題

### 画面取得エラーが出る

Macの画面収録の許可が確認できていません。
システム設定でGalaxyFoldDisplayMacの画面収録を許可してください。

すでにオンなのに同じエラーが出る場合は、Xcodeから起動しているアプリと、設定画面で許可したアプリがMac内部で別物扱いになっている可能性があります。

その場合は次を試してください。

1. GalaxyFoldDisplayMacを終了する
2. Xcodeも終了する
3. システム設定の画面収録でGalaxyFoldDisplayMacを一度オフにする
4. もう一度オンにする
5. Xcodeを開き直して再生ボタンで起動する

### Galaxy Foldで白画面になる

QRコードがFoldから届かないMacのIPアドレスを指している可能性があります。
MacにはWi-Fi以外に、VPNや仮想ネットワークのIPが出ることがあります。

Macアプリに複数URLが表示されている場合は、別のURLも試してください。
特に `192.168.` から始まるURLがある場合は、それを優先してください。

接続だけ確認したい場合は、URLの末尾に `/check` を付けて開きます。

```text
例: http://<Macに表示されたIPアドレス>:8765/check
```

「接続できています」と表示されれば、FoldからMacアプリへの通信は届いています。

### 表示が止まる・遅い

Galaxy Fold側でページを再読み込みしてください。
遅延が気になる場合は「速さ」、文字が読みにくい場合は「画質」を試してください。

## 開発メモ

Codexで確認したビルドコマンドです。

```bash
xcodebuild -project 'GalaxyFoldDisplayMac.xcodeproj' -scheme GalaxyFoldDisplayMac -configuration Debug -derivedDataPath '../../build/GalaxyFoldDisplayMac-DerivedData' build
```

直近の確認結果: `BUILD SUCCEEDED`

## 次にやること

- Android側でより低遅延に表示できる方法を検証する
- scrcpy統合方式を検証する
- 本物の拡張ディスプレイ方式を検証する
- 配布用の署名設定を整える
