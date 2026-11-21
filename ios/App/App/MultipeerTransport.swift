import Foundation
import MultipeerConnectivity

final class MultipeerLink: MeshLink {
    let session: MCSession
    let peer: MCPeerID

    init(session: MCSession, peer: MCPeerID, initiated: Bool) {
        self.session = session
        self.peer = peer
        super.init(medium: "multipeer", initiated: initiated)
    }

    override func write(_ frame: Data) -> Bool {
        if closed { return false }
        return (try? session.send(frame, toPeers: [peer], with: .reliable)) != nil
    }

    override func close(block: Bool) {
        closed = true
    }
}

final class MultipeerTransport: NSObject, MeshTransport, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    private let q = DispatchQueue(label: "ripplo.multipeer")
    private var me: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var links = [String: MultipeerLink]()
    private var invited = [String: Date]()

    func start(nodeTag: String) {
        q.async {
            self.teardown()
            let peer = MCPeerID(displayName: nodeTag)
            let s = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .none)
            s.delegate = self
            let a = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "ripplo-mesh")
            a.delegate = self
            let b = MCNearbyServiceBrowser(peer: peer, serviceType: "ripplo-mesh")
            b.delegate = self
            self.me = peer
            self.session = s
            self.advertiser = a
            self.browser = b
            a.startAdvertisingPeer()
            b.startBrowsingForPeers()
        }
    }

    func stop() {
        q.async { self.teardown() }
    }

    func tick() {
        q.async {
            let cutoff = Date().addingTimeInterval(-20)
            self.invited = self.invited.filter { $0.value > cutoff }
        }
    }

    private func teardown() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        me = nil
        links.removeAll()
        invited.removeAll()
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        q.async {
            guard session === self.session, let me = self.me else { return }
            let name = peerID.displayName
            switch state {
            case .connected:
                if self.links[name] != nil { return }
                let link = MultipeerLink(session: session, peer: peerID, initiated: me.displayName < name)
                self.links[name] = link
                MeshEngine.shared.linkUp(link)
            case .notConnected:
                self.invited.removeValue(forKey: name)
                if let l = self.links.removeValue(forKey: name) { l.ended() }
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        q.async { self.links[peerID.displayName]?.received(data) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        q.async {
            if let s = self.session, self.links[peerID.displayName] == nil {
                invitationHandler(true, s)
            } else {
                invitationHandler(false, nil)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        q.async {
            guard let me = self.me, let s = self.session else { return }
            let name = peerID.displayName
            guard me.displayName < name, self.links[name] == nil, self.invited[name] == nil else { return }
            self.invited[name] = Date()
            browser.invitePeer(peerID, to: s, withContext: nil, timeout: 20)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        q.async { self.invited.removeValue(forKey: peerID.displayName) }
    }
}
