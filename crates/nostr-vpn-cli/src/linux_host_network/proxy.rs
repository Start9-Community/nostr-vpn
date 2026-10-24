use super::*;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Semaphore;

pub(super) async fn serve(
    listener: TcpListener,
    secret: Arc<str>,
    policy: impl Fn() -> Option<Arc<dyn HostNetwork>> + Send + Sync + 'static,
) {
    let slots = Arc::new(Semaphore::new(64));
    loop {
        let Ok((mut client, _)) = listener.accept().await else {
            break;
        };
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let Some(policy) = policy() else { break };
        let secret = secret.clone();
        tokio::spawn(async move {
            let _slot = slot;
            // Unauthenticated clients cannot perform DNS or open a native
            // connection. Bound all handshake and native-connect work.
            let Ok(Ok(mut native)) = tokio::time::timeout(
                Duration::from_secs(5),
                handshake(&mut client, &secret, &*policy),
            )
            .await
            else {
                return;
            };
            let _ = tokio::io::copy_bidirectional(&mut client, &mut native).await;
        });
    }
}

async fn handshake(
    client: &mut TcpStream,
    secret: &str,
    policy: &dyn HostNetwork,
) -> io::Result<TcpStream> {
    let mut header = [0; 2];
    client.read_exact(&mut header).await?;
    if header[0] != 5 || header[1] == 0 {
        return Err(invalid());
    }
    let mut methods = vec![0; usize::from(header[1])];
    client.read_exact(&mut methods).await?;
    if !methods.contains(&2) {
        client.write_all(&[5, 255]).await?;
        return Err(invalid());
    }
    client.write_all(&[5, 2]).await?;
    client.read_exact(&mut header).await?;
    if header[0] != 1 || header[1] == 0 {
        return Err(invalid());
    }
    let mut user = vec![0; usize::from(header[1])];
    client.read_exact(&mut user).await?;
    let length = client.read_u8().await?;
    let mut password = vec![0; usize::from(length)];
    client.read_exact(&mut password).await?;
    let valid = user == b"nvpn"
        && password.len() == secret.len()
        && password
            .iter()
            .zip(secret.as_bytes())
            .fold(0u8, |difference, (a, b)| difference | (a ^ b))
            == 0;
    client.write_all(&[1, if valid { 0 } else { 1 }]).await?;
    if !valid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "carrier authorization failed",
        ));
    }
    let mut request = [0; 4];
    client.read_exact(&mut request).await?;
    if request[..3] != [5, 1, 0] {
        return Err(invalid());
    }
    let host = match request[3] {
        1 => {
            let mut ip = [0; 4];
            client.read_exact(&mut ip).await?;
            std::net::Ipv4Addr::from(ip).to_string()
        }
        4 => {
            let mut ip = [0; 16];
            client.read_exact(&mut ip).await?;
            std::net::Ipv6Addr::from(ip).to_string()
        }
        3 => {
            let length = client.read_u8().await?;
            if length == 0 {
                return Err(invalid());
            }
            let mut host = vec![0; usize::from(length)];
            client.read_exact(&mut host).await?;
            String::from_utf8(host).map_err(|_| invalid())?
        }
        _ => return Err(invalid()),
    };
    let port = client.read_u16().await?;
    if port == 0 {
        return Err(invalid());
    }
    match connect(policy, &host, port).await {
        Ok(native) => {
            client.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            Ok(native)
        }
        Err(error) => {
            client.write_all(&[5, 1, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            Err(error)
        }
    }
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid carrier proxy request")
}

#[cfg(test)]
mod tests;
