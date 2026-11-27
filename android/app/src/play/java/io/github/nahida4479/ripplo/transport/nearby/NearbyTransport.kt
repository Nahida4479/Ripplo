package io.github.nahida4479.ripplo.transport.nearby

import android.content.Context
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import com.google.android.gms.common.api.ApiException
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.transport.Link
import io.github.nahida4479.ripplo.transport.Transport
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

internal class NearbyTransport(ctx: Context, engine: MeshEngine) : Transport(ctx, engine) {
    companion object {
        private const val SERVICE_ID = "io.github.nahida4479.ripplo.nearby"
        private const val CHUNK = 16 * 1024
        private const val REFRESH_MS = 300000L
        private const val RETRY_MS = 60000L
        private const val FALLBACK_DIAL_MS = 15000L
        private const val MEDIUM = "wifi-direct"
    }

    private class Endpoint(val peer: String, val since: Long)

    private var client: ConnectionsClient? = null
    private val links = ConcurrentHashMap<String, NearbyLink>()
    private val requested = ConcurrentHashMap<String, Long>()
    private val endpoints = ConcurrentHashMap<String, Endpoint>()
    private val strategy = Strategy.P2P_CLUSTER
    @Volatile private var lastRefresh = System.currentTimeMillis()

    override fun name(): String = MEDIUM

    override fun startImpl() {
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) != ConnectionResult.SUCCESS) {
            throw UnsupportedOperationException("no play services")
        }
        val c = Nearby.getConnectionsClient(ctx)
        client = c
        lastRefresh = System.currentTimeMillis()
        startAdvertising(c)
        startDiscovery(c)
    }

    override fun stopImpl() {
        val c = client ?: return
        try { c.stopAdvertising() } catch (ignored: Exception) { }
        try { c.stopDiscovery() } catch (ignored: Exception) { }
        for (l in links.values.toList()) l.close()
        try { c.stopAllEndpoints() } catch (ignored: Exception) { }
        links.clear()
        requested.clear()
        endpoints.clear()
        client = null
    }

    override fun tickImpl() {
        val c = client ?: return
        val now = System.currentTimeMillis()
        requested.entries.removeIf { now - it.value > 30000 }
        if (now - lastRefresh > REFRESH_MS) refresh(c)
        for ((id, e) in endpoints) {
            if (now - e.since > FALLBACK_DIAL_MS && engine.nodeTag() > e.peer) dial(id, e.peer, false)
        }
    }

    private fun refresh(c: ConnectionsClient) {
        lastRefresh = System.currentTimeMillis()
        try { c.stopAdvertising() } catch (ignored: Exception) { }
        try { c.stopDiscovery() } catch (ignored: Exception) { }
        startAdvertising(c)
        startDiscovery(c)
    }

    private fun failed(what: String, e: Exception) {
        if (e is ApiException && e.statusCode == ConnectionsStatusCodes.STATUS_ALREADY_ADVERTISING) return
        if (e is ApiException && e.statusCode == ConnectionsStatusCodes.STATUS_ALREADY_DISCOVERING) return
        Diag.stage(MEDIUM, "", "failed", "$what: $e")
        lastRefresh = System.currentTimeMillis() - REFRESH_MS + RETRY_MS
    }

    private fun startAdvertising(c: ConnectionsClient) {
        c.startAdvertising(engine.nodeTag(), SERVICE_ID, lifecycle, AdvertisingOptions.Builder().setStrategy(strategy).build())
            .addOnSuccessListener { Diag.stage(MEDIUM, "", "started", "advertising") }
            .addOnFailureListener { failed("advertise", it) }
    }

    private fun startDiscovery(c: ConnectionsClient) {
        c.startDiscovery(SERVICE_ID, discovery, DiscoveryOptions.Builder().setStrategy(strategy).build())
            .addOnSuccessListener { Diag.stage(MEDIUM, "", "started", "discovery running") }
            .addOnFailureListener { failed("discovery", it) }
    }

    private fun dial(id: String, peer: String, force: Boolean): Boolean {
        val c = client ?: return false
        if (links.containsKey(id)) return false
        if (!force && engine.hasLink(peer, MEDIUM)) return false
        if (requested.putIfAbsent(id, System.currentTimeMillis()) != null) return false
        Diag.stage(MEDIUM, peer, "connecting", "requesting connection")
        c.requestConnection(engine.nodeTag(), id, lifecycle)
            .addOnFailureListener {
                requested.remove(id)
                val code = (it as? ApiException)?.statusCode
                Diag.stage(MEDIUM, peer, if (code == ConnectionsStatusCodes.STATUS_ALREADY_CONNECTED_TO_ENDPOINT) "connecting" else "failed", "request: $it")
            }
        return true
    }

    override fun forceConnect(node: String, option: String): Boolean {
        val c = client
        if (c == null || !running) {
            Diag.stage(MEDIUM, node, "rejected", "Nearby is not running (Play Services, Bluetooth, Wi-Fi or permissions missing)")
            return false
        }
        var found = endpoints.entries.firstOrNull { it.value.peer == node }
        if (found == null) {
            Diag.stage(MEDIUM, node, "scanning", "peer not discovered yet, restarting discovery (up to 12 s)")
            try { c.stopDiscovery() } catch (ignored: Exception) { }
            startDiscovery(c)
            val end = System.currentTimeMillis() + 15000
            while (found == null && System.currentTimeMillis() < end && running && engine.forcing()) {
                try { Thread.sleep(500) } catch (e: InterruptedException) { break }
                found = endpoints.entries.firstOrNull { it.value.peer == node }
            }
        }
        if (found == null) {
            Diag.stage(MEDIUM, node, "rejected", "peer not found over Nearby (other phone needs Ripplo running, Bluetooth and Wi-Fi on)")
            return false
        }
        engine.forceDialing()
        engine.closeLinks(node, MEDIUM)
        val inFlight = requested[found.key]
        if (inFlight != null && System.currentTimeMillis() - inFlight < 25000) {
            // a request is already being set up (Nearby takes several seconds); a second one would collide with it
            Diag.stage(MEDIUM, node, "connecting", "connection request already in progress, waiting for it")
            return true
        }
        requested.remove(found.key)
        return dial(found.key, node, true)
    }

    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(id: String, info: DiscoveredEndpointInfo) {
            val peer = info.endpointName
            if (peer == engine.nodeTag()) return
            endpoints[id] = Endpoint(peer, System.currentTimeMillis())
            engine.noteSeen(peer, MEDIUM)
            if (engine.nodeTag() < peer && !engine.forcing()) dial(id, peer, false)
        }

        override fun onEndpointLost(id: String) {
            endpoints.remove(id)
            requested.remove(id)
        }
    }

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(id: String, info: ConnectionInfo) {
            Diag.stage(MEDIUM, info.endpointName, "connecting", (if (info.isIncomingConnection) "incoming" else "outgoing") + " connection initiated, accepting")
            client?.acceptConnection(id, payloads)
        }

        override fun onConnectionResult(id: String, r: ConnectionResolution) {
            requested.remove(id)
            if (r.status.statusCode != ConnectionsStatusCodes.STATUS_OK) {
                Diag.stage(MEDIUM, endpoints[id]?.peer ?: "", "failed", "connection result ${r.status.statusCode}")
                return
            }
            Diag.stage(MEDIUM, endpoints[id]?.peer ?: "", "connected", "connection established")
            val l = NearbyLink(id)
            links.put(id, l)?.close()
            engine.addLink(l)
        }

        override fun onDisconnected(id: String) {
            Diag.stage(MEDIUM, endpoints[id]?.peer ?: "", "closed", "disconnected")
            links.remove(id)?.close()
        }
    }

    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(id: String, p: Payload) {
            val b = p.asBytes() ?: return
            val l = links[id] ?: return
            engine.rx.execute { l.onBytes(b, 0, b.size) }
        }

        override fun onPayloadTransferUpdate(id: String, u: PayloadTransferUpdate) {}
    }

    private inner class NearbyLink(val id: String) : Link(this@NearbyTransport.engine, MEDIUM, true) {
        override fun writeFrame(frame: ByteArray) {
            val c = client ?: throw IOException("nearby stopped")
            for (o in 0 until frame.size step CHUNK) {
                c.sendPayload(id, Payload.fromBytes(frame.copyOfRange(o, minOf(frame.size, o + CHUNK))))
            }
        }

        override fun closeImpl() {
            links.remove(id, this)
            try { client?.disconnectFromEndpoint(id) } catch (ignored: Exception) { }
        }
    }
}
