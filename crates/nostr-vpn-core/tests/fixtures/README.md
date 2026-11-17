# TLS trust fixtures

These are public SPKI SEQUENCE contents, without the outer tag and length.
They contain no private keys.

- `EM*.spki.der`: the eight distrusted intermediate public keys from
  [rustls/webpki PR 546](https://github.com/rustls/webpki/pull/546), copied from
  [`src/data/distrusted` at 8ecdcc76f56b68fda67a6adf7976f5eed5006a4c](https://github.com/rustls/webpki/tree/8ecdcc76f56b68fda67a6adf7976f5eed5006a4c/src/data/distrusted).
- `emSign-ECC-Root-CA-G3.spki.der`: the removed trust anchor's
  `subject_public_key_info` from
  [webpki-roots 1.0.8](https://github.com/rustls/webpki-roots/blob/v/1.0.8/webpki-roots/src/lib.rs).

`tls_trust.rs` checks the effective Rust root sets and rustls verifier. Synthetic
intermediates carry the distrusted keys under a locally trusted root; the
verifier must report explicit distrust, not merely an invalid leaf signature.
