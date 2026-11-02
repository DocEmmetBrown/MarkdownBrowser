import Foundation

/// Watches a single file and survives atomic saves (which replace the inode) by re-opening it.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var isStopped = false
    private var isMissing = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    func stop() {
        isStopped = true
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func arm() {
        source?.cancel()
        source = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            isMissing = true
            schedule(rearm: true, delay: .seconds(1), notify: false)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                let replaced = !source.data.isDisjoint(with: [.delete, .rename, .revoke])
                self.schedule(rearm: replaced, delay: .milliseconds(120), notify: true)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        if isMissing {
            isMissing = false
            onChange()
        }
    }

    private func schedule(rearm: Bool, delay: Duration, notify: Bool) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            if rearm { self.arm() }
            if notify { self.onChange() }
        }
    }
}
