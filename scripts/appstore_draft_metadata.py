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
import re

from testflight_export_compliance import VerifiedBuildCompliance


DEFAULT_DESCRIPTION = """Nostr VPN creates private mesh VPN networks between your own devices and trusted peers.

Create a network, approve devices' signed join requests, start the VPN, and reach your private services through encrypted tunnels. Devices can use readable MagicDNS names, direct LAN paths when available, relay-assisted paths when needed, and optional exit-node routing through a peer or WireGuard upstream you control.

You choose the networks, peers, relays, routes, and exit nodes."""

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


def default_review_notes(
    version_name: str,
    *,
    environ: Mapping[str, str] | None = None,
    encryption_compliance: VerifiedBuildCompliance | None = None,
) -> str:
    if encryption_compliance is not None and not isinstance(
        encryption_compliance,
        VerifiedBuildCompliance,
    ):
        raise ValueError("review notes require a live build compliance proof")
    source = os.environ if environ is None else environ
    review_wireguard_config = str(
        source.get("NVPN_APPSTORE_REVIEW_WIREGUARD_CONFIG", "")
    ).strip()
    wireguard_fixture = (
        "\n\nReady-to-use reviewer WireGuard configuration:\n"
        f"{review_wireguard_config}"
        if review_wireguard_config
        else ""
    )
    french_approval = (
        " The approved French-store encryption declaration is attached to "
        "this exact build in App Store Connect."
        if encryption_compliance is not None
        else ""
    )
    return f"""Nostr VPN {version_name} is a client for user-configured private mesh networks and WireGuard endpoints. Sirius Business Oy does not operate, sell, or provide public VPN endpoints or a hosted VPN service. Users supply and control their own peers and WireGuard configurations. The iOS app uses Apple's Network Extension framework through an NEPacketTunnelProvider.

No developer account or demo credentials are required. The Nostr identity used for device pairing is generated and stored locally; Sirius Business Oy does not hold a user account.

Review paths:
1. Private mesh: launch the app and create a network. On a second Nostr VPN installation (iOS, Android, macOS, Windows, or Linux), choose Join Network and display its signed QR request. On the first device open Devices, select the network, scan or paste the request, and tap Add. The joining screen closes only after that device receives the signed roster containing its identity. Manual join is available on both the admin and joiner sides in the same screens.
2. VPN lifecycle: tap the VPN switch, read the VPN Data Use disclosure, tap Continue, and approve Apple's VPN permission prompt. Background and foreground the app; the Packet Tunnel remains active. Switching between Wi-Fi, cellular, or a personal hotspot reconnects the same tunnel automatically.
3. WireGuard exit and DNS: open Internet, choose WireGuard, paste the reviewer configuration below, and save. Exit DNS supports profile DNS with Cloudflare encrypted DNS as the Automatic fallback, explicit Cloudflare, Quad9, custom DoH, and DNS configured through the exit. Start the VPN, load an HTTPS page, change the network connection, then stop the VPN and select Direct; the device's native route and DNS are restored.

The iOS app offers Direct, trusted Private VPN peers, and WireGuard configurations supplied by the user. Nostr provides signed device identity, peer discovery, and encrypted VPN/mesh networking control transport. The shared repository retains Cashu wallet and paid-exit implementations for non-iOS products. The iOS target is built without those feature dependencies or runtime workers and has no wallet or paid-exit UI/action path; only inert shared state-compatibility data types remain. There is no wallet, mint, token import/export; no paid VPN purchase, use, or sale; and no external purchase link in the iOS app.

This build uses industry-standard cryptography implemented by the app, including WireGuard and encrypted Nostr/FIPS transport, in addition to cryptography provided by Apple operating systems. It is declared as using non-exempt encryption.{french_approval} The app is available worldwide, including France and China.

Before first VPN activation, the app explains the connection data needed for configured networks, peers, relays, exits, and the selected DNS operator. Sirius Business Oy does not collect or retain VPN traffic, connection data, or DNS queries; sell VPN data; or use it for advertising or tracking. The Settings tab includes a link to the current Privacy Policy.{wireguard_fixture}"""


def _claims_unverified_french_approval(notes: str) -> bool:
    normalized = re.sub(r"\s+", " ", notes.lower())
    claims_approval_or_link = (
        "approv" in normalized
        or "attach" in normalized
        or "link" in normalized
    )
    identifies_french_export_compliance = (
        ("french" in normalized or "france" in normalized)
        and (
            "encryption" in normalized
            or "export-compliance" in normalized
            or "export compliance" in normalized
        )
    )
    return claims_approval_or_link and (
        "declaration" in normalized or identifies_french_export_compliance
    )


def _review_notes_value(
    *,
    override_name: str,
    source: Mapping[str, str],
    default: str,
    encryption_compliance: VerifiedBuildCompliance | None,
) -> str:
    override = str(source.get(override_name, "")).strip()
    notes = override or default
    if (
        override
        and encryption_compliance is None
        and _claims_unverified_french_approval(notes)
    ):
        raise ValueError(
            "French encryption approval or attachment may be claimed only "
            "after a verified live build relationship readback"
        )
    return notes


def review_notes(
    version_name: str,
    existing: Mapping[str, object] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    encryption_compliance: VerifiedBuildCompliance | None = None,
) -> str:
    """Return authoritative reviewer notes for the current marketing version."""

    del existing
    source = os.environ if environ is None else environ
    return _review_notes_value(
        override_name="NVPN_APPSTORE_REVIEW_NOTES",
        source=source,
        default=default_review_notes(
            version_name,
            environ=source,
            encryption_compliance=encryption_compliance,
        ),
        encryption_compliance=encryption_compliance,
    )


def testflight_review_notes(
    version_name: str,
    existing: Mapping[str, object] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    encryption_compliance: VerifiedBuildCompliance | None = None,
) -> str:
    """Return authoritative Beta App Review notes for an external build."""

    del existing
    source = os.environ if environ is None else environ
    return _review_notes_value(
        override_name="NVPN_TESTFLIGHT_REVIEW_NOTES",
        source=source,
        default=default_review_notes(
            version_name,
            environ=source,
            encryption_compliance=encryption_compliance,
        ),
        encryption_compliance=encryption_compliance,
    )


def require_review_submission_encryption_compliance(
    action: str,
    encryption_compliance: VerifiedBuildCompliance | None,
) -> None:
    """Validate an optional live approval proof before review submission.

    France remains enabled even while a truthful encryption declaration is
    pending. In that case reviewer notes must omit any approval claim and App
    Store Connect decides whether the worldwide submission can proceed.
    """

    if action not in {"submit", "public", "public-submit"}:
        return
    if encryption_compliance is not None and not isinstance(
        encryption_compliance, VerifiedBuildCompliance
    ):
        raise ValueError(
            "Review submission encryption compliance must be a verified "
            "exact-build proof when supplied"
        )


def require_testflight_external_review_material(
    action: str,
    *,
    environ: Mapping[str, str] | None = None,
) -> None:
    """Reject external review submission without usable reviewer material."""

    if action not in {"public", "public-submit"}:
        return
    source = os.environ if environ is None else environ
    wireguard_config = str(
        source.get("NVPN_APPSTORE_REVIEW_WIREGUARD_CONFIG", "")
    ).strip()
    override_notes = str(
        source.get("NVPN_TESTFLIGHT_REVIEW_NOTES", "")
    ).strip()
    if not wireguard_config and not override_notes:
        raise ValueError(
            "External TestFlight review requires a ready-to-use reviewer "
            "WireGuard configuration or complete override notes"
        )
