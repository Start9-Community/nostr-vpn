use std::sync::Arc;

use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair, SubjectPublicKeyInfo};
use tokio_rustls::rustls::{
    CertificateError, Error, RootCertStore,
    client::{WebPkiServerVerifier, danger::ServerCertVerifier},
    crypto::ring::default_provider,
    pki_types::{ServerName, UnixTime},
};

#[test]
fn embedded_roots_exclude_emsign_g3() {
    let g3_spki = include_bytes!("fixtures/emSign-ECC-Root-CA-G3.spki.der");
    for roots in [
        webpki_roots::TLS_SERVER_ROOTS,
        webpki_roots_compat::TLS_SERVER_ROOTS,
    ] {
        assert!(!roots.is_empty());
        assert!(
            roots
                .iter()
                .all(|root| root.subject_public_key_info.as_ref() != g3_spki)
        );
    }
}

#[test]
fn verifier_distrusts_emudhra_intermediate_keys() {
    let root_key = KeyPair::generate().unwrap();
    let root = ca_params("Root").self_signed(&root_key).unwrap();
    let mut roots = RootCertStore::empty();
    roots.add(root.der().clone()).unwrap();
    let verifier =
        WebPkiServerVerifier::builder_with_provider(Arc::new(roots), Arc::new(default_provider()))
            .build()
            .unwrap();
    let issuer_key = KeyPair::generate().unwrap();
    let issuer_params = ca_params("Intermediate");
    let issuer = issuer_params
        .clone()
        .signed_by(&issuer_key, &root, &root_key)
        .unwrap();
    let leaf_key = KeyPair::generate().unwrap();
    let leaf = CertificateParams::new(vec!["localhost".into()])
        .unwrap()
        .signed_by(&leaf_key, &issuer, &issuer_key)
        .unwrap();
    let name = ServerName::try_from("localhost").unwrap();
    let now = UnixTime::now();
    verifier
        .verify_server_cert(leaf.der(), &[issuer.der().clone()], &name, &[], now)
        .unwrap();

    for spki in [
        include_bytes!("fixtures/EMDVTLSCAG3B.spki.der"),
        include_bytes!("fixtures/EMDVTLSCAG3C.spki.der"),
        include_bytes!("fixtures/EMEVTLSCAG3B.spki.der"),
        include_bytes!("fixtures/EMEVTLSCAG3C.spki.der"),
        include_bytes!("fixtures/EMOVTLSCAG3B.spki.der"),
        include_bytes!("fixtures/EMOVTLSCAG3C.spki.der"),
        include_bytes!("fixtures/EMOVCSCAG3B.spki.der"),
        include_bytes!("fixtures/EMOVCSCAG3C.spki.der"),
    ] {
        // Upstream fixtures omit the SPKI SEQUENCE tag and length.
        let spki_der = [&[0x30, 118][..], spki.as_slice()].concat();
        let public_key = SubjectPublicKeyInfo::from_der(&spki_der).unwrap();
        let blocked_issuer = issuer_params
            .clone()
            .signed_by(&public_key, &root, &root_key)
            .unwrap();
        // No compromised private key is needed: distrust precedes signature verification.
        let error = verifier
            .verify_server_cert(leaf.der(), &[blocked_issuer.der().clone()], &name, &[], now)
            .unwrap_err();
        let Error::InvalidCertificate(CertificateError::Other(error)) = error else {
            panic!("expected explicit key distrust, got {error:?}");
        };
        assert_eq!(
            error.0.downcast_ref::<webpki::Error>(),
            Some(&webpki::Error::CertDistrusted)
        );
    }
}

fn ca_params(name: &str) -> CertificateParams {
    let mut params = CertificateParams::default();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.distinguished_name.push(DnType::CommonName, name);
    params
}
