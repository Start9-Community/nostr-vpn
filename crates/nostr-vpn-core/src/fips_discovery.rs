use sha2::{Digest, Sha256};

pub const FIPS_LAN_DISCOVERY_SCOPE_PREFIX: &str = "nostr-vpn";

/// Derive the opaque per-network endpoint label shared by nvpn platforms.
///
/// The endpoint keeps this label for compatibility. Its explicit LAN discovery
/// config uses the common application scope above so devices can find an
/// approval recipient before it learns the private network ID.
pub fn fips_lan_discovery_scope(network_id: &str) -> String {
    let digest = Sha256::digest(network_id.trim().as_bytes());
    format!(
        "{FIPS_LAN_DISCOVERY_SCOPE_PREFIX}:{}",
        hex::encode(&digest[..16])
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lan_discovery_scope_is_private_stable_and_trimmed() {
        let scope = fips_lan_discovery_scope(" private-network-id ");

        assert!(scope.starts_with(&format!("{FIPS_LAN_DISCOVERY_SCOPE_PREFIX}:")));
        assert!(!scope.contains("private-network-id"));
        assert_eq!(scope, fips_lan_discovery_scope("private-network-id"));
    }
}
