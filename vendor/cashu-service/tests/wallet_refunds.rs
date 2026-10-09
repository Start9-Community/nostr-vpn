use super::*;

#[tokio::test]
async fn legacy_refunds_do_not_block_payments_or_inflate_spendable_balance() {
    use cdk::nuts::{Proof, SecretKey, State};
    use cdk::secret::Secret;
    use cdk::wallet::types::ProofInfo;

    let mint = Mint::serve(200, true).await;
    let directory = tempfile::tempdir().unwrap();
    mint.seed(directory.path(), 1).await;
    let service = CashuWalletService::open_file_backed(directory.path())
        .await
        .unwrap();
    assert_eq!(
        service.load_wallet_overview(true).await.unwrap().totals[0].balance,
        5
    );
    let db = WalletSqliteDatabase::new(cashu_service::cashu_wallet_db_path(directory.path()))
        .await
        .unwrap();
    let keyset = db
        .get_mint_keysets(mint.url.clone())
        .await
        .unwrap()
        .unwrap()[0]
        .id;
    let sender = SecretKey::generate();
    let mut refund = Proof::new(
        8_u64.into(),
        keyset,
        Secret::new(
            serde_json::json!(["P2PK", {
                "nonce": "legacy-refund", "data": sender.public_key().to_hex(), "tags": null
            }])
            .to_string(),
        ),
        sender.public_key(),
    );
    refund.sign_p2pk(sender).unwrap();
    let info = ProofInfo::new(
        refund.clone(),
        mint.url.clone(),
        State::Unspent,
        CurrencyUnit::Sat,
    )
    .unwrap();
    let y = info.y;
    // Simulate a refund imported by an older version, before this service was opened.
    db.update_proofs(vec![info], vec![]).await.unwrap();
    drop(service);
    let service = CashuWalletService::open_file_backed(directory.path())
        .await
        .unwrap();

    // Sending must work even when the user never opens the wallet overview first.
    let error = service
        .send_payment_token(&mint.url.to_string(), 6)
        .await
        .unwrap_err();
    let shortfall = error
        .downcast_ref::<cashu_service::CashuInsufficientFunds>()
        .unwrap();
    assert_eq!(shortfall.available_sat, 5);
    assert!(!mint
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|path| path == "/v1/swap"));
    let payment = service
        .send_payment_token(&mint.url.to_string(), 2)
        .await
        .unwrap();
    assert_eq!(payment.amount_sat, 2);
    let overview = service.load_wallet_overview(false).await.unwrap();
    assert_eq!(overview.totals[0].balance, 3);
    assert!(overview
        .warnings
        .iter()
        .any(|warning| warning.contains("8 sat") && warning.contains("refund")));
    let saved = db.get_proofs_by_ys(vec![y]).await.unwrap().remove(0);
    assert_eq!(
        saved.proof, refund,
        "a mint signature binds the original secret bytes"
    );
    assert_eq!(saved.state, State::Reserved);
    assert_eq!(saved.used_by_operation, None);

    // Re-import and restart must preserve the hold without duplicating value.
    let imported = service
        .import_payment_proofs(
            &mint.url.to_string(),
            "sat",
            &serde_json::to_string(&vec![refund.clone()]).unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(imported.amount_sat, 0);
    drop(service);
    let service = CashuWalletService::open_file_backed(directory.path())
        .await
        .unwrap();
    let overview = service.load_wallet_overview(false).await.unwrap();
    assert_eq!(overview.totals[0].balance, 3);
    assert_eq!(overview.warnings.len(), 1);
    assert_eq!(db.get_proofs_by_ys(vec![y]).await.unwrap()[0].proof, refund);
}

#[tokio::test]
async fn new_legacy_refunds_are_held_without_touching_pending_or_valid_proofs() {
    use cdk::nuts::{Proof, SecretKey, State};
    use cdk::secret::Secret;
    use cdk::wallet::types::ProofInfo;

    let mint = Mint::serve(200, true).await;
    let directory = tempfile::tempdir().unwrap();
    mint.seed(directory.path(), 1).await;
    let service = CashuWalletService::open_file_backed(directory.path())
        .await
        .unwrap();
    service.load_wallet_overview(true).await.unwrap();
    let db = WalletSqliteDatabase::new(cashu_service::cashu_wallet_db_path(directory.path()))
        .await
        .unwrap();
    let keyset = db
        .get_mint_keysets(mint.url.clone())
        .await
        .unwrap()
        .unwrap()[0]
        .id;
    let sender = SecretKey::generate();
    let mut proofs = Vec::new();
    for (index, tags) in [serde_json::Value::Null, serde_json::json!([])]
        .into_iter()
        .enumerate()
    {
        let mut proof = Proof::new(1_u64.into(), keyset,
            Secret::new(serde_json::json!(["P2PK", {
                "nonce": format!("refund-{index}"), "data": sender.public_key().to_hex(), "tags": tags
            }]).to_string()), sender.public_key());
        proof.sign_p2pk(sender.clone()).unwrap();
        proofs.push(proof);
    }
    service
        .import_payment_proofs(
            &mint.url.to_string(),
            "sat",
            &serde_json::to_string(&proofs).unwrap(),
        )
        .await
        .unwrap();
    let mut owned = Vec::new();
    for state in [State::Pending, State::Reserved] {
        let mut proof = Proof::new(1_u64.into(), keyset,
            Secret::new(serde_json::json!(["P2PK", {
                "nonce": format!("owned-{state}"), "data": sender.public_key().to_hex(), "tags": null
            }]).to_string()), sender.public_key());
        proof.sign_p2pk(sender.clone()).unwrap();
        let mut info = ProofInfo::new(proof, mint.url.clone(), state, CurrencyUnit::Sat).unwrap();
        info.used_by_operation = Some(uuid::Uuid::new_v4());
        owned.push(info);
    }
    db.update_proofs(owned.clone(), vec![]).await.unwrap();
    let overview = service.load_wallet_overview(false).await.unwrap();
    assert_eq!(overview.totals[0].balance, 6);
    assert_eq!(
        service
            .load_mint_balance(&mint.url.to_string())
            .await
            .unwrap()
            .balance_sat,
        6
    );
    assert_eq!(overview.warnings.len(), 1);
    for info in owned {
        assert_eq!(db.get_proofs_by_ys(vec![info.y]).await.unwrap()[0], info);
    }
    let saved = db
        .get_proofs(
            Some(mint.url.clone()),
            None,
            Some(vec![State::Reserved]),
            None,
        )
        .await
        .unwrap();
    let held: Vec<_> = saved
        .into_iter()
        .filter(|info| info.used_by_operation.is_none())
        .collect();
    assert_eq!(held.len(), 1);
    assert_eq!(held[0].proof, proofs[0]);
}
