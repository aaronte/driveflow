import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that catches Google's OAuth redirect.
///
/// Google's installed-app (Desktop) clients only accept loopback redirects;
/// custom URL schemes like `driveflow://oauth` are refused with `invalid_request`.
final class LoopbackAuthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aaronte.driveflow.oauth-loopback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    /// Holds the redirect params when Google beats `waitForCallback()` to the punch.
    private var pendingParams: [String: String]?
    private var didStart = false
    private var didDeliver = false

    /// Binds an ephemeral loopback port and returns it.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    // Bind loopback only — never all interfaces.
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host("127.0.0.1"),
                        port: .any
                    )
                    let listener = try NWListener(using: parameters)
                    self.listener = listener

                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = listener.port?.rawValue {
                                self.finishStart(.success(port))
                            } else {
                                self.finishStart(.failure(AppError.authFailed("Couldn’t open a local callback port.")))
                            }
                        case .failed(let error):
                            self.finishStart(.failure(error))
                            self.deliver(.failure(error))
                        case .cancelled:
                            self.finishStart(.failure(AppError.authCancelled))
                        case .setup, .waiting:
                            break
                        @unknown default:
                            break
                        }
                    }

                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }

                    listener.start(queue: self.queue)
                } catch {
                    self.finishStart(.failure(error))
                }
            }
        }
    }

    /// Waits for the browser to hit the loopback URL, returning the query params.
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    if let pending = self.pendingParams {
                        self.pendingParams = nil
                        self.didDeliver = true
                        continuation.resume(returning: pending)
                        return
                    }
                    self.callbackContinuation = continuation
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Tears down the listener and unblocks any waiter (cancel / timeout / finished sign-in).
    func stop() {
        queue.async {
            self.deliver(.failure(AppError.authCancelled))
            self.finishStart(.failure(AppError.authCancelled))
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let error {
                self.deliver(.failure(error))
                connection.cancel()
                return
            }

            // Headers end at the blank line; the redirect carries everything in the URL.
            if let text = String(data: accumulated, encoding: .utf8),
               text.contains("\r\n\r\n") || text.contains("\n\n") {
                self.handleRequest(text, on: connection)
                return
            }

            if isComplete {
                if let text = String(data: accumulated, encoding: .utf8) {
                    self.handleRequest(text, on: connection)
                } else {
                    connection.cancel()
                }
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func handleRequest(_ request: String, on connection: NWConnection) {
        let params = Self.queryParams(fromRequestLine: request)
        let success = params["code"] != nil && params["error"] == nil
        respond(on: connection, success: success)

        if params.isEmpty {
            return
        }
        deliver(.success(params))
    }

    private func respond(on connection: NWConnection, success: Bool) {
        let title = success ? "Signed in to Driveflow" : "Sign-in didn’t finish"
        let detail = success
            ? "You can close this tab and return to the app."
            : "Return to Driveflow and try signing in again."
        let body = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;background:#F5F0E6;color:#1C1A18;\
        display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0">
        <div style="text-align:center;max-width:22rem">
        <h1 style="font-size:1.35rem;letter-spacing:-0.02em;margin:0 0 .5rem">\(title)</h1>
        <p style="color:#665F58;line-height:1.6;margin:0">\(detail)</p>
        </div></body></html>
        """
        let bytes = Array(body.utf8)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Continuation plumbing

    private func finishStart(_ result: Result<UInt16, Error>) {
        guard !didStart, let continuation = startContinuation else { return }
        didStart = true
        startContinuation = nil
        continuation.resume(with: result)
    }

    private func deliver(_ result: Result<[String: String], Error>) {
        guard !didDeliver else { return }
        guard let continuation = callbackContinuation else {
            // Redirect landed before the caller started waiting — hold onto it.
            if case .success(let params) = result {
                pendingParams = params
            }
            return
        }
        didDeliver = true
        callbackContinuation = nil
        continuation.resume(with: result)
    }

    /// Pulls the query items out of a raw `GET /?code=…&state=… HTTP/1.1` request.
    private static func queryParams(fromRequestLine request: String) -> [String: String] {
        guard let line = request.split(separator: "\n").first else { return [:] }
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return [:] }
        let target = String(fields[1])
        guard var components = URLComponents(string: "http://127.0.0.1\(target)") else { return [:] }
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%20")
        return (components.queryItems ?? []).reduce(into: [:]) { result, item in
            if let value = item.value { result[item.name] = value }
        }
    }
}
