package org.nostrvpn.app.vpn

import android.net.VpnService
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidVpnServiceStartContractTest {
    @Test
    fun bootRestoreColdRelaunchEntersForegroundBeforeStateCanChange() {
        assertTrue(
            AndroidVpnServiceStartContract.requiresImmediateForeground(
                NostrVpnService.ACTION_RESTORE,
            ),
        )
    }

    @Test
    fun everyAppStartedTunnelActionUsesOneForegroundContract() {
        assertTrue(
            AndroidVpnServiceStartContract.requiresImmediateForeground(
                NostrVpnService.ACTION_CONNECT,
            ),
        )
        assertTrue(AndroidVpnServiceStartContract.requiresImmediateForeground(null))
        assertFalse(
            AndroidVpnServiceStartContract.requiresImmediateForeground(
                NostrVpnService.ACTION_DISCONNECT,
            ),
        )
        assertFalse(
            AndroidVpnServiceStartContract.requiresImmediateForeground(
                VpnService.SERVICE_INTERFACE,
            ),
        )
    }
}
