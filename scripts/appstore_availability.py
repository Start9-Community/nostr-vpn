"""Pure helpers for enforcing the App Store territory policy."""

from __future__ import annotations

from collections.abc import Iterable, Mapping


EU_TERRITORY_IDS = frozenset(
    "AUT BEL BGR HRV CYP CZE DNK EST FIN FRA DEU GRC HUN IRL ITA "
    "LVA LTU LUX MLT NLD POL PRT ROU SVK SVN ESP SWE".split()
)
FRANCE_TERRITORY_ID = "FRA"
REQUIRED_ENABLED_TERRITORY_IDS = frozenset({"CHN"})
REQUIRED_TERRITORY_IDS = REQUIRED_ENABLED_TERRITORY_IDS | frozenset(
    {FRANCE_TERRITORY_ID}
)
DSA_TRADER_CONTENT_ERRORS = frozenset(
    {
        "TRADER_STATUS_NOT_PROVIDED",
        "TRADER_STATUS_VERIFICATION_FAILED",
        "TRADER_STATUS_VERIFICATION_STATUS_MISSING",
    }
)


class AppStoreAvailabilityError(RuntimeError):
    """Raised when storefront availability does not match release policy."""


def require_new_territories_enabled(
    resource: Mapping[str, object] | None,
) -> Mapping[str, object]:
    if resource is None:
        raise AppStoreAvailabilityError(
            "App Store territory availability is missing"
        )
    attributes = resource.get("attributes")
    if not isinstance(attributes, Mapping):
        raise AppStoreAvailabilityError(
            "App Store territory availability has no attributes"
        )
    if attributes.get("availableInNewTerritories") is not True:
        raise AppStoreAvailabilityError(
            "App Store availability must enable automatic distribution in "
            "new territories"
        )
    return resource


def territory_id(resource: Mapping[str, object]) -> str:
    relationships = resource.get("relationships")
    if not isinstance(relationships, Mapping):
        return ""
    territory = relationships.get("territory")
    if not isinstance(territory, Mapping):
        return ""
    data = territory.get("data")
    if not isinstance(data, Mapping):
        return ""
    return str(data.get("id", "")).strip().upper()


def required_territory_availability(territory: str) -> bool:
    """Return the required availability state for one territory."""

    territory = str(territory).strip().upper()
    if not territory:
        raise ValueError("territory identifier is required")
    return territory != FRANCE_TERRITORY_ID


def require_territory_policy(
    resources: Iterable[Mapping[str, object]],
) -> list[Mapping[str, object]]:
    rows = list(resources)
    if not rows:
        raise AppStoreAvailabilityError(
            "App Store availability has no territory rows"
        )
    unavailable = []
    france_enabled = False
    present = set()
    for resource in rows:
        resource_id = str(resource.get("id", "")).strip()
        territory = territory_id(resource)
        attributes = resource.get("attributes")
        if not resource_id:
            raise AppStoreAvailabilityError(
                "App Store territory availability row is malformed"
            )
        if not territory:
            raise AppStoreAvailabilityError(
                "App Store availability row has no territory identifier"
            )
        if not isinstance(attributes, Mapping):
            raise AppStoreAvailabilityError(
                f"App Store territory {territory} has no attributes"
            )
        available = attributes.get("available")
        if available is not True and available is not False:
            raise AppStoreAvailabilityError(
                f"App Store territory {territory} has no boolean available state"
            )
        present.add(territory)
        if territory == FRANCE_TERRITORY_ID and available is True:
            france_enabled = True
        elif territory != FRANCE_TERRITORY_ID and available is False:
            unavailable.append(territory)
    missing = sorted(REQUIRED_TERRITORY_IDS - present)
    if missing:
        raise AppStoreAvailabilityError(
            "App Store required territories are missing: " + ", ".join(missing)
        )
    if france_enabled:
        raise AppStoreAvailabilityError(
            "App Store territory FRA must remain disabled"
        )
    if unavailable:
        raise AppStoreAvailabilityError(
            "App Store territories are excluded: " + ", ".join(unavailable)
        )
    return rows


def require_no_eu_trader_status_errors(
    resources: Iterable[Mapping[str, object]],
) -> list[Mapping[str, object]]:
    """Reject DSA trader errors reported for any enabled EU storefront.

    This API check only detects Apple's explicit verification failures. It
    cannot prove the account's positive trader/non-trader selection, which
    must also be verified in App Store Connect and on a public EU listing.
    """

    rows = list(resources)
    for resource in rows:
        territory = territory_id(resource)
        if territory not in EU_TERRITORY_IDS:
            continue
        attributes = resource.get("attributes")
        if not isinstance(attributes, Mapping):
            raise AppStoreAvailabilityError(
                f"App Store EU territory {territory} has no attributes"
            )
        available = attributes.get("available")
        if available is not True and available is not False:
            raise AppStoreAvailabilityError(
                f"App Store EU territory {territory} has no boolean available state"
            )
        if available is False:
            continue
        content_statuses = attributes.get("contentStatuses")
        if not isinstance(content_statuses, list) or not all(
            isinstance(status, str) for status in content_statuses
        ):
            raise AppStoreAvailabilityError(
                f"App Store EU territory {territory} has malformed contentStatuses"
            )
        trader_errors = sorted(
            DSA_TRADER_CONTENT_ERRORS.intersection(content_statuses)
        )
        if trader_errors:
            raise AppStoreAvailabilityError(
                f"App Store EU territory {territory} reports DSA trader "
                f"status error(s): {', '.join(trader_errors)}"
            )
    return rows


def territory_update_request(
    resource_id: str,
    *,
    available: bool,
) -> dict[str, object]:
    if not resource_id.strip():
        raise ValueError("territory availability resource ID is required")
    return {
        "data": {
            "type": "territoryAvailabilities",
            "id": resource_id,
            "attributes": {
                "available": available,
            },
        }
    }
