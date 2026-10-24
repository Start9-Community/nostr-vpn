use igd_next::SearchError;
use igd_next::aio::tokio::{SearchProvider, Tokio};
use igd_next::aio::{Provider, RequestFuture, RequestProvider};

#[derive(Clone)]
pub(super) enum UpnpProvider {
    Native,
    #[cfg(target_os = "linux")]
    Protected(reqwest::Client),
}

impl std::fmt::Debug for UpnpProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UpnpProvider").finish_non_exhaustive()
    }
}

impl UpnpProvider {
    pub(super) fn new() -> anyhow::Result<Self> {
        #[cfg(target_os = "linux")]
        if let Some(network) = crate::linux_host_network::current() {
            return Ok(Self::Protected(
                network
                    .http_client_builder()?
                    .redirect(reqwest::redirect::Policy::none())
                    .build()?,
            ));
        }
        Ok(Self::Native)
    }
}

impl RequestProvider for UpnpProvider {
    fn send_request<'a>(
        &'a self,
        url: &'a str,
        action: &'a str,
        body: &'a str,
    ) -> RequestFuture<'a> {
        Box::pin(async move {
            match self {
                Self::Native => Tokio::send_async(url, action, body).await,
                #[cfg(target_os = "linux")]
                Self::Protected(client) => Ok(client
                    .post(url)
                    .header("SOAPAction", action)
                    .header("Content-Type", "text/xml")
                    .body(body.to_owned())
                    .send()
                    .await
                    .map_err(std::io::Error::other)?
                    .text()
                    .await
                    .map_err(std::io::Error::other)?),
            }
        })
    }
}

#[async_trait::async_trait]
impl SearchProvider for UpnpProvider {
    fn prepare_socket(&self, socket: &tokio::net::UdpSocket) -> std::io::Result<()> {
        super::super::probes::protect_control_socket(&socket2::SockRef::from(socket))
    }

    async fn get(&self, url: &str) -> Result<Vec<u8>, SearchError> {
        match self {
            Self::Native => Tokio.get(url).await,
            #[cfg(target_os = "linux")]
            Self::Protected(client) => Ok(client
                .get(url)
                .send()
                .await
                .map_err(std::io::Error::other)?
                .bytes()
                .await
                .map_err(std::io::Error::other)?
                .to_vec()),
        }
    }
}
