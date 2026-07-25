#!/usr/bin/env python3

from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import appstore_availability as availability
import appstore_draft_metadata as metadata
import testflight_export_compliance as export_compliance


class AppStoreDraftMetadataTests(unittest.TestCase):
    def test_repo_defaults_replace_stale_existing_version_metadata(self):
        existing = {
            "attributes": {
                "description": "stale description",
                "keywords": "stale",
                "promotionalText": "stale promotional text",
                "supportUrl": "https://example.invalid/stale",
                "whatsNew": "stale release notes",
                "marketingUrl": "https://example.invalid/old",
            }
        }

        attrs = metadata.version_localization_attributes(existing, environ={})

        self.assertEqual(attrs["description"], metadata.DEFAULT_DESCRIPTION)
        self.assertEqual(attrs["keywords"], metadata.DEFAULT_KEYWORDS)
        self.assertEqual(attrs["promotionalText"], metadata.DEFAULT_PROMOTIONAL_TEXT)
        self.assertEqual(attrs["supportUrl"], "https://nostrvpn.org/support/")
        self.assertEqual(attrs["whatsNew"], metadata.DEFAULT_WHATS_NEW)
        self.assertEqual(attrs["marketingUrl"], metadata.DEFAULT_MARKETING_URL)

    def test_explicit_environment_overrides_repo_defaults(self):
        attrs = metadata.version_localization_attributes(
            None,
            environ={
                "NVPN_APPSTORE_DESCRIPTION": "explicit description",
                "NVPN_APPSTORE_KEYWORDS": "one,two",
                "NVPN_APPSTORE_PROMOTIONAL_TEXT": "explicit promo",
                "NVPN_APPSTORE_SUPPORT_URL": "https://support.example/",
                "NVPN_APPSTORE_WHATS_NEW": "explicit changes",
                "NVPN_APPSTORE_MARKETING_URL": "https://marketing.example/",
            },
        )

        self.assertEqual(attrs["description"], "explicit description")
        self.assertEqual(attrs["keywords"], "one,two")
        self.assertEqual(attrs["promotionalText"], "explicit promo")
        self.assertEqual(attrs["supportUrl"], "https://support.example/")
        self.assertEqual(attrs["whatsNew"], "explicit changes")
        self.assertEqual(attrs["marketingUrl"], "https://marketing.example/")

    def test_keywords_limit_is_validated_offline(self):
        with self.assertRaisesRegex(ValueError, "100"):
            metadata.version_localization_attributes(
                None,
                environ={"NVPN_APPSTORE_KEYWORDS": "x" * 101},
            )

    def test_reviewer_notes_replace_stale_notes_and_use_current_version(self):
        notes = metadata.review_notes(
            "4.1.4",
            {"attributes": {"notes": "stale review notes"}},
            environ={},
        )

        self.assertIn("Nostr VPN 4.1.4", notes)
        self.assertNotIn("stale review notes", notes)
        self.assertIn("without those feature dependencies or runtime workers", notes)
        self.assertIn("no wallet or paid-exit UI/action path", notes)
        self.assertIn("only inert shared state-compatibility data types remain", notes)
        self.assertIn("no wallet, mint, token import/export", notes)
        self.assertIn("no paid VPN purchase, use, or sale", notes)
        self.assertIn("no external purchase link", notes)
        self.assertIn("non-exempt encryption", notes)
        self.assertIn("France is excluded from availability", notes)
        self.assertIn("China mainland is also excluded", notes)

    def test_explicit_reviewer_notes_override_repo_default(self):
        notes = metadata.review_notes(
            "4.1.4",
            {"attributes": {"notes": "stale review notes"}},
            environ={"NVPN_APPSTORE_REVIEW_NOTES": "explicit review notes"},
        )
        self.assertEqual(notes, "explicit review notes")

    def test_testflight_notes_replace_stale_connect_notes(self):
        notes = metadata.testflight_review_notes(
            "4.1.4",
            {"notes": "stale TestFlight review notes"},
            environ={},
        )

        self.assertEqual(notes, metadata.default_review_notes("4.1.4"))
        self.assertNotIn("stale TestFlight review notes", notes)
        self.assertIn("without those feature dependencies or runtime workers", notes)
        self.assertIn("no wallet or paid-exit UI/action path", notes)
        self.assertIn("no paid VPN purchase, use, or sale", notes)
        self.assertIn("VPN Data Use disclosure", notes)
        self.assertIn("non-exempt encryption", notes)
        self.assertIn("France is excluded from availability", notes)
        self.assertIn("China mainland is also excluded", notes)

    def test_explicit_testflight_notes_override_repo_default(self):
        notes = metadata.testflight_review_notes(
            "4.1.4",
            {"notes": "stale TestFlight review notes"},
            environ={"NVPN_TESTFLIGHT_REVIEW_NOTES": "deliberate beta override"},
        )

        self.assertEqual(notes, "deliberate beta override")

    def test_testflight_shipper_uses_authoritative_notes_helper(self):
        shipper = (ROOT / "scripts" / "testflight-internal").read_text(
            encoding="utf-8"
        )

        self.assertIn("testflight_review_notes(", shipper)
        self.assertNotIn('or attrs.get("notes")', shipper)

    def test_support_page_exists_in_repo(self):
        support_page = ROOT / "docs" / "support" / "index.html"
        self.assertTrue(support_page.is_file())
        contents = support_page.read_text(encoding="utf-8")
        self.assertIn("Nostr VPN Support", contents)
        self.assertIn("mailto:", contents)

    def test_required_storefronts_can_only_pass_when_explicitly_excluded(self):
        france = {
            "type": "territoryAvailabilities",
            "id": "france-row",
            "attributes": {"available": False},
            "relationships": {
                "territory": {
                    "data": {"type": "territories", "id": "FRA"},
                }
            },
        }
        germany = {
            "type": "territoryAvailabilities",
            "id": "germany-row",
            "attributes": {"available": True},
            "relationships": {
                "territory": {
                    "data": {"type": "territories", "id": "DEU"},
                }
            },
        }
        selected = availability.find_territory_availability(
            [germany, france],
            availability.FRANCE_TERRITORY_ID,
        )
        self.assertEqual(selected, france)
        self.assertEqual(
            availability.require_territory_excluded(selected, "FRA"),
            france,
        )
        with self.assertRaises(availability.AppStoreAvailabilityError):
            availability.require_territory_excluded(
                {**france, "attributes": {"available": True}},
                "FRA",
            )
        self.assertEqual(
            availability.REQUIRED_EXCLUDED_TERRITORIES,
            {"FRA": "France", "CHN": "China mainland"},
        )

    def test_required_storefront_patch_uses_the_territory_resource(self):
        self.assertEqual(
            availability.territory_update_request(
                "france-row",
                available=False,
            ),
            {
                "data": {
                    "type": "territoryAvailabilities",
                    "id": "france-row",
                    "attributes": {"available": False},
                }
            },
        )
        draft = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )
        self.assertIn('ensure_required_territories_excluded(app["id"])', draft)
        self.assertIn("REQUIRED_EXCLUDED_TERRITORIES.items()", draft)
        self.assertIn("territoryAvailabilities/", draft)


class TestFlightExportComplianceTests(unittest.TestCase):
    def test_declaration_answers_standard_app_crypto_without_france(self):
        body = export_compliance.declaration_create_request("app-id")

        self.assertEqual(
            body,
            {
                "data": {
                    "type": "appEncryptionDeclarations",
                    "attributes": {
                        "appDescription": export_compliance.APP_DESCRIPTION,
                        "availableOnFrenchStore": False,
                        "containsProprietaryCryptography": False,
                        "containsThirdPartyCryptography": True,
                    },
                    "relationships": {
                        "app": {
                            "data": {
                                "type": "apps",
                                "id": "app-id",
                            }
                        }
                    },
                }
            },
        )

    def test_build_update_is_truthful_and_links_declaration(self):
        body = export_compliance.build_update_request("build-id", "declaration-id")

        self.assertEqual(
            body,
            {
                "data": {
                    "type": "builds",
                    "id": "build-id",
                    "attributes": {"usesNonExemptEncryption": True},
                    "relationships": {
                        "appEncryptionDeclaration": {
                            "data": {
                                "type": "appEncryptionDeclarations",
                                "id": "declaration-id",
                            }
                        }
                    },
                }
            },
        )
        self.assertNotIn("false", str(body).lower())

    def test_selects_existing_matching_active_declaration(self):
        rejected = self._declaration("rejected", state="REJECTED")
        created = self._declaration("created", state="CREATED")
        approved = self._declaration("approved", state="APPROVED")

        selected = export_compliance.select_reusable_declaration(
            [rejected, created, approved]
        )

        self.assertEqual(selected["id"], "approved")

    def test_does_not_reuse_wrong_france_or_crypto_answers(self):
        france = self._declaration("france", availableOnFrenchStore=True)
        proprietary = self._declaration(
            "proprietary", containsProprietaryCryptography=True
        )
        apple_only = self._declaration(
            "apple-only", containsThirdPartyCryptography=False
        )
        exempt = self._declaration("exempt", exempt=True)

        self.assertIsNone(
            export_compliance.select_reusable_declaration(
                [france, proprietary, apple_only, exempt]
            )
        )

    def test_ensure_reuses_and_links_without_caller_supplied_id(self):
        calls = []
        builds = [
            self._build(False),
            self._build(True),
        ]
        declaration = self._declaration("existing", state="APPROVED")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            if method == "GET":
                if len([call for call in calls if call[0] == "GET"]) == 1:
                    return 404, {"errors": []}
                return 200, {"data": declaration}
            if method == "PATCH":
                return 200, {"data": self._build(True)}
            raise AssertionError((method, path))

        def get_all(path, params=None):
            self.assertEqual(path, "appEncryptionDeclarations")
            self.assertEqual(params["filter[app]"], "app-id")
            return [declaration]

        result = export_compliance.ensure_build_compliance(
            {"id": "build-id"},
            app_id="app-id",
            request=request,
            get_all=get_all,
            get_build=lambda _build_id: builds.pop(0),
        )

        self.assertTrue(result["attributes"]["usesNonExemptEncryption"])
        patch = next(call for call in calls if call[0] == "PATCH")
        self.assertEqual(patch[1], "builds/build-id")
        self.assertEqual(
            patch[3],
            export_compliance.build_update_request("build-id", "existing"),
        )
        self.assertFalse(any(call[0] == "POST" for call in calls))

    def test_ensure_creates_then_links_when_no_declaration_exists(self):
        calls = []
        builds = [
            self._build(None),
            self._build(True),
        ]
        created = self._declaration("created", state="APPROVED")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            if method == "GET":
                if path.endswith("/appEncryptionDeclaration"):
                    if len([call for call in calls if call[0] == "GET"]) == 1:
                        return 404, {"errors": []}
                    return 200, {"data": created}
            if method == "POST":
                return 201, {"data": created}
            if method == "PATCH":
                return 200, {"data": self._build(True)}
            raise AssertionError((method, path))

        result = export_compliance.ensure_build_compliance(
            {"id": "build-id"},
            app_id="app-id",
            request=request,
            get_all=lambda _path, _params=None: [],
            get_build=lambda _build_id: builds.pop(0),
        )

        self.assertTrue(result["attributes"]["usesNonExemptEncryption"])
        create = next(call for call in calls if call[0] == "POST")
        self.assertEqual(create[1], "appEncryptionDeclarations")
        self.assertEqual(
            create[3],
            export_compliance.declaration_create_request("app-id"),
        )
        patch = next(call for call in calls if call[0] == "PATCH")
        self.assertEqual(
            patch[3],
            export_compliance.build_update_request("build-id", "created"),
        )

    def test_ensure_is_noop_when_truthful_declaration_is_already_linked(self):
        calls = []
        declaration = self._declaration("linked", state="APPROVED")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            return 200, {"data": declaration}

        result = export_compliance.ensure_build_compliance(
            {"id": "build-id"},
            app_id="app-id",
            request=request,
            get_all=lambda *_args, **_kwargs: self.fail(
                "should not list declarations"
            ),
            get_build=lambda _build_id: self._build(True),
        )

        self.assertTrue(result["attributes"]["usesNonExemptEncryption"])
        self.assertEqual([call[0] for call in calls], ["GET"])

    def test_shipper_has_no_false_or_manual_id_policy(self):
        shipper = (ROOT / "scripts" / "testflight-internal").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("NVPN_TESTFLIGHT_USES_NONEXEMPT_ENCRYPTION", shipper)
        self.assertNotIn("NVPN_TESTFLIGHT_APP_ENCRYPTION_DECLARATION_ID", shipper)
        self.assertNotIn("uses_nonexempt_encryption=False", shipper)
        self.assertIn("ensure_build_compliance(", shipper)

    @staticmethod
    def _build(value):
        return {
            "type": "builds",
            "id": "build-id",
            "attributes": {"usesNonExemptEncryption": value},
        }

    @staticmethod
    def _declaration(declaration_id, state="APPROVED", **overrides):
        attributes = {
            "usesEncryption": True,
            "exempt": False,
            "containsProprietaryCryptography": False,
            "containsThirdPartyCryptography": True,
            "availableOnFrenchStore": False,
            "appEncryptionDeclarationState": state,
        }
        attributes.update(overrides)
        return {
            "type": "appEncryptionDeclarations",
            "id": declaration_id,
            "attributes": attributes,
        }


if __name__ == "__main__":
    unittest.main()
