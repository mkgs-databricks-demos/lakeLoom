import Foundation

/// Lightweight `URLProtocol` stub for tests that hit `URLSession`.
///
/// Tests build a `URLSession` via ``makeSession(handler:)`` and pass
/// it into the network layer under test; the supplied handler receives
/// each `URLRequest` and returns the `(HTTPURLResponse, Data)` to
/// surface back to the client. No real HTTP traffic occurs.
public final class StubURLProtocol: URLProtocol {

    /// Per-session handler. Stored by `URLSessionConfiguration`'s
    /// associated `requestKey` so concurrent test sessions don't bleed
    /// into each other.
    private static let handlerKey = "lakeloom.stub.handler"
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> (HTTPURLResponse, Data)] = [:]
    private static let lock = NSLock()

    public static func makeSession(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let id = UUID().uuidString
        lock.lock()
        handlers[id] = handler
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [handlerKey: id]
        return URLSession(configuration: config)
    }

    // MARK: URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard
            let id = request.value(forHTTPHeaderField: Self.handlerKey),
            let handler = Self.lookupHandler(id: id)
        else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "StubURLProtocolError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "no handler registered"]
                )
            )
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}

    private static func lookupHandler(id: String) -> (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[id]
    }
}

/// Helper to read the request body in test handlers.
///
/// `URLProtocol` strips `httpBody` from `request` when the body was
/// uploaded as a stream (which `URLSession` does for many requests).
/// We hold the original request in a side channel so handler closures
/// can still read the bytes they were sent.
extension URLRequest {
    public var lakeloomTestBody: Data? {
        if let body = self.httpBody { return body }
        guard let stream = self.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let chunkSize = 4096
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
