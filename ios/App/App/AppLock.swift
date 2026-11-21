import UIKit
import LocalAuthentication

enum AppLock {
    static var secure = false

    static func available() -> (biometric: Bool, credential: Bool) {
        let bio = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let cred = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return (bio, cred)
    }

    static func authenticate(reason: String, _ done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            done(err?.code == LAError.passcodeNotSet.rawValue)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}

final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    private static var live: PickerDelegate?
    private let done: (URL?) -> Void

    private init(_ done: @escaping (URL?) -> Void) {
        self.done = done
    }

    static func present(_ make: @escaping () -> UIDocumentPickerViewController, from vc: UIViewController?, _ done: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            guard let vc = vc else {
                done(nil)
                return
            }
            let d = PickerDelegate(done)
            live = d
            let picker = make()
            picker.delegate = d
            vc.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    private func finish(_ u: URL?) {
        PickerDelegate.live = nil
        done(u)
    }
}
