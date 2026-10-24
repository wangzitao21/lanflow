package dev.lanflow.app

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.RouteInfo
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.NetworkInterface

/** Event-driven topology updates, including LANs without Internet access. */
internal class NetworkStateMonitor(
    context: Context,
    private val onChanged: (Map<String, Any?>, Boolean) -> Unit,
) {
    private val applicationContext = context.applicationContext
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var registered = false
    private var interfaceChangesRegistered = false
    private var closed = false
    private var lastState: Map<String, Any?>? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = report()
        override fun onLost(network: Network) = report()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = report()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = report()
    }

    private val interfaceChanges = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = report()
    }

    @Suppress("DEPRECATION")
    fun start() {
        if (registered || interfaceChangesRegistered || closed) return
        try {
            // Builder defaults exclude VPNs; clearing them also retains unvalidated LANs.
            manager.registerNetworkCallback(NetworkRequest.Builder().clearCapabilities().build(), callback)
            registered = true
        } catch (_: Exception) {
            // A snapshot remains available if the device refuses callbacks.
        }
        try {
            val filter = IntentFilter().apply {
                addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
                addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
                // These system broadcasts cover hotspot/USB interfaces, which
                // are not always ConnectivityManager networks. Ignore extras:
                // only the OS snapshot below determines connectivity.
                addAction("android.net.wifi.WIFI_AP_STATE_CHANGED")
                addAction("android.net.conn.TETHER_STATE_CHANGED")
            }
            if (Build.VERSION.SDK_INT >= 33) {
                applicationContext.registerReceiver(interfaceChanges, filter, Context.RECEIVER_EXPORTED)
            } else {
                applicationContext.registerReceiver(interfaceChanges, filter)
            }
            interfaceChangesRegistered = true
        } catch (_: Exception) {
            // Keep routing hints conservative when interface changes are unknown.
        }
        publish()
    }

    @Suppress("DEPRECATION")
    fun snapshot(): Map<String, Any?> {
        val routes = sortedMapOf<String, Map<String, Any>>()
        val topology = sortedSetOf<String>()
        val knownInterfaces = mutableSetOf<String>()
        // Without callbacks a negative hint could remain stale after reconnection.
        var complete = registered && interfaceChangesRegistered
        var available = false
        var hasLocalNetwork = false

        fun addRoute(address: String?, prefixLength: Int) {
            if (address == null) return
            routes["$address/$prefixLength"] = mapOf("destination" to address, "prefixLength" to prefixLength)
        }

        try {
            // Observe all paths rather than just the default Internet connection.
            // Wi-Fi, Ethernet and VPN may coexist with a cellular default route.
            val networks = manager.allNetworks
            available = networks.isNotEmpty()
            topology.add("default:${manager.activeNetwork}")
            for (network in networks) {
                val capabilities = manager.getNetworkCapabilities(network)
                val properties = manager.getLinkProperties(network)
                if (capabilities == null || properties == null) complete = false
                val cellularOnly = capabilities != null &&
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                if (!cellularOnly) hasLocalNetwork = true
                properties?.interfaceName?.let { knownInterfaces.add(it) }
                topology.add("network:$network:${properties?.interfaceName}:cellularOnly=$cellularOnly")
                properties?.routes?.filter {
                    Build.VERSION.SDK_INT < 33 || it.type == RouteInfo.RTN_UNICAST
                }?.forEach { route ->
                    val destination = route.destination
                    addRoute(destination.address.hostAddress, destination.prefixLength)
                    route.`interface`?.let { knownInterfaces.add(it) }
                    topology.add("route:$network:${destination}:${route.gateway?.hostAddress}:${route.`interface`}")
                }
                properties?.linkAddresses?.forEach { address ->
                    topology.add("address:$network:$address")
                }
            }
        } catch (_: Exception) {
            complete = false
        }

        try {
            // Hotspot / Wi-Fi Direct / USB interfaces are not always represented
            // by ConnectivityManager. Never mistake them for cellular-only use.
            val interfaces = NetworkInterface.getNetworkInterfaces()
            if (interfaces == null) complete = false
            else for (networkInterface in interfaces) {
                if (!networkInterface.isUp || networkInterface.isLoopback) continue
                val addresses = networkInterface.interfaceAddresses.filter {
                    !it.address.isLoopbackAddress && !it.address.isAnyLocalAddress
                }
                if (addresses.isEmpty()) continue
                available = true
                if (networkInterface.name !in knownInterfaces) hasLocalNetwork = true
                addresses.forEach { address ->
                    val prefix = address.networkPrefixLength.toInt()
                    if (prefix >= 0) addRoute(address.address.hostAddress, prefix)
                    else complete = false
                    topology.add("interface:${networkInterface.name}:${address.address.hostAddress}/$prefix")
                }
            }
        } catch (_: Exception) {
            complete = false
        }

        // Unknown topology must allow attempts; this is an optimization hint,
        // never evidence that a message may be discarded or an address is bad.
        val localNetworkAvailable: Boolean? = when {
            hasLocalNetwork -> true
            complete -> false
            else -> null
        }
        if (!complete && !available) available = true
        return mapOf(
            "available" to available,
            "localNetworkAvailable" to localNetworkAvailable,
            "routes" to routes.values.toList(),
            "fingerprint" to "$available:$localNetworkAvailable:${topology.joinToString("|")}",
        )
    }

    private fun report() {
        // Read after the callback, outside ConnectivityManager's callback thread.
        // There is no debounce delay: newly usable paths are reported immediately.
        handler.post { if (!closed) publish() }
    }

    private fun publish() {
        val state = snapshot()
        if (state == lastState) return
        val availabilityChanged = state["available"] != lastState?.get("available")
        lastState = state
        onChanged(state, availabilityChanged)
    }

    fun close() {
        closed = true
        handler.removeCallbacksAndMessages(null)
        if (registered) {
            try { manager.unregisterNetworkCallback(callback) } catch (_: Exception) {}
            registered = false
        }
        if (interfaceChangesRegistered) {
            try { applicationContext.unregisterReceiver(interfaceChanges) } catch (_: Exception) {}
            interfaceChangesRegistered = false
        }
    }
}
