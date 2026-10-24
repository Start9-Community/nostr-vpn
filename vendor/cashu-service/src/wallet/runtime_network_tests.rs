use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn fresh_connections_escape_a_stale_pooled_socket_without_reopening_the_wallet() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mint: cdk::mint_url::MintUrl = format!("http://{}", listener.local_addr().unwrap())
        .parse()
        .unwrap();
    let server = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let body = serde_json::to_string(&cdk::nuts::MintInfo::new()).unwrap();
            connections.spawn(async move {
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    request.push(socket.read_u8().await.unwrap());
                }
                socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}", body.len(), body).as_bytes()).await.unwrap();
                // The connection remains open but cannot carry another request,
                // like a socket retaining its source IP after a route change.
                std::future::pending::<()>().await;
            });
        }
    });
    let directory = tempfile::tempdir().unwrap();
    let service = CashuWalletService::open_file_backed(directory.path())
        .await
        .unwrap();
    let wallet = service
        .repository
        .create_wallet(mint.clone(), cdk::nuts::CurrencyUnit::Sat, None)
        .await
        .unwrap();
    wallet.mint_connector().get_mint_info().await.unwrap();
    drop(wallet);
    service.refresh_network_connections().await.unwrap();
    let wallet = service
        .repository
        .get_wallet(&mint, &cdk::nuts::CurrencyUnit::Sat)
        .await
        .unwrap();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        wallet.mint_connector().get_mint_info(),
    )
    .await;
    server.abort();
    result
        .expect("a stale pooled connection delayed the next operation")
        .unwrap();
    assert!(
        CashuWalletService::open_file_backed(directory.path())
            .await
            .is_err(),
        "refreshing connections must retain exclusive wallet ownership"
    );
}

#[tokio::test]
#[cfg(feature = "wallet-proxy")]
async fn explicit_proxy_is_retained_when_wallet_connections_refresh() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = format!(
        "socks5h://nvpn:fixture-secret@{}",
        listener.local_addr().unwrap()
    )
    .parse()
    .unwrap();
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut header = [0; 2];
            socket.read_exact(&mut header).await.unwrap();
            assert_eq!(header[0], 5);
            let mut methods = vec![0; header[1] as usize];
            socket.read_exact(&mut methods).await.unwrap();
            assert!(methods.contains(&2));
            socket.write_all(&[5, 2]).await.unwrap();
            socket.read_exact(&mut header).await.unwrap();
            assert_eq!(header, [1, 4]);
            let mut user = [0; 4];
            socket.read_exact(&mut user).await.unwrap();
            assert_eq!(&user, b"nvpn");
            let mut password = vec![0; socket.read_u8().await.unwrap() as usize];
            socket.read_exact(&mut password).await.unwrap();
            assert_eq!(password, b"fixture-secret");
            socket.write_all(&[1, 0]).await.unwrap();
            let mut request_header = [0; 4];
            socket.read_exact(&mut request_header).await.unwrap();
            assert_eq!(request_header, [5, 1, 0, 3]);
            let mut host = vec![0; socket.read_u8().await.unwrap() as usize];
            socket.read_exact(&mut host).await.unwrap();
            assert_eq!(host, b"wallet-mint.invalid");
            assert_eq!(socket.read_u16().await.unwrap(), 80);
            socket
                .write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                .await
                .unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(socket.read_u8().await.unwrap());
            }
            let request = String::from_utf8(request).unwrap();
            assert!(request.starts_with("GET /v1/info HTTP/1.1\r\n"));
            let body = serde_json::to_string(&cdk::nuts::MintInfo::new()).unwrap();
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}", body.len(), body).as_bytes()).await.unwrap();
        }
    });
    let directory = tempfile::tempdir().unwrap();
    let seed = Arc::new(FileCashuWalletSeedStore::for_data_dir(directory.path()));
    let service = CashuWalletService::open_with_seed_store_and_proxy(directory.path(), seed, proxy)
        .await
        .unwrap();
    let mint: cdk::mint_url::MintUrl = "http://wallet-mint.invalid".parse().unwrap();
    let wallet = service
        .repository
        .create_wallet(mint.clone(), cdk::nuts::CurrencyUnit::Sat, None)
        .await
        .unwrap();
    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        wallet.mint_connector().get_mint_info(),
    )
    .await
    .unwrap()
    .unwrap();
    drop(wallet);
    service.refresh_network_connections().await.unwrap();
    let wallet = service
        .repository
        .get_wallet(&mint, &cdk::nuts::CurrencyUnit::Sat)
        .await
        .unwrap();
    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        wallet.mint_connector().get_mint_info(),
    )
    .await
    .unwrap()
    .unwrap();
    server.await.unwrap();
}
