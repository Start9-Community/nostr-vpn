package org.nostrvpn.app.vpn

internal object AndroidVpnRoutingPolicy {
    data class UnderlayNetworkCandidate(
        val handle: Long,
        val active: Boolean,
        val validated: Boolean,
        val usable: Boolean,
        val transportPreference: Int,
    )

    fun isPhysicalNetworkChange(
        previousFingerprint: String?,
        currentFingerprint: String,
    ): Boolean =
        previousFingerprint != null && previousFingerprint != currentFingerprint

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

    fun preferredWireGuardUnderlay(candidates: List<UnderlayNetworkCandidate>): Long? {
        val usable = candidates.filter(UnderlayNetworkCandidate::usable)
        val validated = usable.filter(UnderlayNetworkCandidate::validated)
        val eligible = validated.ifEmpty {
            usable
        }
        return eligible.minWithOrNull(
            compareBy<UnderlayNetworkCandidate>(
                { if (it.active) 0 else 1 },
                UnderlayNetworkCandidate::transportPreference,
                UnderlayNetworkCandidate::handle,
            ),
        )?.handle
    }

    fun nextUnderlayRefreshDelay(
        pendingDelay: Long?,
        immediate: Boolean,
        delayedRefresh: Long,
    ): Long? = (if (immediate) 0L else delayedRefresh)
        .takeIf { pendingDelay == null || it < pendingDelay }
}
