package org.nostrvpn.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import org.json.JSONObject
import org.nostrvpn.app.core.AppCoreClient
import org.nostrvpn.app.core.AppState
import org.nostrvpn.app.core.NativeActions
import org.nostrvpn.app.core.NativeCore
import org.nostrvpn.app.core.activeNetwork
import org.nostrvpn.app.update.AndroidSelfUpdateManager
import org.nostrvpn.app.update.AndroidSelfUpdateState
import org.nostrvpn.app.vpn.NostrVpnService
import org.nostrvpn.app.vpn.AndroidVpnRoutingPolicy
import org.nostrvpn.app.vpn.VpnStartState

class MainActivity : ComponentActivity() {
    private var deepLink by mutableStateOf<String?>(null)
    private var debugRequest by mutableStateOf(AndroidDebugRequest())
    private var legacyPackageToRemove by mutableStateOf<String?>(null)
    private lateinit var selfUpdateManager: AndroidSelfUpdateManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        legacyPackageToRemove = AndroidLegacyPackageMigration.packageToRemove(this)
        deepLink = intent?.dataString
        debugRequest = AndroidDebugRequest.from(intent)
        NativeCore.initializeAndroidContext(applicationContext)
        val dataDir = appCoreDataDir(this)
        seedMobileConfig(dataDir)
        writeAndroidBuildMetadata(dataDir)
        // Pass empty so the FFI falls back to its own CARGO_PKG_VERSION
        // (workspace-inherited). Avoids drift between BuildConfig.VERSION_NAME
        // and the bundled nvpn binary's version.
        val core = AppCoreClient(dataDir.absolutePath, "")
        selfUpdateManager =
            AndroidSelfUpdateManager(
                context = this,
                scope = lifecycleScope,
                ioDispatcher = Dispatchers.IO,
            )
        selfUpdateManager.startAutomaticChecks()

        setContent {
            val lifecycleOwner = LocalLifecycleOwner.current
            var state by remember { mutableStateOf(core.state()) }
            var androidError by remember { mutableStateOf("") }
            var vpnLockdownActive by remember { mutableStateOf(VpnStartState.refreshLockdownActive(this)) }
            var pendingVpnStart by remember { mutableStateOf(false) }
            var pendingLocalNetworkAction by remember { mutableStateOf<JSONObject?>(null) }
            var showQrScanner by remember { mutableStateOf(false) }
            var qrScanNetworkId by remember { mutableStateOf("") }
            var pendingScannedJoinRequest by remember { mutableStateOf<String?>(null) }
            var observedTunnelConfigJson by remember {
                mutableStateOf(core.mobileTunnelConfigJson())
            }
            fun showAndroidError(message: String, fallback: String = "Android action failed") {
                androidError = message.trim().ifBlank { fallback }
            }
            fun showAndroidError(error: Throwable, fallback: String) {
                showAndroidError(error.message.orEmpty(), fallback)
            }
            fun applyUserActionState(nextState: AppState) {
                state = nextState
                androidError = ""
            }
            fun startVpnTunnel() {
                val tunnelConfigJson = core.mobileTunnelConfigJson()
                observedTunnelConfigJson = tunnelConfigJson
                startVpnService(
                    Intent(this, NostrVpnService::class.java)
                        .setAction(NostrVpnService.ACTION_CONNECT)
                        .putExtra(
                            NostrVpnService.EXTRA_CONFIG_JSON,
                            tunnelConfigJson,
                        ),
                )
            }
            val vpnPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) { result ->
                if (result.resultCode == RESULT_OK && state.vpnEnabled) {
                    startVpnTunnel()
                } else if (pendingVpnStart && state.vpnEnabled) {
                    try {
                        applyUserActionState(core.dispatch(NativeActions.disconnectVpn()))
                    } catch (error: Exception) {
                        showAndroidError(error, "Android action failed")
                    }
                }
                pendingVpnStart = false
            }
            val legacyPackageRemovalLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) {
                legacyPackageToRemove = AndroidLegacyPackageMigration.packageToRemove(this)
            }
            fun requestVpnTunnel() {
                val tunnelConfigJson = core.mobileTunnelConfigJson()
                observedTunnelConfigJson = tunnelConfigJson
                val tunnelConfig = JSONObject(tunnelConfigJson)
                val routeTargets = buildList {
                    val routes = tunnelConfig.optJSONArray("routeTargets") ?: return@buildList
                    for (index in 0 until routes.length()) {
                        routes.optString(index).trim().takeIf(String::isNotEmpty)?.let(::add)
                    }
                }
                if (
                    VpnStartState.alwaysOnActiveForThisApp(this) &&
                    !AndroidVpnRoutingPolicy.supportsAlwaysOn(routeTargets)
                ) {
                    applyUserActionState(core.dispatch(NativeActions.disconnectVpn()))
                    showAndroidError(
                        "Always-on VPN cannot be used with split tunneling. " +
                            "Turn it off in Android VPN settings or select an Internet exit.",
                    )
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                    return
                }
                val intent = VpnService.prepare(this)
                if (intent == null) {
                    startVpnTunnel()
                } else {
                    pendingVpnStart = true
                    vpnPermissionLauncher.launch(intent)
                }
            }
            fun actionRequiresTunnelRefresh(action: JSONObject): Boolean {
                val type = action.optString("type")
                val patchKeys = buildSet {
                    val keys = action.optJSONObject("patch")?.keys() ?: return@buildSet
                    while (keys.hasNext()) {
                        add(keys.next())
                    }
                }
                return TunnelRefreshPolicy.requiresTunnelRefresh(type, patchKeys)
            }

            fun dispatchNow(action: JSONObject) {
                val actionType = action.optString("type")
                val wasEnabled = state.vpnEnabled
                var actionSucceeded = false
                try {
                    val nextState = core.dispatch(action)
                    actionSucceeded = nextState.error.isBlank()
                    applyUserActionState(nextState)
                } catch (error: Exception) {
                    showAndroidError(error, "Android action failed")
                }
                if (!actionSucceeded) {
                    return
                }
                when (
                    TunnelServiceCommandPolicy.commandAfterAction(
                        actionType = actionType,
                        wasEnabled = wasEnabled,
                        isEnabled = state.vpnEnabled,
                        requiresRefresh = actionRequiresTunnelRefresh(action),
                    )
                ) {
                    TunnelServiceCommand.CONNECT -> requestVpnTunnel()
                    TunnelServiceCommand.DISCONNECT -> {
                        startVpnService(
                            Intent(this, NostrVpnService::class.java)
                                .setAction(NostrVpnService.ACTION_DISCONNECT),
                        )
                    }
                    TunnelServiceCommand.NONE -> Unit
                }
            }
            fun requiredLocalNetworkPermission(): String? =
                when {
                    Build.VERSION.SDK_INT >= ANDROID_ACCESS_LOCAL_NETWORK_API -> ACCESS_LOCAL_NETWORK_PERMISSION
                    Build.VERSION.SDK_INT >= ANDROID_LOCAL_NETWORK_OPT_IN_API -> Manifest.permission.NEARBY_WIFI_DEVICES
                    else -> null
                }

            fun requiresLocalNetworkPermission(action: JSONObject): Boolean =
                when (action.optString("type")) {
                    "connect_vpn", "start_join_request_broadcast", "start_nearby_discovery" -> true
                    else -> false
                }

            fun localNetworkPermissionMessage() =
                "Local network permission is needed for nearby device discovery."

            val localNetworkPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                val action = pendingLocalNetworkAction
                pendingLocalNetworkAction = null
                if (granted && action != null) {
                    dispatchNow(action)
                } else {
                    showAndroidError(localNetworkPermissionMessage())
                }
            }
            val dispatch: (JSONObject) -> Unit = { action ->
                val permission = requiredLocalNetworkPermission()
                if (
                    permission != null &&
                    requiresLocalNetworkPermission(action) &&
                    checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED
                ) {
                    pendingLocalNetworkAction = action
                    runCatching { localNetworkPermissionLauncher.launch(permission) }
                        .onFailure {
                            pendingLocalNetworkAction = null
                            showAndroidError(localNetworkPermissionMessage())
                        }
                } else {
                    dispatchNow(action)
                }
            }
            val wireGuardConfigFileLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.OpenDocument(),
            ) { uri ->
                if (uri == null) {
                    return@rememberLauncherForActivityResult
                }
                runCatching {
                    contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                        ?: error("Could not open selected file")
                }.onSuccess { config ->
                    if (config.isBlank()) {
                        showAndroidError("Selected WireGuard config is empty.")
                    } else {
                        dispatch(NativeActions.updateSettings("wireguardExitConfig" to config))
                    }
                }.onFailure { error ->
                    showAndroidError(error, "Could not read WireGuard config")
                }
            }
            fun importWireGuardConfigFile() {
                androidError = ""
                runCatching {
                    wireGuardConfigFileLauncher.launch(
                        arrayOf(
                            "application/x-wireguard-profile",
                            "application/octet-stream",
                            "text/*",
                            "*/*",
                        ),
                    )
                }.onFailure { error ->
                    showAndroidError(error, "Could not open file picker")
                }
            }
            fun requestDeviceQrScan(networkId: String) {
                androidError = ""
                qrScanNetworkId = networkId
                showQrScanner = true
            }

            DisposableEffect(core) {
                onDispose { core.close() }
            }
            LaunchedEffect(core, lifecycleOwner) {
                lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
                    while (true) {
                        vpnLockdownActive = VpnStartState.refreshLockdownActive(this@MainActivity)
                        try {
                            val nextState = core.refresh()
                            if (nextState.error.isNotBlank()) {
                                androidError = ""
                            }
                            val currentTunnelConfigJson = core.mobileTunnelConfigJson()
                            val requiresTunnelRefresh =
                                TunnelConfigRefreshPolicy.requiresAsyncRefresh(
                                    vpnEnabled = nextState.vpnEnabled,
                                    observedConfigJson = observedTunnelConfigJson,
                                    currentConfigJson = currentTunnelConfigJson,
                                )
                            state = nextState
                            observedTunnelConfigJson = currentTunnelConfigJson
                            if (requiresTunnelRefresh) {
                                requestVpnTunnel()
                            }
                        } catch (error: Exception) {
                            showAndroidError(error, "Android refresh failed")
                        }
                        delay(2_000)
                    }
                }
            }
            LaunchedEffect(deepLink, debugRequest) {
                val request = deepLink
                if (!request.isNullOrBlank() && looksLikeJoinRequestQrOrLink(request)) {
                    dispatch(NativeActions.importJoinRequest(request))
                    deepLink = null
                }
                val automation = debugRequest
                if (automation.action != null) {
                    AndroidDebugAutomation.run(
                        request = automation,
                        state = state,
                        core = core,
                        dataDir = dataDir,
                        dispatch = dispatch,
                    )
                    debugRequest = AndroidDebugRequest()
                }
            }

            val selfUpdateState by selfUpdateManager.state.collectAsState()
            val updateActions = remember {
                SelfUpdateActions(
                    check = { selfUpdateManager.check(manual = true) },
                    download = { selfUpdateManager.download() },
                    install = { selfUpdateManager.install(this@MainActivity) },
                    setAutoCheck = { enabled -> selfUpdateManager.setAutoCheckEnabled(enabled) },
                )
            }

            NostrVpnTheme {
                val displayState = state.withAndroidNotice(androidError, vpnLockdownActive)
                NostrVpnApp(
                    state = displayState,
                    qrJson = { text -> core.qrMatrix(text) },
                    scanDeviceQr = { networkId -> requestDeviceQrScan(networkId) },
                    dispatch = dispatch,
                    selfUpdateState = selfUpdateState,
                    selfUpdateActions = updateActions,
                    importWireGuardConfigFile = { importWireGuardConfigFile() },
                )
                if (showQrScanner) {
                    QrScannerDialog(
                        onDismiss = { showQrScanner = false },
                        onScanned = { value ->
                            if (looksLikeJoinRequestQrOrLink(value)) {
                                showQrScanner = false
                                pendingScannedJoinRequest = value.trim()
                                null
                            } else {
                                val scanned = parseScannedDeviceLinkQr(value)
                                if (scanned == null) {
                                    "Not a Nostr VPN joiner QR."
                                } else {
                                    showQrScanner = false
                                    dispatch(
                                        NativeActions.addParticipant(
                                            qrScanNetworkId,
                                            scanned.deviceId,
                                            scanned.alias,
                                        ),
                                    )
                                    null
                                }
                            }
                        },
                    )
                }
                pendingScannedJoinRequest?.let { request ->
                    val networkName = displayState.networks
                        .firstOrNull { it.id == qrScanNetworkId }
                        ?.name
                        ?.ifBlank { "this network" }
                        ?: "this network"
                    AlertDialog(
                        onDismissRequest = { pendingScannedJoinRequest = null },
                        title = { Text("Add device?") },
                        text = { Text("Add the device from this join request to $networkName?") },
                        confirmButton = {
                            Button(
                                onClick = {
                                    dispatch(NativeActions.importJoinRequest(request))
                                    pendingScannedJoinRequest = null
                                },
                                modifier = Modifier.mobileUiSelector(
                                    id = "join-request-confirm-add",
                                    description = "Confirm adding scanned join request",
                                ),
                            ) {
                                Text("Add")
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = { pendingScannedJoinRequest = null }) {
                                Text("Cancel")
                            }
                        },
                    )
                }
                legacyPackageToRemove?.let { packageName ->
                    AlertDialog(
                        onDismissRequest = {},
                        title = { Text("Remove older Nostr VPN") },
                        text = {
                            Text(
                                "An older Nostr VPN installation is still present. " +
                                    "Remove it so Android cannot run two VPN apps or services.",
                            )
                        },
                        confirmButton = {
                            Button(
                                onClick = {
                                    legacyPackageRemovalLauncher.launch(
                                        AndroidLegacyPackageMigration.uninstallIntent(packageName),
                                    )
                                },
                                modifier = Modifier.mobileUiSelector(
                                    id = "remove-legacy-app",
                                    description = "Remove older Nostr VPN installation",
                                ),
                            ) {
                                Text("Remove old app")
                            }
                        },
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        legacyPackageToRemove = AndroidLegacyPackageMigration.packageToRemove(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        writeAndroidBuildMetadata(appCoreDataDir(this))
        deepLink = intent.dataString
        debugRequest = AndroidDebugRequest.from(intent)
    }

    private fun startVpnService(intent: Intent) {
        if (intent.action == NostrVpnService.ACTION_CONNECT) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun writeAndroidBuildMetadata(dataDir: java.io.File) {
        runCatching {
            dataDir.mkdirs()
            val metadata = JSONObject()
                .put("appPackageName", BuildConfig.APPLICATION_ID)
                .put("appVersionName", BuildConfig.VERSION_NAME)
                .put("appVersionCode", BuildConfig.VERSION_CODE)
            BuildConfig.NVPN_BUILD_GIT_SHA.trim()
                .takeIf { it.isNotEmpty() && !it.startsWith("\${") }
                ?.let { metadata.put("appBuildGitSha", it) }
            BuildConfig.NVPN_BUILD_TIMESTAMP_UTC.trim()
                .takeIf { it.isNotEmpty() && !it.startsWith("\${") }
                ?.let { metadata.put("appBuildTimestampUtc", it) }
            dataDir.resolve(ANDROID_BUILD_METADATA_FILE).writeText(
                metadata.toString(2) + "\n",
                Charsets.UTF_8,
            )
        }.onFailure { error ->
            android.util.Log.w("NostrVpn", "failed to write Android build metadata", error)
        }
    }

    private fun AppState.withAndroidNotice(androidError: String, vpnLockdownActive: Boolean): AppState {
        if (error.isNotBlank()) return this
        if (androidError.isNotBlank()) return copy(error = androidError)
        val fullTunnelConfigured =
            exitNode.isNotBlank() || (wireguardExitEnabled && wireguardExitConfigured)
        if (vpnEnabled && vpnLockdownActive && !fullTunnelConfigured) {
            return copy(
                error = "Android VPN lockdown is on. Split tunnel cannot provide regular internet until lockdown is fully disabled or internet has been selected.",
            )
        }
        return this
    }

    companion object {
        private const val ANDROID_BUILD_METADATA_FILE = "android-build-metadata.json"
        private const val ANDROID_LOCAL_NETWORK_OPT_IN_API = 36
        private const val ANDROID_ACCESS_LOCAL_NETWORK_API = 37
        private const val ACCESS_LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }

}
