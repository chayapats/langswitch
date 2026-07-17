import Foundation
import Darwin

/// Keeps two GUI instances from racing over the same global HID mapping.
final class SingleInstanceLock {
    private let descriptor: Int32

    init?() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.chayapats.langswitch.lock", isDirectory: false)

        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let fd = Darwin.open(lockURL.path, flags, mode)
        guard fd >= 0 else { return nil }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }

        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// Converts normal termination signals into an AppKit quit so cleanup runs.
/// SIGKILL and crashes are covered separately by the mapping watchdog.
final class TerminationSignalHandler {
    private let signals = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]
    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping () -> Void) {
        for signalNumber in signals {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources {
            source.cancel()
        }
        for signalNumber in signals {
            Darwin.signal(signalNumber, SIG_DFL)
        }
    }
}
