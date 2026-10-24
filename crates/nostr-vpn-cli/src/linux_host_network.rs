//! Native carrier access. Only sockets created through this policy can use
//! the physical network while Linux exit protection is active.

use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
#[cfg(target_os = "linux")]
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};

use fips_core::host_network::HostNetwork;
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use tokio::task::JoinHandle;

mod dns;
mod proxy;

pub(crate) const CARRIER_MARK: u32 = 0x4e56;
#[cfg(target_os = "linux")]
static NETWORK: OnceLock<Arc<LinuxHostNetwork>> = OnceLock::new();

#[cfg(target_os = "linux")]
pub(crate) fn current() -> Option<Arc<LinuxHostNetwork>> {
    NETWORK.get().cloned()
}

#[cfg(target_os = "linux")]
pub(crate) async fn initialize() -> io::Result<Arc<LinuxHostNetwork>> {
    if let Some(network) = current() {
        return Ok(network);
    }
    let network = LinuxHostNetwork::start().await?;
    NETWORK
        .set(network.clone())
        .map_err(|_| io::Error::other("carrier network initialized twice"))?;
    Ok(network)
}

pub(crate) struct LinuxHostNetwork {
    resolver: Arc<dns::UnderlayDns>,
    proxy_url: reqwest::Url,
    proxy_task: Mutex<Option<JoinHandle<()>>>,
}

impl std::fmt::Debug for LinuxHostNetwork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinuxHostNetwork").finish_non_exhaustive()
    }
}

impl Drop for LinuxHostNetwork {
    fn drop(&mut self) {
        if let Ok(task) = self.proxy_task.get_mut()
            && let Some(task) = task.take()
        {
            task.abort();
        }
    }
}

impl LinuxHostNetwork {
    #[cfg(target_os = "linux")]
    async fn start() -> io::Result<Arc<Self>> {
        // Probe privilege before installing a guard or starting any carrier.
        let probe = TcpSocket::new_v4()?;
        protect_socket(&socket2::SockRef::from(&probe))?;
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
        let secret = Arc::<str>::from(hex::encode(rand::random::<[u8; 32]>()));
        let proxy_url = reqwest::Url::parse(&format!(
            "socks5h://nvpn:{secret}@{}",
            listener.local_addr()?
        ))
        .map_err(io::Error::other)?;
        let resolver = Arc::new(dns::UnderlayDns::new()?);
        let network = Arc::new(Self {
            resolver,
            proxy_url,
            proxy_task: Mutex::new(None),
        });
        let weak = Arc::downgrade(&network);
        let task = tokio::spawn(proxy::serve(listener, secret, move || {
            weak.upgrade()
                .map(|network| network as Arc<dyn HostNetwork>)
        }));
        *network
            .proxy_task
            .lock()
            .map_err(|_| io::Error::other("carrier task lock poisoned"))? = Some(task);
        Ok(network)
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn http_client_builder(&self) -> io::Result<reqwest::ClientBuilder> {
        carrier_client_builder(&self.proxy_url)
    }

    // This URL contains an in-memory capability. Do not log, serialize or put
    // it into process arguments, environment variables, or saved settings.
    pub(crate) fn http_proxy_url(&self) -> &reqwest::Url {
        &self.proxy_url
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn capture_native_dns(&self, contents: &[u8]) -> io::Result<()> {
        self.resolver.capture_direct_config(contents)
    }
}

fn carrier_client_builder(proxy_url: &reqwest::Url) -> io::Result<reqwest::ClientBuilder> {
    Ok(reqwest::Client::builder()
        .no_proxy()
        .proxy(reqwest::Proxy::all(proxy_url.as_str()).map_err(io::Error::other)?))
}

fn protect_socket(socket: &socket2::SockRef<'_>) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    return socket.set_mark(CARRIER_MARK);
    #[cfg(not(target_os = "linux"))]
    {
        let _ = socket;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Linux carrier policy requires SO_MARK",
        ))
    }
}

impl HostNetwork for LinuxHostNetwork {
    fn protect_socket(&self, socket: &socket2::SockRef<'_>) -> io::Result<()> {
        protect_socket(socket)
    }

    fn resolve<'a>(
        &'a self,
        address: &'a str,
    ) -> Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send + Sync + 'a>> {
        Box::pin(async move {
            if let Ok(address) = address.parse::<SocketAddr>() {
                return Ok(vec![address]);
            }
            let (host, port) = address.rsplit_once(':').ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "carrier address needs a port")
            })?;
            let port: u16 = port.parse().map_err(io::Error::other)?;
            self.resolver.resolve(host, port).await
        })
    }
}

async fn connect(policy: &dyn HostNetwork, host: &str, port: u16) -> io::Result<TcpStream> {
    let address = if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let mut error = io::Error::new(
        io::ErrorKind::NotFound,
        "carrier resolver returned no addresses",
    );
    for address in policy.resolve(&address).await? {
        let socket = if address.is_ipv4() {
            TcpSocket::new_v4()?
        } else {
            TcpSocket::new_v6()?
        };
        policy.protect_socket(&socket2::SockRef::from(&socket))?;
        match socket.connect(address).await {
            Ok(stream) => return Ok(stream),
            Err(failure) => error = failure,
        }
    }
    Err(error)
}
