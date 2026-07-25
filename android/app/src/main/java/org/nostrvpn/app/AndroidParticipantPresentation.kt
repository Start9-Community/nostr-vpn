package org.nostrvpn.app

import androidx.compose.ui.graphics.Color
import org.nostrvpn.app.core.AppState
import org.nostrvpn.app.core.ParticipantState

internal fun ParticipantState.isSelf(state: AppState): Boolean =
    (state.ownNpub.isNotBlank() && npub == state.ownNpub) || meshState == "local"

internal fun ParticipantState.displayName(state: AppState): String {
    if (magicDnsName.isNotBlank()) return magicDnsName
    if (isSelf(state) && state.selfMagicDnsName.isNotBlank()) return state.selfMagicDnsName
    if (alias.isNotBlank()) return alias
    if (magicDnsAlias.isNotBlank()) return magicDnsAlias
    return npub.shortNpub()
}

internal fun ParticipantState.subtitle(isSelf: Boolean): String {
    val ip = tunnelIp.substringBefore("/")
    return if (isSelf) {
        if (ip.isBlank()) "This device" else "This device - $ip"
    } else {
        ip
    }
}

internal fun ParticipantState.statusLabel(appState: AppState): String {
    if (isSelf(appState)) return if (appState.vpnEnabled) "This device" else "Off"
    if (state == "pending") {
        return when (statusText.trim().lowercase()) {
            "join request sent" -> JOIN_REQUEST_SENT_TEXT
            "waiting for admin" -> "Waiting for admin"
            else -> "Connecting"
        }
    }
    return when (state) {
        "local", "online", "present" -> "Online"
        "offline", "absent", "off" -> "Offline"
        else -> if (reachable) "Online" else "Unknown"
    }
}

internal fun ParticipantState.detailStatusLabel(appState: AppState): String {
    if (isSelf(appState)) return statusLabel(appState)
    return if (statusText.isNotBlank()) statusText else statusLabel(appState)
}

internal fun ParticipantState.fipsPathLabel(appState: AppState): String {
    if (isSelf(appState)) return "This device"
    if (reachable && fipsTransportAddr.isNotBlank()) {
        val transport = if (fipsTransportType.isBlank()) "" else " (${fipsTransportType.uppercase()})"
        return if (fipsSrttMs > 0) {
            "Direct connection$transport, $fipsSrttMs ms"
        } else {
            "Direct connection$transport"
        }
    }
    if (reachable) {
        return if (fipsSrttMs > 0) "Via mesh, $fipsSrttMs ms" else "Via mesh"
    }
    if (state == "pending") return "Connecting"
    return "Offline"
}

internal fun ParticipantState.isFipsRouted(state: AppState): Boolean =
    !isSelf(state) && reachable && fipsTransportAddr.isBlank()

internal fun ParticipantState.isActiveExitNode(state: AppState): Boolean =
    state.exitNodeActive && state.exitNode.isNotBlank() && npub == state.exitNode

internal fun ParticipantState.exitNodeLabel(state: AppState): String =
    if (isActiveExitNode(state)) "Exit active" else "Exit offered"

internal fun ParticipantState.exitNodeBackground(state: AppState): Color =
    if (isActiveExitNode(state)) Color(0xFFECFDF5) else Color(0xFFFFF7ED)

internal fun ParticipantState.exitNodeTint(state: AppState): Color =
    if (isActiveExitNode(state)) Ok else Color(0xFFA16207)

internal fun String.shortNpub(): String {
    if (isBlank()) return "Device"
    if (length <= 19) return this
    return "${take(12)}...${takeLast(6)}"
}
