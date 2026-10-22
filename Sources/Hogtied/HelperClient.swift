import Foundation
import Darwin
import Security
import HogCore
import HogIPC

private final class ReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?
    var connectionDidFail: ((String) -> Void)?

    func availability() -> (Bool, String) {
        do {
            let trust = try HelperTrust.load()
            guard trust.AllowedUserID == getuid() else { return (false, "The helper is installed for another user.") }
            guard Self.currentCodeHash() == trust.ClientCodeHash else {
                return (false, "Reinstall the helper for this version of Hogtied.")
            }
            return (true, "Installed · available for third-party system processes")
        } catch { return (false, "Not installed · your own processes can still be force-quit") }
    }

    private static func currentCodeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any], let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func getConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let trust = try HelperTrust.load()
        guard trust.AllowedUserID == getuid(), trust.ClientCodeHash == Self.currentCodeHash() else {
            throw HelperError("Reinstall the administrator helper for this app and user.")
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HogHelperProtocol.self)
        connection.setCodeSigningRequirement(trust.helperRequirement)
        connection.interruptionHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.connection?.invalidate()
                self.connection = nil
                self.connectionDidFail?("Administrator helper disconnected. The next check will try again.")
            }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.connection = nil
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    func updatePolicy(settings: HogSettings, revision: UInt64, retries: [UUID: RetryState] = [:]) {
        guard let connection, let data = try? JSONEncoder().encode(HelperPolicy(revision: revision, settings: settings, retries: retries)) else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? HogHelperProtocol
        proxy?.updatePolicy(data, withReply: { _ in })
        if !settings.administratorEnabled { disconnect() }
    }

    func disconnect() {
        let old = connection
        connection = nil
        old?.invalidate()
    }

    func check(settings: HogSettings, revision: UInt64, apps: [RunningApp], enforce: Bool,
               retries: [UUID: RetryState]) async throws -> HelperCheckResponse {
        let connection = try getConnection()
        let request = HelperCheckRequest(policy: HelperPolicy(revision: revision, settings: settings, retries: retries), apps: apps, enforce: enforce)
        let data = try JSONEncoder().encode(request)
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate<Data>(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                gate.finish(.failure(HelperError("Administrator helper did not respond. Check its status in Login Items & Extensions.")))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler {
                gate.finish(.failure(HelperError("Administrator helper: \($0.localizedDescription)")))
            } as? HogHelperProtocol
            guard let proxy else { gate.finish(.failure(HelperError("Could not connect to the administrator helper."))); return }
            proxy.performCheck(data) { result, error in
                if let error { gate.finish(.failure(HelperError(error))) }
                else if let result { gate.finish(.success(result)) }
                else { gate.finish(.failure(HelperError("Administrator helper returned an empty reply."))) }
            }
        }
        guard response.count <= 20_000_000 else { throw HelperError("Administrator reply is too large.") }
        let report = try JSONDecoder().decode(HelperCheckResponse.self, from: response)
        guard report.version == HelperConstants.protocolVersion else { throw HelperError("Reinstall the helper for this version of Hogtied.") }
        return report
    }
}
