import Foundation

@testable import LakeloomApp

/// Scriptable in-memory ``LakeloomAppClient`` for AuthService and
/// other consumer tests. Records configure/request/removeConfiguration
/// calls, returns canned responses for `request<T>` / `requestRaw` /
/// `currentBearer`.
public actor FakeLakeloomAppClient: LakeloomAppClient {

    public struct RequestCall: Sendable, Equatable {
        public let workspaceID: String
        public let method: HTTPMethod
        public let path: String
        public let body: Data?
        public let contentType: String?
    }

    public enum Outcome: Sendable {
        case success(Data)
        case failure(LakeloomAppError)
    }

    public private(set) var configured: [String: LakeloomAppClientConfig] = [:]
    public private(set) var removedConfigurations: [String] = []
    public private(set) var requestCalls: [RequestCall] = []
    private var responses: [Outcome] = []
    private var nextBearer: String = "fake-m2m-bearer"

    public init() {}

    public func enqueueResponse(_ outcome: Outcome) {
        responses.append(outcome)
    }

    public func setNextBearer(_ value: String) {
        nextBearer = value
    }

    public func configure(workspaceID: String, config: LakeloomAppClientConfig) async {
        configured[workspaceID] = config
    }

    public func removeConfiguration(workspaceID: String) async {
        configured[workspaceID] = nil
        removedConfigurations.append(workspaceID)
    }

    public func request<T: Decodable & Sendable>(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?,
        decode: T.Type
    ) async throws -> T {
        let data = try await requestRaw(workspaceID: workspaceID, method: method, path: path, body: body, contentType: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LakeloomAppError.decodeFailed(reason: String(describing: error))
        }
    }

    public func requestRaw(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        requestCalls.append(RequestCall(
            workspaceID: workspaceID,
            method: method,
            path: path,
            body: body,
            contentType: contentType
        ))
        guard !responses.isEmpty else {
            throw LakeloomAppError.transport(reason: "FakeLakeloomAppClient: no response enqueued")
        }
        let outcome = responses.removeFirst()
        switch outcome {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    public func currentBearer(workspaceID: String) async throws -> String {
        nextBearer
    }
}
