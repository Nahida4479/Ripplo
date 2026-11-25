import Foundation

enum Diag {
    private static let lock = NSLock()
    private static var lines = [String]()
    private static let cap = 600
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func add(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let t = stamp.string(from: Date())
        for l in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(t + " " + l)
        }
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }

    static func dump() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
