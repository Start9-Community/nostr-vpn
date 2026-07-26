#ifndef NOSTR_VPN_APP_CORE_C_H
#define NOSTR_VPN_APP_CORE_C_H

#include <stdbool.h>

typedef struct NvpnAppHandle NvpnAppHandle;
typedef struct NvpnMobileTunnelHandle NvpnMobileTunnelHandle;

NvpnAppHandle *nostr_vpn_app_new(const char *data_dir, const char *app_version);
void nostr_vpn_app_free(NvpnAppHandle *handle);

char *nostr_vpn_app_state_json(const NvpnAppHandle *handle);
char *nostr_vpn_app_refresh_json(const NvpnAppHandle *handle);
char *nostr_vpn_app_dispatch_json(const NvpnAppHandle *handle, const char *action_json);

char *nostr_vpn_qr_matrix_json(const char *text);
char *nostr_vpn_decode_qr_image_json(const char *path);

char *nostr_vpn_mobile_tunnel_config_json(const char *data_dir);
char *nostr_vpn_mobile_tunnel_provider_options_config_json(const char *data_dir);
NvpnMobileTunnelHandle *nostr_vpn_mobile_tunnel_new(const char *config_json);
char *nostr_vpn_mobile_tunnel_runtime_state_json(const NvpnMobileTunnelHandle *handle);
char *nostr_vpn_mobile_tunnel_take_app_config_toml(const NvpnMobileTunnelHandle *handle);
bool nostr_vpn_mobile_tunnel_ack_app_config_toml(
    const NvpnMobileTunnelHandle *handle,
    const char *expected_toml
);
bool nostr_vpn_mobile_tunnel_network_changed(const NvpnMobileTunnelHandle *handle);
char *nostr_vpn_mobile_tunnel_wg_excluded_route(const NvpnMobileTunnelHandle *handle);
void nostr_vpn_mobile_tunnel_free(NvpnMobileTunnelHandle *handle);
bool nostr_vpn_mobile_tunnel_attach_current_tun_fd(NvpnMobileTunnelHandle *handle);
void nostr_vpn_string_free(char *value);

#endif
