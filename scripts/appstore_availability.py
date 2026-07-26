"""Pure App Store territory-availability helpers for the iOS release."""

from __future__ import annotations

from collections.abc import Iterable, Mapping


FRANCE_TERRITORY_ID = "FRA"
CHINA_MAINLAND_TERRITORY_ID = "CHN"
REQUIRED_EXCLUDED_TERRITORIES = {
    FRANCE_TERRITORY_ID: "France",
    CHINA_MAINLAND_TERRITORY_ID: "China mainland",
}


class AppStoreAvailabilityError(RuntimeError):
    """Raised when a required storefront state cannot be proven."""


def require_new_territories_disabled(
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
    if attributes.get("availableInNewTerritories") is not False:
        raise AppStoreAvailabilityError(
            "App Store availability must disable automatic distribution in "
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


def find_territory_availability(
    resources: Iterable[Mapping[str, object]],
    territory: str,
) -> Mapping[str, object] | None:
    expected = territory.strip().upper()
    return next(
        (
            resource
            for resource in resources
            if territory_id(resource) == expected
        ),
        None,
    )


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


def require_territory_excluded(
    resource: Mapping[str, object] | None,
    territory: str,
) -> Mapping[str, object]:
    if resource is None:
        raise AppStoreAvailabilityError(
            f"App Store availability has no {territory} territory row"
        )
    attributes = resource.get("attributes")
    if not isinstance(attributes, Mapping):
        raise AppStoreAvailabilityError(
            f"App Store {territory} availability has no attributes"
        )
    if attributes.get("available") is not False:
        raise AppStoreAvailabilityError(
            f"App Store territory {territory} is still available"
        )
    return resource
