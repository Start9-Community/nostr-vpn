    #[test]
    fn send_identity_derives_an_independent_participant_endpoint() {
        let participant = Keys::generate();
        let participant_hex = participant.public_key().to_hex();
        let participant_npub = participant.public_key().to_bech32().expect("npub");
        let participant_key =
            participant_pubkey_bytes(&participant_hex).expect("participant key");
        let endpoint_node_addr = *PeerIdentity::from_npub(&participant_npub)
            .expect("participant endpoint identity")
            .node_addr()
            .as_bytes();

        let identity = endpoint_identity_for_send(
            &FipsPeerIdentityMap::default(),
            Some(&participant_key),
            &endpoint_node_addr,
        )
        .expect("independent participant send identity");

        assert_eq!(identity.npub(), participant_npub);
    }

    #[cfg(feature = "paid-exit")]
    fn paid_route_test_ipv4_udp_packet(total_len: usize) -> Vec<u8> {
        assert!(total_len >= 28);
        assert!(total_len <= u16::MAX as usize);
        let udp_len = total_len - 20;
        let mut packet = vec![0u8; total_len];
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
        packet[9] = 17;
        packet[12..16].copy_from_slice(&[10, 8, 0, 2]);
        packet[16..20].copy_from_slice(&[198, 51, 100, 1]);
        packet[20..22].copy_from_slice(&12345u16.to_be_bytes());
        packet[22..24].copy_from_slice(&53u16.to_be_bytes());
        packet[24..26].copy_from_slice(&(udp_len as u16).to_be_bytes());
        packet
    }
