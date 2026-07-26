#!/usr/bin/env python3

from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import appstore_availability as availability


class AppStoreWorldwideAvailabilityTests(unittest.TestCase):
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

    def test_every_current_territory_must_be_available(self):
        france = self._row("FRA", True)
        china = self._row("CHN", True)

        self.assertEqual(
            availability.require_worldwide_availability([france, china]),
            [france, china],
        )

        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "FRA",
        ):
            availability.require_worldwide_availability(
                [self._row("FRA", False), china]
            )

    def test_worldwide_check_fails_closed_on_malformed_or_empty_rows(self):
        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "no territory rows",
        ):
            availability.require_worldwide_availability([])

        for value in (None, 1, "true"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(
                    availability.AppStoreAvailabilityError,
                    "boolean available state",
                ):
                    availability.require_worldwide_availability(
                        [self._row("USA", value)]
                    )

        malformed = self._row("USA", True)
        malformed["relationships"] = {}
        with self.assertRaisesRegex(
            availability.AppStoreAvailabilityError,
            "no territory identifier",
        ):
            availability.require_worldwide_availability([malformed])


if __name__ == "__main__":
    unittest.main()
