import CryptoKit
import Darwin
import Foundation

/// A kernel-managed lock; process exit (including a crash) releases ownership.
final class SingleInstanceGuard {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(executableURL: URL) throws -> SingleInstanceGuard? {
        let path = executableURL.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("BotSpeaker/InstanceLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(key + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return SingleInstanceGuard(descriptor: descriptor)
    }

    deinit {
        Darwin.close(descriptor)
        // Keep the file: unlinking it can let two processes lock different inodes.
    }
}
