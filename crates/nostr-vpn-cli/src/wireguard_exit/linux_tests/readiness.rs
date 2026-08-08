#[test]
fn wireguard_readiness_requires_one_completed_handshake() {
    assert!(!parse_linux_wireguard_latest_handshakes("").expect("empty output"));
    assert!(!parse_linux_wireguard_latest_handshakes("peer-key\t0\n").expect("zero handshake"));
    assert!(
        parse_linux_wireguard_latest_handshakes("peer-key\t1778720702\n")
            .expect("completed handshake")
    );
    assert!(parse_linux_wireguard_latest_handshakes("peer-key nope\n").is_err());
    assert!(
        parse_linux_wireguard_latest_handshakes("peer-a 1\npeer-b 2\n").is_err(),
        "the managed exit interface must have exactly one peer"
    );
}
