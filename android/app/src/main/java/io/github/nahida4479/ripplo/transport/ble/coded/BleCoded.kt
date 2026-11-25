package io.github.nahida4479.ripplo.transport.ble.coded

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.Build
import io.github.nahida4479.ripplo.platform.Diag

internal object BleCoded {
    fun mask(coded: Boolean): Int =
        if (Build.VERSION.SDK_INT >= 26) (if (coded) BluetoothDevice.PHY_LE_CODED_MASK else BluetoothDevice.PHY_LE_1M_MASK) else 0

    fun isCoded(phy: Int): Boolean = Build.VERSION.SDK_INT >= 26 && phy == BluetoothDevice.PHY_LE_CODED

    fun phyNote(rxPhy: Int): String =
        "phy " + when (rxPhy) {
            BluetoothDevice.PHY_LE_CODED -> "coded"
            BluetoothDevice.PHY_LE_2M -> "2M"
            else -> "1M"
        }

    fun supported(adapter: BluetoothAdapter?): Boolean =
        Build.VERSION.SDK_INT >= 26 && adapter != null && adapter.isLeCodedPhySupported && adapter.isLeExtendedAdvertisingSupported
}

internal class CodedAdvertiser {
    private var cb: AdvertisingSetCallback? = null

    fun start(adv: BluetoothLeAdvertiser, d: AdvertiseData) {
        try {
            val p = AdvertisingSetParameters.Builder()
                .setLegacyMode(false)
                .setConnectable(true)
                .setScannable(false)
                .setPrimaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
                .build()
            val c = object : AdvertisingSetCallback() {
                override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                    Diag.i("ble coded advertising status=$status")
                    if (status == AdvertisingSetCallback.ADVERTISE_SUCCESS) Diag.stage("ble", "", "started", "advertising coded")
                    else Diag.stage("ble", "", "failed", "coded advertise status=$status")
                }
            }
            cb = c
            adv.startAdvertisingSet(p, d, null, null, null, c)
        } catch (e: Exception) {
            Diag.w("ble coded advertise failed $e")
            Diag.stage("ble", "", "failed", "coded advertise: " + e.javaClass.simpleName)
        }
    }

    fun stop(adv: BluetoothLeAdvertiser?) {
        try {
            val c = cb
            if (adv != null && c != null) adv.stopAdvertisingSet(c)
        } catch (ignored: Exception) { }
        cb = null
    }
}
