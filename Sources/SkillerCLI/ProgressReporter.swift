import Foundation
import SkillerKit

/// Prints what a long-running command is doing.
///
/// Everything goes to standard error, so `--json` output and piped stdout stay clean.
/// On a terminal the transient line is overwritten in place; redirected, only the milestones
/// are printed, because a log full of half-second percentage updates is worse than none.
///
/// A class with a lock rather than a struct: the progress callback is `@Sendable` and gets
/// called from whatever thread is draining the child process.
final class ProgressReporter: Sendable {
    private let isInteractive: Bool
    private let state = Lock()

    init(isInteractive: Bool = isatty(FileHandle.standardError.fileDescriptor) == 1) {
        self.isInteractive = isInteractive
    }

    /// git prefixes the interesting phases with these; the rest of what it writes is noise
    /// like "remote: Enumerating objects" repeated per packet.
    private static let phasesWorthShowing = [
        "Receiving objects", "Resolving deltas", "Counting objects", "Compressing objects",
        "Updating files", "Cloning into",
    ]

    func report(_ progress: SkillInstaller.Progress) {
        switch progress {
        case .cloning(let repo):
            milestone("cloning \(repo) …")
        case .updating(let repo):
            milestone("fetching \(repo) …")
        case .scanning(let repo):
            milestone("scanning \(repo) for \(SkillManifest.fileName) …")
        case .resolvingLicense:
            // Fast enough not to be worth a line of its own once the clone is done.
            break
        case .git(let line):
            guard isInteractive, Self.phasesWorthShowing.contains(where: line.hasPrefix) else { return }
            transient(line)
        }
    }

    /// Removes any transient line, so the command's real output starts on a clean row.
    func finish() {
        state.withLock { pending in
            guard pending else { return }
            write("\r\u{1B}[K")
            pending = false
        }
    }

    // MARK: - Writing

    private func milestone(_ text: String) {
        state.withLock { pending in
            if pending { write("\r\u{1B}[K") }
            write(text + "\n")
            pending = false
        }
    }

    private func transient(_ text: String) {
        state.withLock { pending in
            write("\r\u{1B}[K  \(text)")
            pending = true
        }
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Guards the one bit of mutable state: whether a transient line is on screen.
    private final class Lock: @unchecked Sendable {
        private let mutex = NSLock()
        private var lineIsPending = false

        func withLock(_ body: (inout Bool) -> Void) {
            mutex.lock()
            defer { mutex.unlock() }
            body(&lineIsPending)
        }
    }
}
