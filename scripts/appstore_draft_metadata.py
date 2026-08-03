"""Pure, offline App Store draft metadata helpers.

Existing public App Store text is authoritative by default. Repository
defaults initialize a missing localization, while a non-empty environment
override explicitly replaces only its corresponding field.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
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
REQUIRED_APPSTORE_SCREENSHOT_COUNTS = {
    "APP_IPAD_PRO_3GEN_129": 3,
    "APP_IPHONE_67": 3,
}
VERSION_LOCALIZATION_FIELDS = (
    ("description", "NVPN_APPSTORE_DESCRIPTION", DEFAULT_DESCRIPTION),
    ("keywords", "NVPN_APPSTORE_KEYWORDS", DEFAULT_KEYWORDS),
    (
        "promotionalText",
        "NVPN_APPSTORE_PROMOTIONAL_TEXT",
        DEFAULT_PROMOTIONAL_TEXT,
    ),
    ("supportUrl", "NVPN_APPSTORE_SUPPORT_URL", DEFAULT_SUPPORT_URL),
    ("whatsNew", "NVPN_APPSTORE_WHATS_NEW", DEFAULT_WHATS_NEW),
    ("marketingUrl", "NVPN_APPSTORE_MARKETING_URL", DEFAULT_MARKETING_URL),
)


def _explicit_boolean(
    environ: Mapping[str, str],
    name: str,
) -> bool:
    value = str(environ.get(name, "")).strip().lower()
    if value in {"", "0", "false", "no", "off"}:
        return False
    if value in {"1", "true", "yes", "on"}:
        return True
    raise ValueError(f"{name} must be an explicit boolean")


def reconcile_appstore_screenshots(
    *,
    screenshot_sets: Callable[[], Sequence[Mapping[str, object]]],
    screenshots_for_set: Callable[
        [str],
        Sequence[Mapping[str, object]],
    ],
    replace_screenshots: Callable[[], object],
    environ: Mapping[str, str] | None = None,
) -> tuple[str, tuple[Mapping[str, object], ...]]:
    """Reuse exact complete App Store screenshots unless replacement is explicit."""

    source = os.environ if environ is None else environ
    replace = _explicit_boolean(
        source,
        "NVPN_APPSTORE_REPLACE_SCREENSHOTS",
    )
    if replace:
        replace_screenshots()

    observed: dict[str, Sequence[Mapping[str, object]]] = {}
    for screenshot_set in screenshot_sets():
        resource_id = str(screenshot_set.get("id", "")).strip()
        attributes = screenshot_set.get("attributes")
        if not resource_id or not isinstance(attributes, Mapping):
            raise ValueError("App Store screenshot set is malformed")
        display_type = str(
            attributes.get("screenshotDisplayType", "")
        ).strip()
        if display_type not in REQUIRED_APPSTORE_SCREENSHOT_COUNTS:
            raise ValueError(
                f"Unexpected App Store screenshot set: {display_type or '<empty>'}"
            )
        if display_type in observed:
            raise ValueError(
                f"Duplicate App Store screenshot set: {display_type}"
            )
        observed[display_type] = tuple(screenshots_for_set(resource_id))

    if set(observed) != set(REQUIRED_APPSTORE_SCREENSHOT_COUNTS):
        raise ValueError(
            "App Store draft does not contain exactly the required screenshot sets"
        )

    reusable: list[Mapping[str, object]] = []
    screenshot_ids: set[str] = set()
    for display_type, required_count in (
        REQUIRED_APPSTORE_SCREENSHOT_COUNTS.items()
    ):
        screenshots = observed[display_type]
        if len(screenshots) != required_count:
            raise ValueError(
                f"{display_type} must contain exactly {required_count} screenshots"
            )
        for screenshot in screenshots:
            resource_id = str(screenshot.get("id", "")).strip()
            attributes = screenshot.get("attributes")
            if (
                not resource_id
                or resource_id in screenshot_ids
                or not isinstance(attributes, Mapping)
                or not str(attributes.get("fileName", "")).strip()
            ):
                raise ValueError(
                    f"{display_type} contains a malformed screenshot resource"
                )
            delivery = attributes.get("assetDeliveryState")
            if (
                not isinstance(delivery, Mapping)
                or delivery.get("state") != "COMPLETE"
            ):
                raise ValueError(
                    f"{display_type} screenshot {resource_id} is not COMPLETE"
                )
            screenshot_ids.add(resource_id)
            reusable.append(screenshot)

    return (
        "replaced" if replace else "reused",
        tuple(reusable),
    )


def _existing_localization_attributes(
    existing: Mapping[str, object] | None,
) -> Mapping[str, object] | None:
    if existing is None:
        return None
    attributes = existing.get("attributes")
    if not isinstance(attributes, Mapping):
        raise ValueError("existing App Store localization has no attributes")
    return attributes


def version_localization_attributes(
    existing: Mapping[str, object] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return preserved fields plus any explicit per-field replacements."""

    source = os.environ if environ is None else environ
    current = _existing_localization_attributes(existing)
    values: dict[str, str] = {}
    for attribute, environment_name, default in VERSION_LOCALIZATION_FIELDS:
        override = str(source.get(environment_name, "")).strip()
        existing_value = current.get(attribute) if current is not None else None
        if override:
            values[attribute] = override
        elif current is None:
            values[attribute] = default
        elif isinstance(existing_value, str):
            values[attribute] = existing_value
    if len(values.get("keywords", "")) > 100:
        raise ValueError(
            f"NVPN_APPSTORE_KEYWORDS is {len(values['keywords'])} characters; "
            "App Store limit is 100"
        )
    return values


def version_localization_patch(
    existing: Mapping[str, object],
    *,
    environ: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return only explicit replacements that differ from live metadata."""

    current = _existing_localization_attributes(existing) or {}
    desired = version_localization_attributes(existing, environ=environ)
    return {
        name: value
        for name, value in desired.items()
        if current.get(name) != value
    }


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
2. VPN lifecycle: tap the VPN switch, read the VPN Data Use disclosure, tap Continue, and approve Apple's VPN permission prompt. Background and foreground the app; the Packet Tunnel remains active. Turning Wi-Fi off and on restores the same Wi-Fi connection and reconnects the same tunnel automatically.
3. WireGuard exit and DNS: open Internet, choose WireGuard, paste the reviewer configuration below, and save. Exit DNS supports profile DNS with Cloudflare encrypted DNS as the Automatic fallback, explicit Cloudflare, Quad9, custom DoH, and DNS configured through the exit. Start the VPN, load an HTTPS page, turn Wi-Fi off and back on, then stop the VPN and select Direct; the device's native route and DNS are restored.

The iOS app offers Direct, trusted Private VPN peers, and WireGuard configurations supplied by the user. Nostr provides signed device identity, peer discovery, and encrypted VPN/mesh networking control transport. The shared repository retains Cashu wallet and paid-exit implementations for non-iOS products. The iOS target is built without those feature dependencies or runtime workers and has no wallet or paid-exit UI/action path; only inert shared state-compatibility data types remain. There is no wallet, mint, token import/export; no paid VPN purchase, use, or sale; and no external purchase link in the iOS app.

This build uses industry-standard cryptography implemented by the app, including WireGuard and encrypted Nostr/FIPS transport, in addition to cryptography provided by Apple operating systems. It is declared as using non-exempt encryption.{french_approval} The app is available worldwide, including France and China.

Before first VPN activation, the app explains the connection data needed for configured networks, peers, relays, exits, and the selected DNS operator. Sirius Business Oy does not collect or retain VPN traffic, connection data, or DNS queries; sell VPN data; or use it for advertising or tracking. The Settings tab includes a link to the current Privacy Policy.{wireguard_fixture}"""


def _claims_unverified_french_approval(notes: str) -> bool:
    normalized = re.sub(r"\s+", " ", notes.lower())
    sentences = [
        sentence.strip()
        for sentence in re.split(r"(?<=[.!?])\s+", normalized)
        if sentence.strip()
    ]
    subject = re.compile(
        r"(?:\b(?:french|france)\b.*\b(?:encryption|export[ -]compliance)\b"
        r"|\b(?:encryption|export[ -]compliance)\b.*\bdeclaration\b)"
    )
    positive = re.compile(
        r"\b(?:approval|approved|accepted|granted|cleared|attached|linked|"
        r"associated|assigned)\b"
    )
    pending_or_negated = re.compile(
        r"\b(?:no|not|never|without|pending|awaiting|unapproved|rejected|denied)\b"
    )
    referential = re.compile(r"\b(?:it|this|that|declaration|approval|apple|build)\b")

    def positive_claim(sentence: str) -> bool:
        clauses = re.split(
            r"[,;:]|\b(?:but|however|although)\b",
            sentence,
        )
        return any(
            positive.search(clause) and not pending_or_negated.search(clause)
            for clause in clauses
        )

    for index, sentence in enumerate(sentences):
        if not subject.search(sentence):
            continue
        if positive_claim(sentence):
            return True
        if index + 1 >= len(sentences):
            continue
        following = sentences[index + 1]
        if referential.search(following) and positive_claim(following):
            return True
    return False


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
    """Require live exact-build French approval before review submission."""

    if action not in {"submit", "public", "public-submit"}:
        return
    if encryption_compliance is None:
        raise ValueError(
            "Review submission requires an approved French-store encryption "
            "declaration linked to the exact build"
        )
    if not isinstance(encryption_compliance, VerifiedBuildCompliance):
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
