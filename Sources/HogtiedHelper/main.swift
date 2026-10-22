import Foundation
import Darwin
import HogIPC

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let trust: HelperTrust
    init(trust: HelperTrust) { self.trust = trust }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == trust.AllowedUserID else { return false }
        connection.setCodeSigningRequirement(trust.clientRequirement)
        let worker = HelperWorker(clientUID: connection.effectiveUserIdentifier, clientPID: connection.processIdentifier)
        connection.exportedInterface = NSXPCInterface(with: HogHelperProtocol.self)
        connection.exportedObject = worker
        connection.invalidationHandler = { worker.invalidate() }
        connection.interruptionHandler = { worker.invalidate() }
        connection.resume()
        return true
    }
}

guard geteuid() == 0 else {
    fputs("This helper is started by launchd after administrator installation.\n", stderr)
    exit(1)
}
do {
    let trust = try HelperTrust.load()
    let listener = NSXPCListener(machServiceName: HelperConstants.service)
    listener.setConnectionCodeSigningRequirement(trust.clientRequirement)
    let delegate = ListenerDelegate(trust: trust)
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime(delegate) { dispatchMain() }
} catch {
    fputs("Hogtied helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
