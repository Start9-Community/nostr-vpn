use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

#[derive(Debug)]
struct FixturePolicy {
    destination: SocketAddr,
    denied: bool,
    resolutions: Mutex<Vec<String>>,
    protected: AtomicUsize,
}

impl HostNetwork for FixturePolicy {
    fn protect_socket(&self, socket: &socket2::SockRef<'_>) -> io::Result<()> {
        assert_eq!(socket.local_addr()?.as_socket().unwrap().port(), 0);
        self.protected.fetch_add(1, Ordering::SeqCst);
        if self.denied {
            Err(io::Error::new(io::ErrorKind::PermissionDenied, "denied"))
        } else {
            Ok(())
        }
    }

    fn resolve<'a>(
        &'a self,
        address: &'a str,
    ) -> Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send + Sync + 'a>> {
        Box::pin(async move {
            self.resolutions.lock().unwrap().push(address.to_owned());
            Ok(vec![self.destination])
        })
    }
}

struct Fixture {
    address: SocketAddr,
    policy: Arc<FixturePolicy>,
    task: JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Fixture {
    async fn start(destination: SocketAddr, denied: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let policy = Arc::new(FixturePolicy {
            destination,
            denied,
            resolutions: Mutex::new(Vec::new()),
            protected: AtomicUsize::new(0),
        });
        let shared = policy.clone();
        let task = tokio::spawn(serve(listener, Arc::from("fixture-secret"), move || {
            Some(shared.clone())
        }));
        Self {
            address,
            policy,
            task,
        }
    }

    fn client(&self, password: &str) -> reqwest::Client {
        let url =
            reqwest::Url::parse(&format!("socks5h://nvpn:{password}@{}", self.address)).unwrap();
        carrier_client_builder(&url)
            .unwrap()
            .timeout(Duration::from_secs(1))
            .build()
            .unwrap()
    }
}

#[tokio::test]
async fn carrier_proxy_rejects_unauthenticated_and_wrong_secret_clients_before_dns() {
    let destination = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::start(destination.local_addr().unwrap(), false).await;
    let mut unauthenticated = TcpStream::connect(fixture.address).await.unwrap();
    unauthenticated.write_all(&[5, 1, 0]).await.unwrap();
    let mut reply = [0; 2];
    unauthenticated.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply, [5, 255]);
    assert!(
        fixture
            .client("wrong-secret")
            .get("http://carrier.invalid:8123")
            .send()
            .await
            .is_err()
    );
    assert!(fixture.policy.resolutions.lock().unwrap().is_empty());
    assert_eq!(fixture.policy.protected.load(Ordering::SeqCst), 0);
    assert!(
        tokio::time::timeout(Duration::from_millis(30), destination.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn carrier_http_uses_remote_dns_and_protected_socket_with_original_host() {
    let destination = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::start(destination.local_addr().unwrap(), false).await;
    let server = tokio::spawn(async move {
        let (mut socket, _) = destination.accept().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(socket.read_u8().await.unwrap());
            assert!(request.len() < 4096);
        }
        let request = String::from_utf8(request).unwrap().to_ascii_lowercase();
        assert!(request.starts_with("get /mint/path http/1.1\r\n"));
        assert!(request.contains("\r\nhost: carrier.invalid:8123\r\n"));
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\ncarrier")
            .await
            .unwrap();
    });
    let response = fixture
        .client("fixture-secret")
        .get("http://carrier.invalid:8123/mint/path")
        .send()
        .await
        .unwrap();
    assert_eq!(response.text().await.unwrap(), "carrier");
    server.await.unwrap();
    assert_eq!(
        *fixture.policy.resolutions.lock().unwrap(),
        vec!["carrier.invalid:8123"]
    );
    assert_eq!(fixture.policy.protected.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn denied_carrier_socket_never_contacts_http_destination() {
    let destination = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fixture = Fixture::start(destination.local_addr().unwrap(), true).await;
    assert!(
        fixture
            .client("fixture-secret")
            .get("http://carrier.invalid:8123")
            .send()
            .await
            .is_err()
    );
    assert_eq!(fixture.policy.protected.load(Ordering::SeqCst), 1);
    assert!(
        tokio::time::timeout(Duration::from_millis(30), destination.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn unsupported_socks_command_is_rejected_before_native_lookup() {
    let fixture = Fixture::start("127.0.0.1:9".parse().unwrap(), false).await;
    let mut client = TcpStream::connect(fixture.address).await.unwrap();
    client.write_all(&[5, 1, 2]).await.unwrap();
    let mut reply = [0; 2];
    client.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply, [5, 2]);
    client
        .write_all(b"\x01\x04nvpn\x0efixture-secret")
        .await
        .unwrap();
    client.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply, [1, 0]);
    client.write_all(&[5, 3, 0, 1]).await.unwrap();
    assert_eq!(client.read(&mut reply).await.unwrap(), 0);
    assert!(fixture.policy.resolutions.lock().unwrap().is_empty());
    assert_eq!(fixture.policy.protected.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn numeric_and_loopback_addresses_do_not_use_application_dns() {
    let network = LinuxHostNetwork {
        resolver: Arc::new(dns::UnderlayDns::new().unwrap()),
        proxy_url: reqwest::Url::parse("socks5h://nvpn:private-capability@127.0.0.1:9").unwrap(),
        proxy_task: Mutex::new(None),
    };
    assert!(
        network
            .resolve("localhost:443")
            .await
            .unwrap()
            .iter()
            .all(|address| address.ip().is_loopback())
    );
    assert_eq!(
        network.resolve("[::1]:1234").await.unwrap(),
        vec!["[::1]:1234".parse::<SocketAddr>().unwrap()]
    );
    assert!(!format!("{network:?}").contains("private-capability"));
}
