import Foundation

protocol MeshTransport: AnyObject {
    func start(nodeTag: String)
    func stop()
    func tick()
}

class MeshLink {
    let medium: String
    let initiated: Bool
    var closed = false
    private let lock = NSLock()
    private var queued = 0

    init(medium: String, initiated: Bool) {
        self.medium = medium
        self.initiated = initiated
    }

    var queuedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return queued
    }

    func addQueued(_ n: Int) {
        lock.lock()
        queued += n
        lock.unlock()
    }

    func write(_ frame: Data) -> Bool { false }

    func close(block: Bool) {
        closed = true
    }

    final func received(_ data: Data) {
        MeshEngine.shared.q.async { MeshEngine.shared.linkData(self, data) }
    }

    final func ended() {
        closed = true
        MeshEngine.shared.q.async { MeshEngine.shared.linkDown(self) }
    }
}

private final class Box: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
}

final class IOThread: NSObject {
    static let shared = IOThread()
    private var thread: Thread!

    private override init() {
        super.init()
        let t = Thread {
            RunLoop.current.add(Port(), forMode: .default)
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }
        }
        t.name = "ripplo-io"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    @objc private func run(_ box: Box) {
        box.f()
    }

    func async(_ block: @escaping () -> Void) {
        perform(#selector(run(_:)), on: thread, with: Box(block), waitUntilDone: false)
    }
}
