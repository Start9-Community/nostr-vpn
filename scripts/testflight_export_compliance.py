"""App Store Connect export-compliance policy for the iOS build.

The iOS binary contains app-implemented, industry-standard cryptography. Its
Info.plist therefore declares non-exempt encryption. A truthful, approved
French-store-enabled app-encryption declaration must be linked to every build
whose Info.plist flag is true.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
import json


APP_DESCRIPTION = (
    "Nostr VPN is a user-configured private VPN and mesh networking app. "
    "It implements industry-standard WireGuard and Nostr/FIPS cryptography "
    "for encrypted networking and control transport, and uses no proprietary "
    "or non-standard cryptography."
)

_DECLARATION_FIELDS = (
    "appDescription,usesEncryption,exempt,containsProprietaryCryptography,"
    "containsThirdPartyCryptography,availableOnFrenchStore,platform,"
    "appEncryptionDeclarationState,createdDate"
)
_ACCEPTABLE_STATE = "APPROVED"
_ACTIVE_PENDING_STATES = {"CREATED", "IN_REVIEW"}


class ExportComplianceError(RuntimeError):
    """Raised when App Store Connect cannot be made consistent with policy."""


class FrenchDeclarationNotApproved(ExportComplianceError):
    """Raised when truthful French-store paperwork exists but is not approved."""


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


@dataclass(frozen=True)
class VerifiedBuildCompliance:
    """Proof from a live exact-build declaration relationship readback."""

    build: Mapping[str, object]
    build_id: str
    declaration_id: str

    def __post_init__(self) -> None:
        attributes = self.build.get("attributes")
        if (
            strict_resource_id(self.build, "builds") != self.build_id
            or not isinstance(self.build_id, str)
            or not self.build_id
            or self.build_id.strip() != self.build_id
            or not isinstance(self.declaration_id, str)
            or not self.declaration_id
            or self.declaration_id.strip() != self.declaration_id
            or not isinstance(attributes, Mapping)
            or attributes.get("usesNonExemptEncryption") is not True
        ):
            raise ValueError("invalid verified build compliance proof")


def declaration_create_request(app_id: str) -> dict[str, object]:
    """Return Apple's AppEncryptionDeclarationCreateRequest payload."""

    if not app_id:
        raise ValueError("app_id is required")
    return {
        "data": {
            "type": "appEncryptionDeclarations",
            "attributes": {
                "appDescription": APP_DESCRIPTION,
                "availableOnFrenchStore": True,
                "containsProprietaryCryptography": False,
                "containsThirdPartyCryptography": True,
            },
            "relationships": {
                "app": {
                    "data": {
                        "type": "apps",
                        "id": app_id,
                    }
                }
            },
        }
    }


def build_update_request(
    build_id: str,
    declaration_id: str,
) -> dict[str, object]:
    """Return Apple's BuildUpdateRequest payload for non-exempt encryption."""

    if not build_id:
        raise ValueError("build_id is required")
    if not declaration_id:
        raise ValueError("declaration_id is required")
    return {
        "data": {
            "type": "builds",
            "id": build_id,
            "attributes": {
                "usesNonExemptEncryption": True,
            },
            "relationships": {
                "appEncryptionDeclaration": {
                    "data": {
                        "type": "appEncryptionDeclarations",
                        "id": declaration_id,
                    }
                }
            },
        }
    }


def non_exempt_build_update_request(build_id: str) -> dict[str, object]:
    """Mark the exact build truthfully without asserting declaration approval."""

    if not build_id:
        raise ValueError("build_id is required")
    return {
        "data": {
            "type": "builds",
            "id": build_id,
            "attributes": {
                "usesNonExemptEncryption": True,
            },
        }
    }


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
        ):
            continue
        observed_marketing = live_marketing_version(build_id)
        if observed_marketing != expected_marketing:
            continue
        selected = dict(build)
        selected["_nvpnMarketingVersion"] = observed_marketing
        matches.append(selected)

    if len(matches) > 1:
        raise ExportComplianceError(
            "App Store Connect returned multiple exact builds for "
            f"{expected_marketing} ({expected_build})"
        )
    return matches[0] if matches else None


def declaration_answers_policy(declaration: Mapping[str, object]) -> bool:
    """Return whether a declaration contains this release's truthful answers."""

    if declaration.get("type") != "appEncryptionDeclarations":
        return False
    attributes = declaration.get("attributes")
    if not isinstance(attributes, Mapping):
        return False
    if attributes.get("appDescription") != APP_DESCRIPTION:
        return False
    if attributes.get("usesEncryption") is not True:
        return False
    if attributes.get("exempt") is not False:
        return False
    if attributes.get("availableOnFrenchStore") is not True:
        return False
    if attributes.get("containsProprietaryCryptography") is not False:
        return False
    if attributes.get("containsThirdPartyCryptography") is not True:
        return False
    if attributes.get("platform") != "IOS":
        return False
    return True


def declaration_matches_policy(declaration: Mapping[str, object]) -> bool:
    """Return whether a truthful declaration is terminal and reusable."""

    if not declaration_answers_policy(declaration):
        return False
    attributes = declaration.get("attributes")
    assert isinstance(attributes, Mapping)
    state = str(attributes.get("appEncryptionDeclarationState", "")).upper()
    return state == _ACCEPTABLE_STATE


def select_reusable_declaration(
    declarations: Iterable[Mapping[str, object]],
) -> Mapping[str, object] | None:
    """Prefer an approved matching declaration and avoid duplicate resources."""

    matching = [
        declaration
        for declaration in declarations
        if declaration_matches_policy(declaration)
        and strict_resource_id(
            declaration, "appEncryptionDeclarations"
        ) is not None
    ]
    if not matching:
        return None

    def sort_key(declaration: Mapping[str, object]) -> tuple[int, str]:
        attributes = declaration.get("attributes")
        if not isinstance(attributes, Mapping):
            return (99, "")
        state = str(attributes.get("appEncryptionDeclarationState", "")).upper()
        created = str(attributes.get("createdDate", ""))
        return (0 if state == _ACCEPTABLE_STATE else 1, created)

    return sorted(matching, key=sort_key)[0]


def declaration_is_active_pending(
    declaration: Mapping[str, object],
) -> bool:
    """Return whether an exact declaration is still moving toward review."""

    if not declaration_answers_policy(declaration):
        return False
    attributes = declaration.get("attributes")
    assert isinstance(attributes, Mapping)
    state = str(attributes.get("appEncryptionDeclarationState", "")).upper()
    return state in _ACTIVE_PENDING_STATES


def verify_build_compliance(
    build_id: str,
    *,
    request: Callable[..., tuple[int, object]],
    get_build: Callable[[str], Mapping[str, object]],
) -> VerifiedBuildCompliance:
    """Read back an exact build and its approved declaration relationship."""

    if (
        not isinstance(build_id, str)
        or not build_id
        or build_id.strip() != build_id
    ):
        raise ExportComplianceError("Build is missing its App Store Connect ID")

    build = get_build(build_id)
    attributes = build.get("attributes")
    if (
        strict_resource_id(build, "builds") != build_id
        or not isinstance(attributes, Mapping)
        or attributes.get("usesNonExemptEncryption") is not True
    ):
        raise ExportComplianceError(
            "The exact App Store Connect build is not declared as using "
            "non-exempt encryption"
        )

    status, body = request(
        "GET",
        f"builds/{build_id}/appEncryptionDeclaration",
        {"fields[appEncryptionDeclarations]": _DECLARATION_FIELDS},
    )
    response = _require_response(
        status,
        body,
        "Verify exact build app encryption declaration",
        expected={200},
    )
    declaration = response.get("data")
    if (
        not isinstance(declaration, Mapping)
        or strict_resource_id(
            declaration, "appEncryptionDeclarations"
        ) is None
        or not declaration_matches_policy(declaration)
    ):
        raise ExportComplianceError(
            "The exact App Store Connect build is not linked to the matching "
            "approved French-store encryption declaration"
        )

    return VerifiedBuildCompliance(
        build=build,
        build_id=build_id,
        declaration_id=str(declaration["id"]),
    )


def _require_response(
    status: int,
    body: object,
    operation: str,
    *,
    expected: set[int] | None = None,
) -> Mapping[str, object]:
    valid = status in expected if expected is not None else 200 <= status < 300
    if not valid:
        raise ExportComplianceError(
            f"{operation} failed: HTTP {status}\n"
            f"{json.dumps(body, indent=2, default=str)}"
        )
    if not isinstance(body, Mapping):
        raise ExportComplianceError(f"{operation} returned a malformed response")
    return body


def ensure_build_compliance(
    build: Mapping[str, object],
    *,
    app_id: str,
    request: Callable[..., tuple[int, object]],
    get_all: Callable[..., list[Mapping[str, object]]],
    get_build: Callable[[str], Mapping[str, object]],
    log: Callable[[str], None] | None = None,
) -> Mapping[str, object]:
    """Create/reuse and link the truthful declaration for an uploaded build.

    ``request``, ``get_all``, and ``get_build`` are injected so this policy can
    be verified offline without App Store Connect credentials or mutations.
    """

    build_id = strict_resource_id(build, "builds")
    if build_id is None:
        raise ExportComplianceError("Build is missing its App Store Connect ID")

    current_build = get_build(build_id)
    current_attributes = current_build.get("attributes")
    if (
        strict_resource_id(current_build, "builds") != build_id
    ):
        raise ExportComplianceError(
            "App Store Connect returned the wrong exact build"
        )
    if not isinstance(current_attributes, Mapping):
        raise ExportComplianceError("App Store Connect build has no attributes")

    linked_status, linked_body = request(
        "GET",
        f"builds/{build_id}/appEncryptionDeclaration",
        {"fields[appEncryptionDeclarations]": _DECLARATION_FIELDS},
    )
    linked_declaration: Mapping[str, object] | None = None
    if linked_status == 200:
        response = _require_response(
            linked_status,
            linked_body,
            "Read build app encryption declaration",
        )
        candidate = response.get("data")
        if (
            not isinstance(candidate, Mapping)
            or strict_resource_id(
                candidate, "appEncryptionDeclarations"
            ) is None
        ):
            raise ExportComplianceError(
                "Read build app encryption declaration returned a malformed "
                "relationship"
            )
        linked_declaration = candidate
    elif linked_status != 404:
        _require_response(
            linked_status,
            linked_body,
            "Read build app encryption declaration",
        )

    if (
        linked_declaration is not None
        and not declaration_answers_policy(linked_declaration)
    ):
        raise ExportComplianceError(
            "The exact build is linked to a mismatched app encryption "
            "declaration"
        )

    if (
        linked_declaration is not None
        and declaration_is_active_pending(linked_declaration)
    ):
        attributes = linked_declaration.get("attributes")
        state = (
            str(attributes.get("appEncryptionDeclarationState", "")).upper()
            if isinstance(attributes, Mapping)
            else "UNKNOWN"
        )
        raise FrenchDeclarationNotApproved(
            "The exact build's matching app encryption declaration is not "
            f"approved (state {state or 'UNKNOWN'}). Complete App Store "
            "Connect export-compliance review before linking this build."
        )

    if (
        current_attributes.get("usesNonExemptEncryption") is True
        and linked_declaration is not None
        and declaration_matches_policy(linked_declaration)
    ):
        if log is not None:
            log("Build export compliance is already truthful and linked.")
        return current_build

    declaration = (
        linked_declaration
        if linked_declaration is not None
        and declaration_matches_policy(linked_declaration)
        else None
    )
    if declaration is None:
        declarations = get_all(
            "appEncryptionDeclarations",
            {
                "filter[app]": app_id,
                "fields[appEncryptionDeclarations]": _DECLARATION_FIELDS,
                "limit": "200",
            },
        )
        declaration = select_reusable_declaration(declarations)
        pending = next(
            (
                candidate
                for candidate in declarations
                if declaration_is_active_pending(candidate)
                and strict_resource_id(
                    candidate, "appEncryptionDeclarations"
                ) is not None
            ),
            None,
        )
        if declaration is None and pending is not None:
            attributes = pending.get("attributes")
            state = (
                str(attributes.get("appEncryptionDeclarationState", "")).upper()
                if isinstance(attributes, Mapping)
                else "UNKNOWN"
            )
            raise FrenchDeclarationNotApproved(
                "The matching app encryption declaration is not approved "
                f"(state {state or 'UNKNOWN'}). Complete App Store Connect "
                "export-compliance review before linking this build."
            )

    if declaration is None:
        create_status, create_body = request(
            "POST",
            "appEncryptionDeclarations",
            body=declaration_create_request(app_id),
        )
        response = _require_response(
            create_status,
            create_body,
            "Create app encryption declaration",
            expected={201},
        )
        candidate = response.get("data")
        if not isinstance(candidate, Mapping) or not declaration_answers_policy(
            candidate
        ):
            raise ExportComplianceError(
                "Created app encryption declaration does not match the "
                "non-exempt, French-store-enabled standard-cryptography policy"
            )
        if strict_resource_id(
            candidate, "appEncryptionDeclarations"
        ) is None:
            raise ExportComplianceError(
                "Created app encryption declaration has no ID"
            )
        if not declaration_matches_policy(candidate):
            attributes = candidate.get("attributes")
            state = (
                str(attributes.get("appEncryptionDeclarationState", "")).upper()
                if isinstance(attributes, Mapping)
                else "UNKNOWN"
            )
            message = (
                "Created the truthful app encryption declaration, but it is "
                f"not approved (state {state or 'UNKNOWN'})."
            )
            if state in _ACTIVE_PENDING_STATES:
                raise FrenchDeclarationNotApproved(
                    f"{message} Complete App Store Connect export-compliance "
                    "review before linking this build."
                )
            raise ExportComplianceError(
                f"{message} App Store Connect returned a non-pending state."
            )
        declaration = candidate

    declaration_id = strict_resource_id(
        declaration, "appEncryptionDeclarations"
    )
    if declaration_id is None:
        raise ExportComplianceError("App encryption declaration has no ID")

    patch_status, patch_body = request(
        "PATCH",
        f"builds/{build_id}",
        body=build_update_request(build_id, declaration_id),
    )
    _require_response(
        patch_status,
        patch_body,
        "Set and link build export compliance",
    )

    updated_build = get_build(build_id)
    updated_attributes = updated_build.get("attributes")
    if (
        strict_resource_id(updated_build, "builds") != build_id
        or not isinstance(updated_attributes, Mapping)
        or updated_attributes.get("usesNonExemptEncryption") is not True
    ):
        raise ExportComplianceError(
            "App Store Connect did not retain usesNonExemptEncryption=true"
        )

    verify_status, verify_body = request(
        "GET",
        f"builds/{build_id}/appEncryptionDeclaration",
        {"fields[appEncryptionDeclarations]": _DECLARATION_FIELDS},
    )
    response = _require_response(
        verify_status,
        verify_body,
        "Verify build app encryption declaration",
        expected={200},
    )
    verified_declaration = response.get("data")
    if (
        not isinstance(verified_declaration, Mapping)
        or verified_declaration.get("id") != declaration_id
        or not declaration_matches_policy(verified_declaration)
    ):
        raise ExportComplianceError(
            "App Store Connect did not retain the expected app encryption "
            "declaration relationship"
        )

    if log is not None:
        log(
            "Set usesNonExemptEncryption=true and linked the "
            "approved French-store-enabled standard-cryptography declaration."
        )
    return updated_build


def ensure_build_compliance_with_proof(
    build: Mapping[str, object],
    *,
    app_id: str,
    request: Callable[..., tuple[int, object]],
    get_all: Callable[..., list[Mapping[str, object]]],
    get_build: Callable[[str], Mapping[str, object]],
    log: Callable[[str], None] | None = None,
) -> VerifiedBuildCompliance:
    """Ensure compliance, then independently read back exact-build proof."""

    build_id = strict_resource_id(build, "builds")
    if build_id is None:
        raise ExportComplianceError("Build is missing its App Store Connect ID")
    updated_build = ensure_build_compliance(
        build,
        app_id=app_id,
        request=request,
        get_all=get_all,
        get_build=get_build,
        log=log,
    )
    return verify_build_compliance(
        build_id,
        request=request,
        get_build=get_build,
    )


def ensure_build_non_exempt_encryption(
    build: Mapping[str, object],
    *,
    request: Callable[..., tuple[int, object]],
    get_build: Callable[[str], Mapping[str, object]],
    log: Callable[[str], None] | None = None,
) -> Mapping[str, object]:
    """Truthfully mark one exact build without claiming French approval."""

    build_id = strict_resource_id(build, "builds")
    if build_id is None:
        raise ExportComplianceError("Build is missing its App Store Connect ID")

    current_build = get_build(build_id)
    attributes = current_build.get("attributes")
    if (
        strict_resource_id(current_build, "builds") != build_id
    ):
        raise ExportComplianceError(
            "App Store Connect returned the wrong exact build"
        )
    if not isinstance(attributes, Mapping):
        raise ExportComplianceError("App Store Connect build has no attributes")

    if attributes.get("usesNonExemptEncryption") is not True:
        status, body = request(
            "PATCH",
            f"builds/{build_id}",
            body=non_exempt_build_update_request(build_id),
        )
        _require_response(
            status,
            body,
            "Set exact build non-exempt encryption flag",
        )
        current_build = get_build(build_id)
        attributes = current_build.get("attributes")

    if (
        strict_resource_id(current_build, "builds") != build_id
        or not isinstance(attributes, Mapping)
        or attributes.get("usesNonExemptEncryption") is not True
    ):
        raise ExportComplianceError(
            "App Store Connect did not retain usesNonExemptEncryption=true "
            "for the exact build"
        )

    if log is not None:
        log(
            "The exact build is truthfully marked as using non-exempt "
            "encryption; no French approval is claimed."
        )
    return current_build


def prepare_build_compliance_for_submission(
    build: Mapping[str, object],
    *,
    app_id: str,
    request: Callable[..., tuple[int, object]],
    get_all: Callable[..., list[Mapping[str, object]]],
    get_build: Callable[[str], Mapping[str, object]],
    log: Callable[[str], None] | None = None,
) -> tuple[Mapping[str, object], VerifiedBuildCompliance | None]:
    """Prefer approved proof, but allow App Store Connect to judge France.

    Only the narrow, truthful not-yet-approved state is allowed through. API
    errors, malformed responses, mismatched declarations, and failed exact
    build readbacks still fail closed.
    """

    try:
        proof = ensure_build_compliance_with_proof(
            build,
            app_id=app_id,
            request=request,
            get_all=get_all,
            get_build=get_build,
            log=log,
        )
        return proof.build, proof
    except FrenchDeclarationNotApproved as error:
        if log is not None:
            log(
                f"{error} Continuing with France enabled and truthful "
                "review metadata so App Store Connect can decide."
            )
        current_build = ensure_build_non_exempt_encryption(
            build,
            request=request,
            get_build=get_build,
            log=log,
        )
        return current_build, None
