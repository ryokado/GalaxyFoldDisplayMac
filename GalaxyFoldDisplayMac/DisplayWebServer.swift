@preconcurrency import Foundation
@preconcurrency import Network
import Security

@MainActor
final class DisplayWebServer {
    var onStatusChange: ((String, [String]) -> Void)?

    private let frameStore: SharedFrameStore
    private let preferredPort: UInt16
    private let maxPort: UInt16
    private var currentPort: UInt16
    private let queue = DispatchQueue(label: "GalaxyFoldDisplayMac.DisplayWebServer")
    private let streamBoundary = "galaxyfoldframe"
    private var listener: NWListener?
    private let accessKey: String

    init(frameStore: SharedFrameStore, port: UInt16 = 8765) {
        self.frameStore = frameStore
        self.preferredPort = port
        self.maxPort = port + 20
        self.currentPort = port
        self.accessKey = Self.makeAccessKey()
    }

    // アプリ起動ごとに作り直すランダムな合言葉。
    // QRコードのURLに含まれ、これが一致しないアクセスには画面を返さない。
    private static func makeAccessKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() {
        start(on: preferredPort)
    }

    private func start(on port: UInt16) {
        do {
            let nextListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            currentPort = port
            nextListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handle(state: state)
                }
            }
            nextListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener = nextListener
            nextListener.start(queue: queue)
        } catch {
            retryOrFail(after: error, port: port)
        }
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            onStatusChange?("Fold配信: 起動中", viewerURLs())
        case .failed(let error):
            retryOrFail(after: error, port: currentPort)
        case .cancelled:
            onStatusChange?("Fold配信: 停止", [])
        default:
            break
        }
    }

    private func retryOrFail(after error: Error, port: UInt16) {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        guard port < maxPort else {
            onStatusChange?("Fold配信エラー: \(error.localizedDescription)", [])
            return
        }

        let nextPort = port + 1
        onStatusChange?("Fold配信: \(port)番が使用中。\(nextPort)番を試します", [])
        start(on: nextPort)
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            Task { @MainActor in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let path = requestPath(from: request)

        // /check は接続確認専用で画面情報を含まないため、合言葉なしで開ける。
        if path == "/check" {
            sendCheckPage(on: connection)
            return
        }

        guard requestKey(from: request) == accessKey else {
            sendUnauthorized(on: connection)
            return
        }

        if path == "/" {
            sendHTML(on: connection)
        } else if path == "/frame.jpg" {
            sendFrame(on: connection)
        } else if path == "/stream.mjpg" {
            sendMJPEGStream(on: connection)
        } else if path == "/status.json" {
            sendJSON(on: connection)
        } else {
            sendNotFound(on: connection)
        }
    }

    private func requestPath(from request: String) -> String {
        guard let firstLine = request.split(separator: "\r\n").first else { return "/" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let rawPath = String(parts[1])
        return rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    }

    private func requestKey(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let pieces = String(parts[1]).split(separator: "?", maxSplits: 1)
        guard pieces.count == 2 else { return nil }

        for pair in pieces[1].split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2, keyValue[0] == "key" {
                return String(keyValue[1])
            }
        }
        return nil
    }

    private func sendHTML(on connection: NWConnection) {
        let html = """
        <!doctype html>
        <html lang="ja">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>Galaxy Fold Display</title>
            <style>
              html, body { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; font-family: system-ui, sans-serif; }
              #top { position: fixed; left: env(safe-area-inset-left); right: env(safe-area-inset-right); top: env(safe-area-inset-top); z-index: 2; display: flex; gap: 8px; align-items: center; padding: 10px; color: #fff; background: rgba(0,0,0,.72); }
              #status { flex: 1; font-weight: 700; }
              button { border: 0; border-radius: 8px; min-height: 36px; padding: 0 12px; color: #fff; background: #1c6b4f; font: inherit; font-weight: 700; }
              #frame { display: block; width: 100vw; height: 100vh; object-fit: contain; background: #000; }
              #frame.cover { object-fit: cover; }
            </style>
          </head>
          <body>
            <div id="top">
              <span id="status">Macの画面を待っています</span>
              <button id="fit">表示切替</button>
            </div>
            <img id="frame" alt="Macの共有画面">
            <script>
              const frame = document.getElementById('frame');
              const status = document.getElementById('status');
              let reconnectTimer = null;

              function startStream() {
                clearTimeout(reconnectTimer);
                status.textContent = 'Macの画面を待っています';
                frame.src = '/stream.mjpg?key=\(accessKey)&ts=' + Date.now();
              }

              async function updateStatus() {
                try {
                  const res = await fetch('/status.json?key=\(accessKey)&ts=' + Date.now(), { cache: 'no-store' });
                  const json = await res.json();
                  if (!json.hasFrame) {
                    status.textContent = 'Mac側でプレビュー開始してください';
                    return;
                  }
                  status.textContent = json.ageMs > 2500 ? 'Mac側の送信が止まっています' : '表示中';
                } catch (error) {
                  status.textContent = '接続できません';
                }
              }
              frame.addEventListener('load', () => { status.textContent = '表示中'; });
              frame.addEventListener('error', () => {
                status.textContent = '再接続中';
                reconnectTimer = setTimeout(startStream, 500);
              });
              document.getElementById('fit').addEventListener('click', () => frame.classList.toggle('cover'));
              setInterval(updateStatus, 1000);
              startStream();
              updateStatus();
            </script>
          </body>
        </html>
        """
        send(body: Data(html.utf8), contentType: "text/html; charset=utf-8", on: connection)
    }

    private func sendCheckPage(on connection: NWConnection) {
        let html = """
        <!doctype html>
        <html lang="ja">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>接続確認</title>
            <style>
              body { margin: 0; padding: 24px; background: #101413; color: #f4f7f5; font-family: system-ui, sans-serif; }
              h1 { font-size: 24px; margin: 0 0 12px; }
              p { color: #c9d2cd; line-height: 1.55; }
              code { background: #202725; padding: 3px 6px; border-radius: 6px; }
            </style>
          </head>
          <body>
            <h1>接続できています</h1>
            <p>この画面が見えていれば、Galaxy FoldからMacアプリへの通信は届いています。</p>
            <p>共有画面を見るにはURL末尾を消して <code>/</code> を開き、Mac側でプレビューを開始してください。</p>
          </body>
        </html>
        """
        send(body: Data(html.utf8), contentType: "text/html; charset=utf-8", on: connection)
    }

    private func sendFrame(on connection: NWConnection) {
        guard let frame = frameStore.latestFrame else {
            send(status: "204 No Content", body: Data(), contentType: "text/plain", on: connection)
            return
        }
        send(body: frame, contentType: "image/jpeg", on: connection)
    }

    private func sendMJPEGStream(on connection: NWConnection) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: multipart/x-mixed-replace; boundary=\(streamBoundary)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }

            Task { @MainActor in
                self?.sendNextStreamFrame(on: connection, lastDate: nil)
            }
        })
    }

    private func sendNextStreamFrame(on connection: NWConnection, lastDate: Date?) {
        let snapshot = frameStore.snapshot()

        guard let frame = snapshot.frame, snapshot.date != lastDate else {
            queue.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
                Task { @MainActor in
                    self?.sendNextStreamFrame(on: connection, lastDate: lastDate)
                }
            }
            return
        }

        var part = Data()
        part.append("--\(streamBoundary)\r\n".data(using: .utf8)!)
        part.append("Content-Type: image/jpeg\r\n".data(using: .utf8)!)
        part.append("Content-Length: \(frame.count)\r\n\r\n".data(using: .utf8)!)
        part.append(frame)
        part.append("\r\n".data(using: .utf8)!)

        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }

            self?.queue.asyncAfter(deadline: .now() + .milliseconds(33)) {
                Task { @MainActor in
                    self?.sendNextStreamFrame(on: connection, lastDate: snapshot.date)
                }
            }
        })
    }

    private func sendJSON(on connection: NWConnection) {
        let ageMs: Int?
        if let frameDate = frameStore.frameDate {
            ageMs = Int(Date().timeIntervalSince(frameDate) * 1000)
        } else {
            ageMs = nil
        }

        let body = """
        {"hasFrame":\(frameStore.latestFrame == nil ? "false" : "true"),"ageMs":\(ageMs.map(String.init) ?? "null")}
        """
        send(body: Data(body.utf8), contentType: "application/json; charset=utf-8", on: connection)
    }

    private func sendUnauthorized(on connection: NWConnection) {
        let html = """
        <!doctype html>
        <html lang="ja">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>表示できません</title>
            <style>
              body { margin: 0; padding: 24px; background: #101413; color: #f4f7f5; font-family: system-ui, sans-serif; }
              h1 { font-size: 24px; margin: 0 0 12px; }
              p { color: #c9d2cd; line-height: 1.55; }
            </style>
          </head>
          <body>
            <h1>このURLでは表示できません</h1>
            <p>合言葉が確認できませんでした。</p>
            <p>Macアプリに表示されている最新のQRコードを読み取り直してください。</p>
          </body>
        </html>
        """
        send(status: "403 Forbidden", body: Data(html.utf8), contentType: "text/html; charset=utf-8", on: connection)
    }

    private func sendNotFound(on connection: NWConnection) {
        send(status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain; charset=utf-8", on: connection)
    }

    private func send(body: Data, contentType: String, on connection: NWConnection) {
        send(status: "200 OK", body: body, contentType: contentType, on: connection)
    }

    private func send(status: String, body: Data, contentType: String, on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func viewerURLs() -> [String] {
        let urls = localIPv4Addresses().map { "http://\($0):\(currentPort)/?key=\(accessKey)" }
        return urls.isEmpty ? ["http://localhost:\(currentPort)/?key=\(accessKey)"] : urls
    }

    private func localIPv4Addresses() -> [String] {
        var entries: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = cursor.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }

            var address = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                entries.append((name: name, address: String(cString: hostname)))
            }
        }

        return entries
            .sorted { left, right in
                score(left) < score(right)
            }
            .map(\.address)
            .reduce(into: []) { result, address in
                if !result.contains(address) {
                    result.append(address)
                }
            }
    }

    private func score(_ entry: (name: String, address: String)) -> Int {
        if entry.name == "en0" { return 0 }
        if entry.address.hasPrefix("192.168.") { return 1 }
        if entry.address.hasPrefix("10.") { return 2 }
        if isPrivate172(entry.address) { return 3 }
        if entry.address.hasPrefix("100.") { return 20 }
        return 10
    }

    private func isPrivate172(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4, let second = Int(parts[1]) else { return false }
        return parts[0] == "172" && (16...31).contains(second)
    }
}
