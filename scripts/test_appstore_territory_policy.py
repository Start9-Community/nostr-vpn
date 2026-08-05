#!/usr/bin/env python3

from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import appstore_availability as availability


class AppStoreTerritoryPolicyTests(unittest.TestCase):
    @staticmethod
    def _row(territory_id: str, available: object) -> dict[str, object]:
        return {
            "type": "territoryAvailabilities",
            "id": f"{territory_id.lower()}-row",
            "attributes": {"available": available},
            "relationships": {
                "territory": {
                    "data": {
                        "type": "territories",
                        "id": territory_id,
                    }
                }
            },
        }

    def test_future_territories_must_remain_enabled(self):
        resource = {
            "type": "appAvailabilities",
            "id": "availability",
            "attributes": {"availableInNewTerritories": True},
        }

        self.assertEqual(
            availability.require_new_territories_enabled(resource),
            resource,
        )
        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "enable automatic distribution",
        ):
            availability.require_new_territories_enabled(
                {
                    **resource,
                    "attributes": {"availableInNewTerritories": False},
                }
            )

    def test_france_must_be_disabled_and_every_other_territory_enabled(self):
        france = self._row("FRA", False)
        china = self._row("CHN", True)
        united_states = self._row("USA", True)

        self.assertEqual(
            availability.require_territory_policy(
                [france, china, united_states]
            ),
            [france, china, united_states],
        )

        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "FRA",
        ):
            availability.require_territory_policy(
                [self._row("FRA", True), china]
            )

        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "USA",
        ):
            availability.require_territory_policy(
                [france, china, self._row("USA", False)]
            )

    def test_france_and_china_must_be_present(self):
        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "CHN",
        ):
            availability.require_territory_policy(
                [self._row("FRA", False), self._row("USA", True)]
            )

        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "FRA",
        ):
            availability.require_territory_policy(
                [self._row("CHN", True), self._row("USA", True)]
            )

    def test_territory_check_fails_closed_on_malformed_or_empty_rows(self):
        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "no territory rows",
        ):
            availability.require_territory_policy([])

        for value in (None, 1, "true"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(
                    availability.AppStoreAvailabilityError,
                    "boolean available state",
                ):
                    availability.require_territory_policy(
                        [self._row("USA", value)]
                    )

        malformed = self._row("USA", True)
        malformed["relationships"] = {}
        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "no territory identifier",
        ):
            availability.require_territory_policy([malformed])

    def test_required_state_disables_only_france(self):
        self.assertFalse(availability.required_territory_availability("FRA"))
        for territory in ("CHN", "USA", "FIN"):
            with self.subTest(territory=territory):
                self.assertTrue(
                    availability.required_territory_availability(territory)
                )


if __name__ == "__main__":
    unittest.main()
