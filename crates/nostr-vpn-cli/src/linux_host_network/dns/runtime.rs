use super::*;
use hickory_resolver::net::runtime::{
    RuntimeProvider, TokioHandle, TokioTime, iocompat::AsyncIoTokioAsStd,
};
use std::time::Duration;
use tokio::net::UdpSocket;

#[derive(Clone)]
pub(super) struct ProtectedRuntime {
    handle: TokioHandle,
    protect: DnsSocketProtector,
    interface: Option<String>,
}

impl ProtectedRuntime {
    pub(super) fn new(protect: DnsSocketProtector, interface: Option<String>) -> Self {
        Self {
            handle: TokioHandle::default(),
            protect,
            interface,
        }
    }

    fn prepare(&self, socket: &socket2::SockRef<'_>) -> io::Result<()> {
        (self.protect)(socket)?;
        #[cfg(target_os = "linux")]
        if let Some(interface) = &self.interface {
            socket.bind_device(Some(interface.as_bytes()))?;
        }
        #[cfg(not(target_os = "linux"))]
        let _ = &self.interface;
        Ok(())
    }
}

impl RuntimeProvider for ProtectedRuntime {
    type Handle = TokioHandle;
    type Timer = TokioTime;
    type Udp = UdpSocket;
    type Tcp = AsyncIoTokioAsStd<TcpStream>;

    fn create_handle(&self) -> Self::Handle {
        self.handle.clone()
    }

    fn connect_tcp(
        &self,
        server: SocketAddr,
        bind: Option<SocketAddr>,
        timeout: Option<Duration>,
    ) -> Pin<Box<dyn Future<Output = io::Result<Self::Tcp>> + Send>> {
        let policy = self.clone();
        Box::pin(async move {
            let socket = if server.is_ipv4() {
                TcpSocket::new_v4()?
            } else {
                TcpSocket::new_v6()?
            };
            policy.prepare(&socket2::SockRef::from(&socket))?;
            if let Some(bind) = bind {
                socket.bind(bind)?;
            }
            socket.set_nodelay(true)?;
            let stream = tokio::time::timeout(
                timeout.unwrap_or(Duration::from_secs(5)),
                socket.connect(server),
            )
            .await
            .map_err(|_| {
                io::Error::new(io::ErrorKind::TimedOut, "native DNS connect timed out")
            })??;
            Ok(AsyncIoTokioAsStd(stream))
        })
    }

    fn bind_udp(
        &self,
        local: SocketAddr,
        _server: SocketAddr,
    ) -> Pin<Box<dyn Future<Output = io::Result<Self::Udp>> + Send>> {
        let policy = self.clone();
        Box::pin(async move {
            let socket = UdpSocket::bind(local).await?;
            policy.prepare(&socket2::SockRef::from(&socket))?;
            Ok(socket)
        })
    }
}
