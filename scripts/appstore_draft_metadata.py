"""Pure, offline App Store draft metadata helpers.

The repository defaults are authoritative for fields managed by
``scripts/appstore-draft``. Existing App Store Connect values are accepted by
the public helpers to make that update policy explicit, but are intentionally
not used. A non-empty environment override is the only way to replace a
repository default.
"""

from __future__ import annotations

from collections.abc import Mapping
import os


DEFAULT_DESCRIPTION = """Nostr VPN creates private mesh VPN networks between your own devices and trusted peers.

Create a network, approve devices' signed join requests, start the VPN, and reach your private services through encrypted tunnels. Devices can use readable MagicDNS names, direct LAN paths when available, relay-assisted paths when needed, and optional exit-node routing through a peer or WireGuard upstream you control.

You choose the networks, peers, relays, routes, and exit nodes. Cashu wallet and paid public exit-node features are not included in the iOS edition."""

DEFAULT_PROMOTIONAL_TEXT = "Private mesh VPN for your own devices and trusted peers."
DEFAULT_WHATS_NEW = """Improves device joining, VPN lifecycle reliability, DNS and exit routing, and switching back to the device's direct internet connection."""
DEFAULT_KEYWORDS = "VPN,mesh,WireGuard,Nostr,private network,LAN,peer-to-peer,DNS"
DEFAULT_SUPPORT_URL = "https://nostrvpn.org/support/"
DEFAULT_MARKETING_URL = "https://nostrvpn.org/"


def _value(
    environ: Mapping[str, str],
    name: str,
    default: str,
) -> str:
    value = str(environ.get(name, "")).strip()
    return value or default


def version_localization_attributes(
    existing: Mapping[str, object] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return authoritative version-localization fields for a PUT/PATCH."""

    del existing
    source = os.environ if environ is None else environ
    keywords = _value(source, "NVPN_APPSTORE_KEYWORDS", DEFAULT_KEYWORDS)
    if len(keywords) > 100:
        raise ValueError(
            f"NVPN_APPSTORE_KEYWORDS is {len(keywords)} characters; "
            "App Store limit is 100"
        )

    attrs = {
        "description": _value(
            source,
            "NVPN_APPSTORE_DESCRIPTION",
            DEFAULT_DESCRIPTION,
        ),
        "keywords": keywords,
        "promotionalText": _value(
            source,
            "NVPN_APPSTORE_PROMOTIONAL_TEXT",
            DEFAULT_PROMOTIONAL_TEXT,
        ),
        "supportUrl": _value(
            source,
            "NVPN_APPSTORE_SUPPORT_URL",
            DEFAULT_SUPPORT_URL,
        ),
        "whatsNew": _value(
            source,
            "NVPN_APPSTORE_WHATS_NEW",
            DEFAULT_WHATS_NEW,
        ),
    }
    marketing_url = _value(
        source,
        "NVPN_APPSTORE_MARKETING_URL",
        DEFAULT_MARKETING_URL,
    )
    if marketing_url:
        attrs["marketingUrl"] = marketing_url
    return attrs


def default_review_notes(version_name: str) -> str:
    return f"""Nostr VPN {version_name} is submitted by Sirius Business Oy. It uses Apple's Network Extension framework through NETunnelProviderManager and an embedded NEPacketTunnelProvider extension.

No developer account or demo credentials are required. The Nostr identity used for device pairing is generated and stored locally; Sirius Business Oy does not hold a user account. To review the VPN flow, launch the app, create a network, tap the VPN switch, review the in-app VPN Data Use disclosure, tap Continue, and approve Apple's system VPN permission prompt.

The iOS app offers Direct, trusted Private VPN peers, and WireGuard configurations supplied by the user. The shared repository retains Cashu wallet and paid-exit implementations for non-iOS products. The iOS target is built without those feature dependencies or runtime workers and has no wallet or paid-exit UI/action path; only inert shared state-compatibility data types remain. There is no wallet, mint, token import/export; no paid VPN purchase, use, or sale; and no external purchase link in the iOS app.

This build uses industry-standard cryptography implemented by the app, including WireGuard and encrypted Nostr/FIPS transport, in addition to cryptography provided by Apple operating systems. It is declared as using non-exempt encryption. No French encryption declaration has been filed, so France is excluded from availability for this release. China mainland is also excluded because this submission does not assert a local VPN-service authorization or app filing.

Before first VPN activation, the app explains the connection data needed for configured networks, peers, relays, and exits. Sirius Business Oy does not collect or retain VPN traffic or connection data, sell VPN data, or use it for advertising or tracking. The Settings tab includes a link to the current Privacy Policy."""


def review_notes(
    version_name: str,
    existing: Mapping[str, object] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
) -> str:
    """Return authoritative reviewer notes for the current marketing version."""

    del existing
    source = os.environ if environ is None else environ
    return _value(
        source,
        "NVPN_APPSTORE_REVIEW_NOTES",
        default_review_notes(version_name),
    )


def testflight_review_notes(
    version_name: str,
    existing: Mapping[str, object] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
) -> str:
    """Return authoritative Beta App Review notes for an external build."""

    del existing
    source = os.environ if environ is None else environ
    return _value(
        source,
        "NVPN_TESTFLIGHT_REVIEW_NOTES",
        default_review_notes(version_name),
    )
