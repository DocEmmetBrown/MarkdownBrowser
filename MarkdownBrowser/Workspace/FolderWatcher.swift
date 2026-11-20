import CoreServices
import Foundation

/// Recursive folder watcher built on FSEvents; reports changed paths on the main queue.
nonisolated final class FolderWatcher {
    private var stream: FSEventStreamRef?
    fileprivate let onChange: @MainActor ([String]) -> Void

    init(url: URL, onChange: @escaping @MainActor ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, folderWatcherCallback, &context, [url.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

private nonisolated func folderWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    let onChange = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange
    // The stream is scheduled on the main queue.
    MainActor.assumeIsolated {
        onChange(changed)
    }
}
