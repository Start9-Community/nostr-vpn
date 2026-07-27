package org.nostrvpn.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.nostrvpn.app.core.AppState
import org.nostrvpn.app.core.NativeActions

@Composable
internal fun ExitDnsSettingsCard(
    state: AppState,
    dispatch: (JSONObject) -> Unit,
) {
    var mode by remember(state.exitDnsMode) { mutableStateOf(state.exitDnsMode) }
    var provider by remember(state.exitDnsDohProvider) { mutableStateOf(state.exitDnsDohProvider) }
    var customUrl by remember(state.exitDnsCustomDohUrl) { mutableStateOf(state.exitDnsCustomDohUrl) }
    var bootstrapIps by remember(state.exitDnsCustomDohBootstrapIps) {
        mutableStateOf(state.exitDnsCustomDohBootstrapIps)
    }
    var throughExitServers by remember(state.exitDnsThroughExitServers) {
        mutableStateOf(state.exitDnsThroughExitServers)
    }
    val validationError = exitDnsValidationError(
        mode = mode,
        provider = provider,
        customUrl = customUrl,
        bootstrapIps = bootstrapIps,
        throughExitServers = throughExitServers,
    )

    AppCard {
        Text("Exit DNS", style = MaterialTheme.typography.titleMedium)
        Text(
            "MagicDNS stays local. Public DNS follows this policy while an internet exit is active.",
            color = Muted,
            style = MaterialTheme.typography.bodySmall,
        )
        ChoiceButtons(
            choices = listOf(
                "automatic" to "Automatic",
                "encrypted" to "Encrypted",
                "through_exit" to "Through exit",
            ),
            selected = mode,
            onSelect = { mode = it },
            selectorPrefix = "exit-dns-mode",
        )
        when (mode) {
            "encrypted" -> {
                ChoiceButtons(
                    choices = listOf(
                        "cloudflare" to "Cloudflare",
                        "quad9" to "Quad9",
                        "custom" to "Custom",
                    ),
                    selected = provider,
                    onSelect = { provider = it },
                    selectorPrefix = "exit-dns-provider",
                )
                if (provider == "custom") {
                    OutlinedTextField(
                        customUrl,
                        { customUrl = it },
                        Modifier
                            .fillMaxWidth()
                            .mobileUiSelector(
                                id = "exit-dns-custom-url",
                                description = "Custom DNS over HTTPS URL",
                            ),
                        label = { Text("HTTPS DoH URL") },
                        singleLine = true,
                        isError = customUrl.isBlank(),
                    )
                    OutlinedTextField(
                        bootstrapIps,
                        { bootstrapIps = it },
                        Modifier
                            .fillMaxWidth()
                            .mobileUiSelector(
                                id = "exit-dns-custom-bootstrap-ips",
                                description = "Custom DNS bootstrap IPs",
                            ),
                        label = { Text("Bootstrap IPs") },
                        singleLine = true,
                        isError = bootstrapIps.isBlank(),
                    )
                }
            }
            "through_exit" -> {
                OutlinedTextField(
                    throughExitServers,
                    { throughExitServers = it },
                    Modifier
                        .fillMaxWidth()
                        .mobileUiSelector(
                            id = "exit-dns-through-exit-servers",
                            description = "DNS through exit server IPs",
                        ),
                    label = { Text("DNS server IPs") },
                    singleLine = true,
                    isError = throughExitServers.isBlank(),
                )
                Text(
                    "These DNS packets are sent only through the selected exit.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            else -> Text(
                "Uses profile DNS when supplied; otherwise built-in encrypted DNS.",
                color = Muted,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (validationError != null) {
            Text(
                validationError,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.mobileUiSelector(
                    id = "exit-dns-validation-error",
                    description = "Exit DNS validation error: $validationError",
                ),
            )
        }
        Button(
            onClick = {
                dispatch(
                    NativeActions.updateSettings(
                        "exitDnsMode" to mode,
                        "exitDnsDohProvider" to provider,
                        "exitDnsCustomDohUrl" to customUrl,
                        "exitDnsCustomDohBootstrapIps" to bootstrapIps,
                        "exitDnsThroughExitServers" to throughExitServers,
                    ),
                )
            },
            enabled = validationError == null,
            modifier = Modifier.mobileUiSelector(
                id = "exit-dns-save",
                description = "Save Exit DNS",
            ),
        ) {
            Text("Save Exit DNS")
        }
    }
}

@Composable
private fun ChoiceButtons(
    choices: List<Pair<String, String>>,
    selected: String,
    onSelect: (String) -> Unit,
    selectorPrefix: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        choices.forEach { (value, label) ->
            if (selected == value) {
                Button(
                    onClick = { onSelect(value) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .mobileUiSelector(
                            id = "$selectorPrefix-$value",
                            description = "$label Exit DNS option",
                        )
                        .semantics { this.selected = true },
                ) { Text(label) }
            } else {
                OutlinedButton(
                    onClick = { onSelect(value) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .mobileUiSelector(
                            id = "$selectorPrefix-$value",
                            description = "$label Exit DNS option",
                        )
                        .semantics { this.selected = false },
                ) { Text(label) }
            }
        }
    }
}

internal fun exitDnsValidationError(
    mode: String,
    provider: String,
    customUrl: String,
    bootstrapIps: String,
    throughExitServers: String,
): String? =
    when {
        mode == "encrypted" && provider == "custom" && customUrl.isBlank() ->
            "Enter an HTTPS DoH URL."
        mode == "encrypted" && provider == "custom" &&
            !customUrl.trim().startsWith("https://", ignoreCase = true) ->
            "DoH URL must use HTTPS."
        mode == "encrypted" && provider == "custom" && bootstrapIps.isBlank() ->
            "Enter at least one bootstrap IP."
        mode == "through_exit" && throughExitServers.isBlank() ->
            "Enter at least one DNS server IP."
        else -> null
    }
