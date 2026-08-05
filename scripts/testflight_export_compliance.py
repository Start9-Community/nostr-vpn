"""Minimal App Store Connect export-exempt build policy.

The app implements standard WireGuard and Nostr/FIPS cryptography, but this
App Store distribution excludes France and both shipped bundles declare
``ITSAppUsesNonExemptEncryption=false``. Automation therefore marks only the
exact uploaded build as export-exempt. It never creates or links an app
encryption declaration.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
import json


class ExportComplianceError(RuntimeError):
    """Raised when App Store Connect cannot be made consistent with policy."""


def strict_resource_id(
    resource: Mapping[str, object],
    expected_type: str,
) -> str | None:
    """Return a canonical JSON:API ID only for the expected resource type."""

    value = resource.get("id")
    if (
        resource.get("type") != expected_type
        or not isinstance(value, str)
        or not value
        or value.strip() != value
    ):
        return None
    return value


def select_exact_app(
    apps: Iterable[Mapping[str, object]],
    bundle_id: str,
) -> Mapping[str, object] | None:
    """Return only an exact, well-formed App Store app resource."""

    expected = str(bundle_id).strip()
    if not expected:
        raise ValueError("bundle_id is required")
    matches = []
    for app in apps:
        attributes = app.get("attributes")
        if (
            strict_resource_id(app, "apps") is not None
            and isinstance(attributes, Mapping)
            and attributes.get("bundleId") == expected
        ):
            matches.append(app)
    if len(matches) > 1:
        raise ExportComplianceError(
            f"App Store Connect returned multiple exact apps for {expected}"
        )
    return matches[0] if matches else None


def select_exact_build(
    builds: Iterable[Mapping[str, object]],
    build_number: str,
) -> Mapping[str, object] | None:
    """Return only a build whose live version exactly matches the request."""

    expected = str(build_number).strip()
    if not expected:
        raise ValueError("build_number is required")
    matches = []
    for build in builds:
        attributes = build.get("attributes")
        if (
            strict_resource_id(build, "builds") is not None
            and isinstance(attributes, Mapping)
            and str(attributes.get("version", "")).strip() == expected
        ):
            matches.append(build)
    if len(matches) > 1:
        raise ExportComplianceError(
            f"App Store Connect returned multiple exact builds for {expected}"
        )
    return matches[0] if matches else None


def select_unique_build_for_marketing_version(
    builds: Iterable[Mapping[str, object]],
    build_number: str,
    marketing_version: str,
    live_marketing_version: Callable[[str], str | None],
) -> Mapping[str, object] | None:
    """Bind one build number to its live pre-release marketing version."""

    expected_build = str(build_number).strip()
    expected_marketing = str(marketing_version).strip()
    if not expected_build:
        raise ValueError("build_number is required")
    if not expected_marketing:
        raise ValueError("marketing_version is required")

    matches = []
    for build in builds:
        attributes = build.get("attributes")
        build_id = strict_resource_id(build, "builds")
        if (
            build_id is None
            or not isinstance(attributes, Mapping)
            or str(attributes.get("version", "")).strip() != expected_build
            or live_marketing_version(build_id) != expected_marketing
        ):
            continue
        selected = dict(build)
        selected["_nvpnMarketingVersion"] = expected_marketing
        matches.append(selected)

    if len(matches) > 1:
        raise ExportComplianceError(
            "App Store Connect returned multiple exact builds for "
            f"{expected_marketing} ({expected_build})"
        )
    return matches[0] if matches else None


def export_exempt_build_update_request(build_id: str) -> dict[str, object]:
    """Return the exact-build request for the no-France distribution."""

    if not build_id:
        raise ValueError("build_id is required")
    return {
        "data": {
            "type": "builds",
            "id": build_id,
            "attributes": {"usesNonExemptEncryption": False},
        }
    }


def _require_response(
    status: int,
    body: object,
    operation: str,
) -> Mapping[str, object]:
    if not 200 <= status < 300:
        raise ExportComplianceError(
            f"{operation} failed: HTTP {status}\n"
            f"{json.dumps(body, indent=2, default=str)}"
        )
    if not isinstance(body, Mapping):
        raise ExportComplianceError(f"{operation} returned a malformed response")
    return body


def ensure_build_export_exempt(
    build: Mapping[str, object],
    *,
    request: Callable[..., tuple[int, object]],
    get_build: Callable[[str], Mapping[str, object]],
    log: Callable[[str], None] | None = None,
) -> Mapping[str, object]:
    """Set and independently read back the exact build's exempt flag."""

    build_id = strict_resource_id(build, "builds")
    if build_id is None:
        raise ExportComplianceError("Build is missing its App Store Connect ID")

    current = get_build(build_id)
    attributes = current.get("attributes")
    if strict_resource_id(current, "builds") != build_id:
        raise ExportComplianceError("App Store Connect returned the wrong exact build")
    if not isinstance(attributes, Mapping):
        raise ExportComplianceError("App Store Connect build has no attributes")

    if attributes.get("usesNonExemptEncryption") is not False:
        status, body = request(
            "PATCH",
            f"builds/{build_id}",
            body=export_exempt_build_update_request(build_id),
        )
        _require_response(status, body, "Set exact build export-exempt flag")
        current = get_build(build_id)
        attributes = current.get("attributes")

    if (
        strict_resource_id(current, "builds") != build_id
        or not isinstance(attributes, Mapping)
        or attributes.get("usesNonExemptEncryption") is not False
    ):
        raise ExportComplianceError(
            "App Store Connect did not retain usesNonExemptEncryption=false "
            "for the exact build"
        )

    if log is not None:
        log(
            "The exact no-France build is marked export-exempt; no app "
            "encryption declaration or French approval is used."
        )
    return current
