#![cfg(feature = "paid-exit")]
use nostr_sdk::prelude::*;
use nostr_vpn_core::paid_provider_names::*;

fn list(author: &Keys, kind: Kind, users: &[&Keys], at: u64) -> Event {
    EventBuilder::new(kind, "")
        .tags(users.iter().map(|u| Tag::public_key(u.public_key())))
        .custom_created_at(Timestamp::from(at))
        .sign_with_keys(author)
        .unwrap()
}
fn profile(author: &Keys, content: &str, at: u64) -> Event {
    EventBuilder::new(Kind::Metadata, content)
        .custom_created_at(Timestamp::from(at))
        .sign_with_keys(author)
        .unwrap()
}
#[test]
fn seller_identity_uses_stable_alias_until_trusted_and_reverts_when_overmuted() {
    let root = Keys::generate();
    let friend = Keys::generate();
    let seller = Keys::generate();
    let npub = seller.public_key().to_bech32().unwrap();
    let hex = seller.public_key().to_hex();
    let alias = provider_alias(&npub);
    assert_eq!(alias, provider_alias(&hex));
    assert_eq!(alias.split_whitespace().count(), 2);
    let mut events = vec![profile(
        &seller,
        r#"{"display_name":"River","name":"old"}"#,
        100,
    )];
    let resolve = |events: &[Event]| {
        provider_display_name(
            &npub,
            &provider_name_graph(&root.public_key().to_hex(), events, 200),
            events,
            200,
        )
    };
    assert_eq!(resolve(&events), alias);
    events.push(list(&root, Kind::ContactList, &[&friend], 100));
    events.push(list(&friend, Kind::ContactList, &[&seller], 100));
    assert_eq!(resolve(&events), "River");
    events.push(profile(&seller, r#"{"name":"Future impostor"}"#, 10_000));
    assert_eq!(resolve(&events), "River");
    events.push(list(&root, Kind::MuteList, &[&seller], 150));
    assert_eq!(resolve(&events), alias);
    events.push(list(&root, Kind::MuteList, &[], 160));
    assert_eq!(resolve(&events), "River");
    events.push(list(&root, Kind::ContactList, &[], 170));
    assert_eq!(resolve(&events), alias);
}

#[test]
fn newer_empty_profile_removes_old_name_and_unverified_profiles_never_name_a_provider() {
    let root = Keys::generate();
    let seller = Keys::generate();
    let npub = seller.public_key().to_bech32().unwrap();
    let mut events = vec![
        list(&root, Kind::ContactList, &[&seller], 100),
        profile(&seller, r#"{"name":"River"}"#, 100),
        profile(&seller, "{}", 101),
    ];
    let mut forged = profile(&seller, r#"{"name":"Forged"}"#, 102);
    forged.pubkey = root.public_key();
    events.push(forged);
    let graph = provider_name_graph(&root.public_key().to_hex(), &events, 200);
    assert_eq!(
        provider_display_name(&npub, &graph, &events, 200),
        provider_alias(&npub)
    );
}
