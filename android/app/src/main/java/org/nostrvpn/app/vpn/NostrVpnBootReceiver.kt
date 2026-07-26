package org.nostrvpn.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import org.nostrvpn.app.AndroidLegacyPackageMigration

class NostrVpnBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        if (!VpnStartState.userWantsVpn(context)) {
            return
        }
        if (AndroidLegacyPackageMigration.packagesToRemove(context).isNotEmpty()) {
            Log.w(
                "NostrVpnBootReceiver",
                "Not restoring VPN while another known nVPN package is installed",
            )
            return
        }
        runCatching {
            NostrVpnService.startRestore(context)
        }.onFailure { error ->
            Log.w("NostrVpnBootReceiver", "Failed to restore VPN service", error)
        }
    }
}
