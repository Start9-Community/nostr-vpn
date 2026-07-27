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


@dataclass(frozen=True)
class VerifiedBuildCompliance:
    """Proof from a live exact-build declaration relationship readback."""

    build: Mapping[str, object]
    build_id: str
    declaration_id: str

    def __post_init__(self) -> None:
        attributes = self.build.get("attributes")
        if (
            not self.build_id
            or self.build.get("id") != self.build_id
            or not self.declaration_id
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
        and str(declaration.get("id", "")).strip()
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

    if not build_id:
        raise ExportComplianceError("Build is missing its App Store Connect ID")

    build = get_build(build_id)
    attributes = build.get("attributes")
    if (
        build.get("id") != build_id
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
        or not str(declaration.get("id", "")).strip()
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

    build_id = str(build.get("id", "")).strip()
    if not build_id:
        raise ExportComplianceError("Build is missing its App Store Connect ID")

    current_build = get_build(build_id)
    current_attributes = current_build.get("attributes")
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
        if isinstance(candidate, Mapping):
            linked_declaration = candidate
    elif linked_status != 404:
        _require_response(
            linked_status,
            linked_body,
            "Read build app encryption declaration",
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
                and str(candidate.get("id", "")).strip()
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
            raise ExportComplianceError(
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
        if not declaration_matches_policy(candidate):
            attributes = candidate.get("attributes")
            state = (
                str(attributes.get("appEncryptionDeclarationState", "")).upper()
                if isinstance(attributes, Mapping)
                else "UNKNOWN"
            )
            raise ExportComplianceError(
                "Created the truthful app encryption declaration, but it is "
                f"not approved (state {state or 'UNKNOWN'}). Complete App "
                "Store Connect export-compliance review before linking this "
                "build."
            )
        declaration = candidate

    declaration_id = str(declaration.get("id", "")).strip()
    if not declaration_id:
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
        not isinstance(updated_attributes, Mapping)
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

    updated_build = ensure_build_compliance(
        build,
        app_id=app_id,
        request=request,
        get_all=get_all,
        get_build=get_build,
        log=log,
    )
    return verify_build_compliance(
        str(updated_build.get("id", "")).strip(),
        request=request,
        get_build=get_build,
    )
