import UIKit
import Capacitor

class RipploBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(RipploMeshPlugin())
    }
}
