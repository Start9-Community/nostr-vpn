use super::*;
use windows_sys::Win32::NetworkManagement::{IpHelper::*, Ndis::NET_LUID_LH};
use windows_sys::Win32::Networking::WinSock::{AF_INET, AF_INET6, IpDadStatePreferred};

// Winsock source binding selects an interface under Windows' strong host model.
// Refuse weak-host configurations rather than silently measuring another link.
// https://learn.microsoft.com/windows/win32/api/netioapi/ns-netioapi-mib_ipinterface_row
pub(super) fn source_address(interface: &str, ipv6: bool) -> Result<std::net::IpAddr> {
    if interface.is_empty() || interface.contains('\0') {
        anyhow::bail!("invalid paid exit tunnel interface");
    }
    let alias: Vec<u16> = interface.encode_utf16().chain(Some(0)).collect();
    let mut luid = NET_LUID_LH::default();
    let status = unsafe { ConvertInterfaceAliasToLuid(alias.as_ptr(), &mut luid) };
    if status != 0 {
        anyhow::bail!("paid exit tunnel interface {interface} is unavailable ({status})");
    }
    let family = if ipv6 { AF_INET6 } else { AF_INET };
    let mut interfaces = std::ptr::null_mut();
    let status = unsafe { GetIpInterfaceTable(family, &mut interfaces) };
    if status != 0 || interfaces.is_null() {
        anyhow::bail!("could not verify Windows tunnel binding ({status})");
    }
    let weak_host = unsafe {
        let rows = std::slice::from_raw_parts(
            (*interfaces).Table.as_ptr(),
            (*interfaces).NumEntries as usize,
        );
        let weak = rows.iter().any(|row| row.WeakHostSend);
        FreeMibTable(interfaces.cast());
        weak
    };
    if weak_host {
        anyhow::bail!(
            "paid exit probes require Windows strong-host routing; weak-host sending is enabled"
        );
    }
    let mut addresses = std::ptr::null_mut();
    let status = unsafe { GetUnicastIpAddressTable(family, &mut addresses) };
    if status != 0 || addresses.is_null() {
        anyhow::bail!("could not read the paid exit tunnel address ({status})");
    }
    let address = unsafe {
        let rows = std::slice::from_raw_parts(
            (*addresses).Table.as_ptr(),
            (*addresses).NumEntries as usize,
        );
        let ip_of = |row: &MIB_UNICASTIPADDRESS_ROW| -> std::net::IpAddr {
            if ipv6 {
                std::net::Ipv6Addr::from(row.Address.Ipv6.sin6_addr.u.Byte).into()
            } else {
                std::net::Ipv4Addr::from(row.Address.Ipv4.sin_addr.S_un.S_addr.to_ne_bytes()).into()
            }
        };
        let selected = rows
            .iter()
            .find(|row| {
                row.InterfaceLuid.Value == luid.Value && row.DadState == IpDadStatePreferred
            })
            .map(ip_of);
        let duplicate = selected.is_some_and(|ip| {
            rows.iter()
                .any(|row| row.InterfaceLuid.Value != luid.Value && ip_of(row) == ip)
        });
        FreeMibTable(addresses.cast());
        if duplicate { None } else { selected }
    };
    address
        .ok_or_else(|| anyhow!("paid exit tunnel {interface} has no unique usable source address"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn paid_probe_windows_missing_interface_cannot_use_host_http() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let mut table = std::ptr::null_mut();
        assert_eq!(unsafe { GetUnicastIpAddressTable(AF_INET, &mut table) }, 0);
        let mut alias = [0_u16; 257];
        unsafe {
            let rows =
                std::slice::from_raw_parts((*table).Table.as_ptr(), (*table).NumEntries as usize);
            let loopback = rows
                .iter()
                .find(|row| row.Address.Ipv4.sin_addr.S_un.S_addr.to_ne_bytes() == [127, 0, 0, 1])
                .unwrap();
            assert_eq!(
                ConvertInterfaceLuidToAlias(
                    &loopback.InterfaceLuid,
                    alias.as_mut_ptr(),
                    alias.len()
                ),
                0
            );
            FreeMibTable(table.cast());
        }
        let alias =
            String::from_utf16(&alias[..alias.iter().position(|ch| *ch == 0).unwrap()]).unwrap();
        let bound = paid_exit_probe_http_client(Duration::from_secs(1), Some(&alias)).unwrap();
        let server = tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0; 1024];
            stream.read(&mut request).await.unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .await
                .unwrap();
        });
        assert_eq!(
            bound.get(&url).send().await.unwrap().text().await.unwrap(),
            "ok"
        );
        server.await.unwrap();
        assert!(paid_exit_probe_http_client(Duration::from_secs(1), Some("nvpn-missing")).is_err());
        assert!(source_address("nvpn-missing", false).is_err());
        assert!(source_address("nvpn-missing", true).is_err());
    }
}
