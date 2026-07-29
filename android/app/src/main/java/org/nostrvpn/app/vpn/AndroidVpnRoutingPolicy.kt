package org.nostrvpn.app.vpn

internal object AndroidVpnRoutingPolicy {
    fun excludesOwnProcess(wireGuardExitActive: Boolean): Boolean =
        !wireGuardExitActive

    fun requiresBypass(routeTargets: List<String>): Boolean =
        routeTargets.none { route ->
            route.trim() == "0.0.0.0/0" || route.trim() == "::/0"
        }

    fun excludedDeviceInternetRoutes(routeTargets: List<String>): List<String> =
        if (requiresBypass(routeTargets)) {
            listOf("0.0.0.0/0", "::/0")
        } else {
            emptyList()
        }

    fun supportsAlwaysOn(routeTargets: List<String>): Boolean =
        !requiresBypass(routeTargets)

    fun installsVpnDns(routeTargets: List<String>): Boolean =
        !requiresBypass(routeTargets)
}
