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
import io.github.nahida4479.ripplo.mesh.MeshEngine
import io.github.nahida4479.ripplo.platform.Diag
import io.github.nahida4479.ripplo.transport.Link
import io.github.nahida4479.ripplo.transport.Transport
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

// Google Nearby Connections (Play Services) as an extra transport. Play build only; loaded by reflection.
internal class NearbyTransport(ctx: Context, engine: MeshEngine) : Transport(ctx, engine) {
    companion object {
        private const val SERVICE_ID = "io.github.nahida4479.ripplo.nearby"
        private const val CHUNK = 16 * 1024
    }

    private var client: ConnectionsClient? = null
    private val links = ConcurrentHashMap<String, NearbyLink>()
    private val requested = ConcurrentHashMap<String, Long>()
    private val strategy = Strategy.P2P_CLUSTER

    override fun name(): String = "nearby"

    override fun startImpl() {
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) != ConnectionResult.SUCCESS) {
            throw UnsupportedOperationException("no play services")
        }
        val c = Nearby.getConnectionsClient(ctx)
        client = c
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
        client = null
    }

    override fun tickImpl() {
        val c = client ?: return
        val now = System.currentTimeMillis()
        requested.entries.removeIf { now - it.value > 30000 }
        // Discovery/advertising are stopped by Play Services after a while; refresh every 5 minutes.
        if (now - lastRefresh > 300000) {
            lastRefresh = now
            try { c.stopAdvertising() } catch (ignored: Exception) { }
            try { c.stopDiscovery() } catch (ignored: Exception) { }
            startAdvertising(c)
            startDiscovery(c)
        }
    }

    @Volatile private var lastRefresh = System.currentTimeMillis()

    private fun startAdvertising(c: ConnectionsClient) {
        c.startAdvertising(engine.nodeTag(), SERVICE_ID, lifecycle, AdvertisingOptions.Builder().setStrategy(strategy).build())
            .addOnFailureListener { Diag.w("nearby advertise failed $it") }
    }

    private fun startDiscovery(c: ConnectionsClient) {
        c.startDiscovery(SERVICE_ID, discovery, DiscoveryOptions.Builder().setStrategy(strategy).build())
            .addOnFailureListener { Diag.w("nearby discovery failed $it") }
    }

    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(id: String, info: DiscoveredEndpointInfo) {
            val peer = info.endpointName
            if (peer == engine.nodeTag() || links.containsKey(id) || engine.hasLink(peer, "nearby")) return
            // Only the lower node tag dials, so the two phones never collide.
            if (engine.nodeTag() > peer) return
            if (requested.putIfAbsent(id, System.currentTimeMillis()) != null) return
            engine.noteSeen(peer, "nearby")
            client?.requestConnection(engine.nodeTag(), id, lifecycle)
                ?.addOnFailureListener { requested.remove(id); Diag.i("nearby request failed $it") }
        }

        override fun onEndpointLost(id: String) {
            requested.remove(id)
        }
    }

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(id: String, info: ConnectionInfo) {
            client?.acceptConnection(id, payloads)
        }

        override fun onConnectionResult(id: String, r: ConnectionResolution) {
            requested.remove(id)
            if (r.status.statusCode != ConnectionsStatusCodes.STATUS_OK) {
                Diag.i("nearby connect failed ${r.status.statusCode}")
                return
            }
            val l = NearbyLink(id)
            links.put(id, l)?.close()
            engine.addLink(l)
        }

        override fun onDisconnected(id: String) {
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

    private inner class NearbyLink(val id: String) : Link(this@NearbyTransport.engine, "nearby", true) {
        init {
            kbps = 20000
        }

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
