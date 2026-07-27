#[cfg(target_os = "macos")]
use super::macos::{macos_magic_dns_resolver_config, macos_secure_dns_resolver_config};
use super::*;
use hickory_proto::op::{Message, MessageType, OpCode, Query, ResponseCode};
use hickory_proto::rr::{Name, RData, RecordType};
use hickory_proto::serialize::binary::{BinEncodable as _, BinEncoder};
use nostr_vpn_core::secure_dns::SecureDnsResolver;

struct FixtureResolver {
    fail: bool,
}

#[async_trait::async_trait]
impl SecureDnsLookup for FixtureResolver {
    async fn resolve(
        &self,
        query: &[u8],
    ) -> std::result::Result<Vec<u8>, nostr_vpn_core::secure_dns::SecureDnsError> {
        if self.fail {
            return Err(nostr_vpn_core::secure_dns::SecureDnsError::InvalidResponse);
        }
        let request = Message::from_vec(query).expect("fixture query");
        let mut response =
            Message::new(request.id, MessageType::Response, request.metadata.op_code);
        response.metadata.recursion_available = true;
        for query in request.queries {
            response.add_query(query);
        }
        let mut packet = Vec::new();
        response
            .emit(&mut BinEncoder::new(&mut packet))
            .expect("fixture response");
        Ok(packet)
    }
}

fn query_packet_with_type(name: &str, id: u16, record_type: RecordType) -> Vec<u8> {
    let mut query = Message::new(id, MessageType::Query, OpCode::Query);
    query.add_query(Query::query(
        Name::from_ascii(name).expect("query name"),
        record_type,
    ));
    let mut packet = Vec::new();
    query
        .emit(&mut BinEncoder::new(&mut packet))
        .expect("query packet");
    packet
}

fn query_packet(name: &str, id: u16) -> Vec<u8> {
    query_packet_with_type(name, id, RecordType::A)
}

#[cfg(target_os = "macos")]
#[test]
fn macos_secure_dns_uses_explicit_unicast_resolver_port() {
    assert_eq!(
        SECURE_DNS_BIND,
        "127.0.0.1:1053".parse::<SocketAddr>().unwrap()
    );
    let resolver = macos_secure_dns_resolver_config();
    assert!(resolver.contains("nameserver 127.0.0.1\n"));
    assert!(resolver.contains("port 1053\n"));
    assert!(resolver.contains("domain .\n"));
    assert!(resolver.contains("search_order 1\n"));

    let magic_dns_resolver = macos_magic_dns_resolver_config();
    assert!(magic_dns_resolver.contains("nameserver 127.0.0.1\n"));
    assert!(magic_dns_resolver.contains("port 1053\n"));
    assert!(!magic_dns_resolver.contains("domain .\n"));
}

#[test]
fn windows_policy_forces_all_dns_to_local_authenticated_stub() {
    let script = windows_secure_dns_install_script(42);
    assert!(script.contains("-InterfaceIndex 42"));
    assert!(script.contains("-Namespace '.'"));
    assert!(script.contains("-NameServers '127.0.0.1'"));
    assert!(!script.contains("1.1.1.1"));
    assert!(!script.contains("9.9.9.9"));
    let cleanup = windows_secure_dns_uninstall_script(42);
    assert!(cleanup.contains("-InterfaceIndex 42"));
    assert!(cleanup.contains("-ResetServerAddresses"));
    assert!(cleanup.contains("$servers.Count -eq 1"));
    assert!(cleanup.contains("$servers[0] -eq '127.0.0.1'"));
    let crash_repair = windows_secure_dns_repair_script();
    assert!(crash_repair.contains("Remove-DnsClientNrptRule"));
    assert!(!crash_repair.contains("Set-DnsClientServerAddress"));
    assert!(!crash_repair.contains("-InterfaceIndex"));
}

#[test]
fn direct_resolv_conf_crash_repair_only_restores_owned_content() {
    let previous = b"nameserver 192.0.2.53\n";
    assert!(!linux_direct_resolv_conf_needs_restore(previous, previous));
    assert!(linux_direct_resolv_conf_needs_restore(
        LINUX_DIRECT_RESOLV_CONF,
        previous
    ));
    assert!(linux_direct_resolv_conf_needs_restore(
        &LINUX_DIRECT_RESOLV_CONF[..12],
        previous
    ));
    assert!(linux_direct_resolv_conf_needs_restore(
        &previous[..10],
        previous
    ));
    assert!(!linux_direct_resolv_conf_needs_restore(
        b"nameserver 203.0.113.53\n",
        previous
    ));
}

#[test]
fn windows_wireguard_policy_uses_provider_dns_and_keeps_magic_dns_local() {
    let script = windows_wireguard_dns_script(
        "nvpn-wg-'exit",
        &["10.99.99.1".parse().expect("DNS address")],
    );
    assert!(script.contains("-Name 'nvpn-wg-''exit'"));
    assert!(script.contains("-ServerAddresses @('10.99.99.1')"));
    assert!(script.contains("-Namespace '.nvpn'"));
    assert!(script.contains("-Namespace '.fips'"));
    assert!(script.contains("-Namespace '.' -NameServers @('10.99.99.1')"));
    assert!(!script.contains("-Namespace '.' -NameServers '127.0.0.1'"));
}

#[test]
fn direct_resolv_conf_is_limited_to_containers_and_openrc_hosts() {
    assert!(linux_direct_resolv_conf_allowed(true, false));
    assert!(linux_direct_resolv_conf_allowed(false, true));
    assert!(!linux_direct_resolv_conf_allowed(false, false));
}

#[cfg(target_os = "linux")]
#[test]
fn missing_openrc_resolv_conf_has_an_empty_restore_baseline() {
    let path = std::env::temp_dir().join(format!(
        "nvpn-missing-resolv-conf-{}-{}",
        std::process::id(),
        std::thread::current().name().unwrap_or("unnamed")
    ));
    assert!(!path.exists());
    assert_eq!(
        read_linux_resolv_conf(&path).expect("missing baseline"),
        b""
    );
}

#[tokio::test]
async fn magic_dns_is_answered_locally_before_doh() {
    let packet = query_packet("peer.nvpn.", 55);
    let records = Arc::new(RwLock::new(HashMap::from([(
        "peer.nvpn".to_string(),
        Ipv4Addr::new(10, 44, 1, 9),
    )])));
    let resolver = SecureDnsResolver::new().expect("secure resolver");

    let response = resolve_or_servfail(&resolver, &records, None, &packet)
        .await
        .expect("local response");
    let response = Message::from_vec(&response).expect("DNS response");
    assert_eq!(response.id, 55);
    assert!(response.answers.iter().any(|answer| {
        matches!(
            &answer.data,
            RData::A(hickory_proto::rr::rdata::A(address))
                if *address == Ipv4Addr::new(10, 44, 1, 9)
        )
    }));
}

#[test]
fn direct_npub_fips_query_returns_ipv6_and_identity_without_doh() {
    let identity = fips_core::Identity::generate();
    let packet =
        query_packet_with_type(&format!("{}.fips.", identity.npub()), 77, RecordType::AAAA);

    let (response, resolved) = resolve_fips_dns_if_handled(&packet).expect("direct .fips response");
    let response = Message::from_vec(&response).expect("DNS response");
    assert_eq!(response.id, 77);
    assert!(response.answers.iter().any(|answer| {
        matches!(&answer.data, RData::AAAA(address) if address.0 == identity.address().to_ipv6())
    }));
    let resolved = resolved.expect("resolved identity");
    assert_eq!(resolved.node_addr, *identity.node_addr());
    let canonical_peer = PeerIdentity::from_npub(&identity.npub()).expect("canonical npub");
    assert_eq!(resolved.pubkey, canonical_peer.pubkey_full());
}

#[tokio::test]
async fn local_stub_serves_udp_and_fails_closed() {
    let server = Arc::new(
        tokio::net::UdpSocket::bind("127.0.0.1:0")
            .await
            .expect("UDP server"),
    );
    let address = server.local_addr().expect("UDP address");
    let resolver: ResolverState = Arc::new(RwLock::new(Arc::new(FixtureResolver { fail: true })));
    let records = Arc::new(RwLock::new(HashMap::new()));
    let task = tokio::spawn(run_udp(server, resolver, records, None));
    let client = tokio::net::UdpSocket::bind("127.0.0.1:0")
        .await
        .expect("UDP client");
    client
        .send_to(&query_packet("example.com.", 81), address)
        .await
        .expect("UDP query");
    let mut response = [0_u8; 512];
    let (length, _) = tokio::time::timeout(Duration::from_secs(1), client.recv_from(&mut response))
        .await
        .expect("UDP timeout")
        .expect("UDP response");
    task.abort();

    let response = Message::from_vec(&response[..length]).expect("DNS response");
    assert_eq!(response.id, 81);
    assert_eq!(response.metadata.response_code, ResponseCode::ServFail);
}

#[tokio::test]
async fn local_stub_serves_framed_tcp_dns() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("TCP server");
    let address = listener.local_addr().expect("TCP address");
    let resolver: ResolverState = Arc::new(RwLock::new(Arc::new(FixtureResolver { fail: false })));
    let records = Arc::new(RwLock::new(HashMap::new()));
    let task = tokio::spawn(run_tcp(listener, resolver, records, None));
    let mut client = tokio::net::TcpStream::connect(address)
        .await
        .expect("TCP client");
    let query = query_packet("example.com.", 82);
    client
        .write_all(&(query.len() as u16).to_be_bytes())
        .await
        .expect("TCP query length");
    client.write_all(&query).await.expect("TCP query");
    let response_length = client.read_u16().await.expect("TCP response length") as usize;
    let mut response = vec![0_u8; response_length];
    client
        .read_exact(&mut response)
        .await
        .expect("TCP response");
    task.abort();

    let response = Message::from_vec(&response).expect("DNS response");
    assert_eq!(response.id, 82);
    assert_eq!(response.metadata.message_type, MessageType::Response);
}
