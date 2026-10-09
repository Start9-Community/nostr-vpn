use super::*;

// Spilman 0.17.6 commits to `tags: null` for its settlement outputs.
// NUT-10 requires an array when tags are present. Strict mints reject these
// proofs, but rewriting the secret would invalidate the mint signature and
// changing deterministic outputs would break already funded channels.
pub(super) fn is_legacy_refund(proof: &Proof) -> bool {
    let Ok(secret) = serde_json::from_str::<serde_json::Value>(&proof.secret.to_string()) else {
        return false;
    };
    secret[0] == "P2PK" && secret[1].get("tags") == Some(&serde_json::Value::Null)
}

// Keep the original proof in the wallet, reserved without an operation owner.
// CDK selects only unspent proofs, so one unusable refund cannot poison every
// later payment. Never take proofs away from an in-flight send/swap/melt.
pub(super) async fn hold_legacy_refunds(wallet: &cdk::Wallet) -> Result<u64> {
    let proofs = wallet
        .localstore
        .get_proofs(
            Some(wallet.mint_url.clone()),
            Some(wallet.unit.clone()),
            Some(vec![State::Unspent, State::Reserved]),
            None,
        )
        .await
        .context("Failed to check legacy Cashu refunds")?;
    let mut held_amount = 0_u64;
    let mut unspent = Vec::new();
    for proof in proofs {
        if proof.used_by_operation.is_some() || !is_legacy_refund(&proof.proof) {
            continue;
        }
        held_amount = held_amount.saturating_add(proof.proof.amount.to_u64());
        if proof.state == State::Unspent {
            unspent.push(proof.y);
        }
    }
    if !unspent.is_empty() {
        wallet
            .localstore
            .update_proofs_state(unspent, State::Reserved)
            .await
            .context("Failed to hold legacy Cashu refunds for recovery")?;
    }
    Ok(held_amount)
}
