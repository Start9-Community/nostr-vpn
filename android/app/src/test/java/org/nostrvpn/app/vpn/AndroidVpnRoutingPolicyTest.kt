package org.nostrvpn.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidVpnRoutingPolicyTest {
    @Test
    fun wireGuardExitIncludesOwnProcessSoAppTrafficEntersTunnel() {
        assertFalse(AndroidVpnRoutingPolicy.excludesOwnProcess(wireGuardExitActive = true))
    }

    @Test
    fun fipsExitExcludesOwnProcessEvenThoughItHasDefaultRoute() {
        assertFalse(AndroidVpnRoutingPolicy.requiresBypass(listOf("0.0.0.0/0")))
        assertTrue(AndroidVpnRoutingPolicy.excludesOwnProcess(wireGuardExitActive = false))
    }

    @Test
    fun directAndSplitModesExcludeOwnProcess() {
        assertTrue(AndroidVpnRoutingPolicy.excludesOwnProcess(wireGuardExitActive = false))
    }

    @Test
    fun splitTunnelPermitsUnmatchedTrafficToUseDeviceInternet() {
        val routes = listOf("10.44.0.0/16", "10.72.0.9/32")
        assertTrue(AndroidVpnRoutingPolicy.requiresBypass(routes))
        assertEquals(
            listOf("0.0.0.0/0", "::/0"),
            AndroidVpnRoutingPolicy.excludedDeviceInternetRoutes(routes),
        )
        assertTrue(AndroidVpnRoutingPolicy.requiresBypass(emptyList()))
        assertFalse(AndroidVpnRoutingPolicy.supportsAlwaysOn(routes))
        assertFalse(AndroidVpnRoutingPolicy.installsVpnDns(routes))
    }

    @Test
    fun fullTunnelExitRemainsNonBypassable() {
        assertFalse(AndroidVpnRoutingPolicy.requiresBypass(listOf("0.0.0.0/0")))
        assertFalse(AndroidVpnRoutingPolicy.requiresBypass(listOf("::/0")))
        assertTrue(
            AndroidVpnRoutingPolicy
                .excludedDeviceInternetRoutes(listOf("0.0.0.0/0"))
                .isEmpty(),
        )
        assertTrue(AndroidVpnRoutingPolicy.supportsAlwaysOn(listOf("0.0.0.0/0")))
        assertTrue(AndroidVpnRoutingPolicy.installsVpnDns(listOf("0.0.0.0/0")))
    }
}
