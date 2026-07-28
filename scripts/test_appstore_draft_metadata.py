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
        self.assertNotIn("Cashu", attrs["description"])
        self.assertNotIn("paid", attrs["description"].lower())

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
        self.assertNotIn(
            "approved French-store encryption declaration is attached",
            notes,
        )
        self.assertIn("available worldwide", notes)
        self.assertIn("including France and China", notes)
        self.assertIn("Switching between Wi-Fi, cellular, or a personal hotspot", notes)
        self.assertIn("Cloudflare encrypted DNS as the Automatic fallback", notes)
        self.assertIn("Quad9", notes)
        self.assertIn("custom DoH", notes)
        self.assertIn("DNS configured through the exit", notes)
        self.assertIn("select Direct", notes)
        self.assertIn("signed roster containing its identity", notes)
        self.assertIn("Manual join", notes)

    def test_reviewer_notes_claim_french_attachment_only_with_live_build_proof(self):
        proof = export_compliance.VerifiedBuildCompliance(
            build={
                "type": "builds",
                "id": "build-id",
                "attributes": {"usesNonExemptEncryption": True},
            },
            build_id="build-id",
            declaration_id="declaration-id",
        )

        notes = metadata.review_notes(
            "4.1.5",
            None,
            environ={},
            encryption_compliance=proof,
        )

        self.assertIn(
            "approved French-store encryption declaration is attached",
            notes,
        )

    def test_unproved_override_cannot_claim_french_approval_or_attachment(self):
        for claim in (
            "The French-store encryption declaration is approved.",
            "The French-store encryption declaration is attached.",
            "The French-store encryption declaration is linked.",
            "The encryption declaration is approved.",
            "French export-compliance approval is attached.",
            (
                "The French encryption declaration is available. "
                "It is approved and attached."
            ),
            (
                "The encryption declaration was filed. "
                "Apple approved it."
            ),
        ):
            with self.subTest(claim=claim):
                with self.assertRaisesRegex(ValueError, "verified live build"):
                    metadata.review_notes(
                        "4.1.5",
                        None,
                        environ={"NVPN_APPSTORE_REVIEW_NOTES": claim},
                    )

    def test_boolean_cannot_stand_in_for_live_build_compliance_proof(self):
        with self.assertRaisesRegex(ValueError, "live build compliance proof"):
            metadata.review_notes(
                "4.1.5",
                None,
                environ={},
                encryption_compliance=True,
            )

    def test_review_submission_allows_truthful_unapproved_france_state(self):
        for action in (
            "submit",
            "public",
            "public-submit",
            "put",
            "attach",
            "status",
            "public-attach",
        ):
            with self.subTest(action=action):
                metadata.require_review_submission_encryption_compliance(
                    action,
                    None,
                )
        with self.assertRaisesRegex(ValueError, "verified exact-build proof"):
            metadata.require_review_submission_encryption_compliance(
                "submit",
                True,
            )

    def test_reviewer_notes_include_private_ready_to_use_wireguard_fixture(self):
        notes = metadata.review_notes(
            "4.1.5",
            None,
            environ={
                "NVPN_APPSTORE_REVIEW_WIREGUARD_CONFIG": (
                    "[Interface]\nAddress = 192.0.2.2/32\n"
                    "[Peer]\nEndpoint = reviewer.example:51820"
                )
            },
        )

        self.assertIn("Ready-to-use reviewer WireGuard configuration", notes)
        self.assertIn("Endpoint = reviewer.example:51820", notes)

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

        self.assertEqual(notes, metadata.default_review_notes("4.1.4", environ={}))
        self.assertNotIn("stale TestFlight review notes", notes)
        self.assertIn("without those feature dependencies or runtime workers", notes)
        self.assertIn("no wallet or paid-exit UI/action path", notes)
        self.assertIn("no paid VPN purchase, use, or sale", notes)
        self.assertIn("VPN Data Use disclosure", notes)
        self.assertIn("non-exempt encryption", notes)
        self.assertNotIn(
            "approved French-store encryption declaration is attached",
            notes,
        )
        self.assertIn("available worldwide", notes)
        self.assertNotIn("excluded from availability", notes)

    def test_explicit_testflight_notes_override_repo_default(self):
        notes = metadata.testflight_review_notes(
            "4.1.4",
            {"notes": "stale TestFlight review notes"},
            environ={"NVPN_TESTFLIGHT_REVIEW_NOTES": "deliberate beta override"},
        )

        self.assertEqual(notes, "deliberate beta override")

    def test_external_testflight_review_requires_fixture_or_complete_override(self):
        for action in ("public", "public-submit"):
            with self.subTest(action=action):
                with self.assertRaisesRegex(
                    ValueError,
                    "WireGuard configuration or complete override notes",
                ):
                    metadata.require_testflight_external_review_material(
                        action,
                        environ={},
                    )

                metadata.require_testflight_external_review_material(
                    action,
                    environ={
                        "NVPN_APPSTORE_REVIEW_WIREGUARD_CONFIG": (
                            "[Interface]\nAddress = 192.0.2.2/32"
                        )
                    },
                )
                metadata.require_testflight_external_review_material(
                    action,
                    environ={
                        "NVPN_TESTFLIGHT_REVIEW_NOTES": (
                            "Complete private reviewer setup and test steps"
                        )
                    },
                )

    def test_non_review_testflight_actions_do_not_require_reviewer_fixture(self):
        for action in (
            "put",
            "attach",
            "wait",
            "status",
            "public-attach",
            "public-status",
        ):
            with self.subTest(action=action):
                metadata.require_testflight_external_review_material(
                    action,
                    environ={},
                )

    def test_testflight_shipper_uses_authoritative_notes_helper(self):
        shipper = (ROOT / "scripts" / "testflight-internal").read_text(
            encoding="utf-8"
        )

        self.assertIn("testflight_review_notes(", shipper)
        self.assertIn("require_testflight_external_review_material(", shipper)
        self.assertIn(
            "select_unique_build_for_marketing_version(",
            shipper,
        )
        self.assertIn("builds/{build_id}/preReleaseVersion", shipper)
        self.assertIn('"version": live_marketing_version', shipper)
        self.assertNotIn('"version": VERSION_NAME,', shipper)
        proof = shipper.index("encryption_compliance = ensure_export_compliance(build)")
        gate = shipper.index(
            "require_review_submission_encryption_compliance(",
            proof,
        )
        submit = shipper.rindex("submit_beta_review(build)")
        self.assertLess(proof, gate)
        self.assertLess(gate, submit)
        self.assertNotIn('or attrs.get("notes")', shipper)

    def test_appstore_submission_prepares_compliance_before_notes_and_submit(self):
        shipper = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )

        proof = shipper.index(
            "build, encryption_compliance = "
            "prepare_build_compliance_for_submission("
        )
        gate = shipper.index(
            "require_review_submission_encryption_compliance(",
            proof,
        )
        notes = shipper.index("review_detail = ensure_review_detail(", gate)
        submit = shipper.rindex("submit_review_submission(")
        self.assertLess(proof, gate)
        self.assertLess(gate, notes)
        self.assertLess(notes, submit)

    def test_support_page_exists_in_repo(self):
        support_page = ROOT / "docs" / "support" / "index.html"
        self.assertTrue(support_page.is_file())
        contents = support_page.read_text(encoding="utf-8")
        self.assertIn("Nostr VPN Support", contents)
        self.assertIn("mailto:", contents)

    def test_worldwide_availability_requires_every_returned_territory(self):
        france = {
            "type": "territoryAvailabilities",
            "id": "france-row",
            "attributes": {"available": True},
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
        china = {
            "type": "territoryAvailabilities",
            "id": "china-row",
            "attributes": {"available": True},
            "relationships": {
                "territory": {
                    "data": {"type": "territories", "id": "CHN"},
                }
            },
        }
        self.assertEqual(
            availability.require_worldwide_availability(
                [germany, france, china]
            ),
            [germany, france, china],
        )
        with self.assertRaises(availability.AppStoreAvailabilityError):
            availability.require_worldwide_availability(
                [
                    {**france, "attributes": {"available": False}},
                    germany,
                    china,
                ]
            )
        with self.assertRaises(availability.AppStoreAvailabilityError):
            availability.require_worldwide_availability([])

    def test_worldwide_patch_enables_the_territory_resource(self):
        self.assertEqual(
            availability.territory_update_request(
                "france-row",
                available=True,
            ),
            {
                "data": {
                    "type": "territoryAvailabilities",
                    "id": "france-row",
                    "attributes": {"available": True},
                }
            },
        )
        draft = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )
        self.assertIn('ensure_worldwide_availability(app["id"])', draft)
        self.assertNotIn("REQUIRED_EXCLUDED_TERRITORIES", draft)
        self.assertNotIn("require_territory_excluded", draft)
        self.assertIn("territoryAvailabilities/", draft)

    def test_enabled_eu_territories_reject_every_dsa_trader_error(self):
        for trader_error in availability.DSA_TRADER_CONTENT_ERRORS:
            with self.subTest(trader_error=trader_error):
                row = self._territory_availability(
                    "FIN",
                    available=True,
                    content_statuses=["AVAILABLE", trader_error],
                )
                with self.assertRaisesRegex(
                    availability.AppStoreAvailabilityError,
                    rf"FIN.*{trader_error}",
                ):
                    availability.require_no_eu_trader_status_errors([row])

    def test_dsa_gate_checks_only_enabled_eu_territories(self):
        clean = self._territory_availability(
            "IRL",
            available=True,
            content_statuses=["AVAILABLE"],
        )
        disabled_eu = self._territory_availability(
            "FRA",
            available=False,
            content_statuses=["TRADER_STATUS_NOT_PROVIDED"],
        )
        enabled_non_eu = self._territory_availability(
            "USA",
            available=True,
            content_statuses=["TRADER_STATUS_VERIFICATION_FAILED"],
        )

        self.assertEqual(
            availability.require_no_eu_trader_status_errors(
                [clean, disabled_eu, enabled_non_eu]
            ),
            [clean, disabled_eu, enabled_non_eu],
        )

    def test_dsa_gate_fails_closed_on_missing_or_malformed_content_statuses(self):
        for content_statuses in (None, "AVAILABLE", {"status": "AVAILABLE"}):
            with self.subTest(content_statuses=content_statuses):
                row = self._territory_availability(
                    "DEU",
                    available=True,
                    content_statuses=content_statuses,
                )
                if content_statuses is None:
                    row["attributes"].pop("contentStatuses")
                with self.assertRaisesRegex(
                    availability.AppStoreAvailabilityError,
                    "DEU.*contentStatuses",
                ):
                    availability.require_no_eu_trader_status_errors([row])

    def test_dsa_gate_fails_closed_when_eu_availability_is_not_boolean(self):
        for available_value in (None, 1, "true"):
            with self.subTest(available_value=available_value):
                row = self._territory_availability(
                    "DEU",
                    available=available_value,
                    content_statuses=["AVAILABLE"],
                )
                with self.assertRaisesRegex(
                    availability.AppStoreAvailabilityError,
                    "DEU.*boolean available",
                ):
                    availability.require_no_eu_trader_status_errors([row])

    def test_appstore_draft_requests_and_enforces_dsa_content_statuses(self):
        draft = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            '"available%2CcontentStatuses%2Cterritory"',
            draft,
        )
        self.assertIn(
            "return require_no_eu_trader_status_errors(",
            draft,
        )

    @staticmethod
    def _territory_availability(
        territory_id,
        *,
        available,
        content_statuses,
    ):
        return {
            "type": "territoryAvailabilities",
            "id": f"{territory_id.lower()}-row",
            "attributes": {
                "available": available,
                "contentStatuses": content_statuses,
            },
            "relationships": {
                "territory": {
                    "data": {
                        "type": "territories",
                        "id": territory_id,
                    }
                }
            },
        }


class TestFlightExportComplianceTests(unittest.TestCase):
    def test_declaration_answers_standard_app_crypto_for_french_store(self):
        body = export_compliance.declaration_create_request("app-id")

        self.assertEqual(
            body,
            {
                "data": {
                    "type": "appEncryptionDeclarations",
                    "attributes": {
                        "appDescription": export_compliance.APP_DESCRIPTION,
                        "availableOnFrenchStore": True,
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
        in_review = self._declaration("in-review", state="IN_REVIEW")
        unknown = self._declaration("unknown", state="")
        approved = self._declaration("approved", state="APPROVED")

        selected = export_compliance.select_reusable_declaration(
            [rejected, created, in_review, unknown, approved]
        )

        self.assertEqual(selected["id"], "approved")
        for unapproved in (rejected, created, in_review, unknown):
            self.assertFalse(export_compliance.declaration_matches_policy(unapproved))

    def test_does_not_reuse_wrong_french_store_or_crypto_answers(self):
        not_french_store = self._declaration(
            "not-french-store",
            availableOnFrenchStore=False,
        )
        proprietary = self._declaration(
            "proprietary", containsProprietaryCryptography=True
        )
        apple_only = self._declaration(
            "apple-only", containsThirdPartyCryptography=False
        )
        exempt = self._declaration("exempt", exempt=True)

        self.assertIsNone(
            export_compliance.select_reusable_declaration(
                [not_french_store, proprietary, apple_only, exempt]
            )
        )

    def test_policy_match_requires_every_exact_answer(self):
        valid = self._declaration("valid")
        self.assertTrue(export_compliance.declaration_answers_policy(valid))
        self.assertIn("VPN", export_compliance.APP_DESCRIPTION)
        self.assertIn("mesh networking", export_compliance.APP_DESCRIPTION)
        self.assertIn(
            "encrypted networking and control transport",
            export_compliance.APP_DESCRIPTION,
        )

        wrong_answers = (
            {"appDescription": "A different app or release"},
            {"usesEncryption": False},
            {"exempt": True},
            {"availableOnFrenchStore": False},
            {"platform": "MAC_OS"},
            {"platform": "ios"},
        )
        for overrides in wrong_answers:
            with self.subTest(overrides=overrides):
                self.assertFalse(
                    export_compliance.declaration_answers_policy(
                        self._declaration("wrong", **overrides)
                    )
                )

        for missing_field in (
            "appDescription",
            "usesEncryption",
            "exempt",
            "platform",
        ):
            with self.subTest(missing_field=missing_field):
                incomplete = self._declaration("incomplete")
                del incomplete["attributes"][missing_field]
                self.assertFalse(
                    export_compliance.declaration_answers_policy(incomplete)
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
            self._build(False),
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
            self._build(False),
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

    def test_ensure_does_not_duplicate_or_link_pending_declaration(self):
        calls = []
        pending = self._declaration("pending", state="IN_REVIEW")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            if method == "GET":
                return 404, {"errors": []}
            raise AssertionError((method, path))

        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "not approved.*IN_REVIEW",
        ):
            export_compliance.ensure_build_compliance(
                self._build(False),
                app_id="app-id",
                request=request,
                get_all=lambda _path, _params=None: [pending],
                get_build=lambda _build_id: self._build(True),
            )

        self.assertFalse(any(call[0] in {"POST", "PATCH"} for call in calls))

    def test_created_terminal_or_unknown_declaration_cannot_submit(self):
        for state in ("REJECTED", "EXPIRED", "INVALID", "UNKNOWN"):
            with self.subTest(state=state):
                calls = []
                created = self._declaration("created", state=state)

                def request(method, path, params=None, body=None):
                    calls.append((method, path, params, body))
                    if method == "GET":
                        return 404, {"errors": []}
                    if method == "POST":
                        return 201, {"data": created}
                    raise AssertionError((method, path))

                with self.assertRaises(
                    export_compliance.ExportComplianceError
                ) as raised:
                    export_compliance.prepare_build_compliance_for_submission(
                        self._build(False),
                        app_id="app-id",
                        request=request,
                        get_all=lambda _path, _params=None: [],
                        get_build=lambda _build_id: self._build(False),
                    )

                self.assertNotIsInstance(
                    raised.exception,
                    export_compliance.FrenchDeclarationNotApproved,
                )
                self.assertFalse(any(call[0] == "PATCH" for call in calls))

    def test_created_pending_declaration_requires_resource_id(self):
        for declaration_id in ("", 123):
            with self.subTest(declaration_id=declaration_id):
                created = self._declaration(
                    declaration_id, state="IN_REVIEW"
                )
                calls = []

                def request(method, path, params=None, body=None):
                    calls.append((method, path, params, body))
                    if method == "GET":
                        return 404, {"errors": []}
                    if method == "POST":
                        return 201, {"data": created}
                    raise AssertionError((method, path))

                with self.assertRaisesRegex(
                    export_compliance.ExportComplianceError,
                    "no ID",
                ) as raised:
                    export_compliance.prepare_build_compliance_for_submission(
                        self._build(False),
                        app_id="app-id",
                        request=request,
                        get_all=lambda _path, _params=None: [],
                        get_build=lambda _build_id: self._build(False),
                    )

                self.assertNotIsInstance(
                    raised.exception,
                    export_compliance.FrenchDeclarationNotApproved,
                )
                self.assertFalse(
                    any(call[0] == "PATCH" for call in calls)
                )

    def test_malformed_link_relationship_fails_closed(self):
        calls = []

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            return 200, {"data": None}

        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "malformed",
        ):
            export_compliance.prepare_build_compliance_for_submission(
                self._build(False),
                app_id="app-id",
                request=request,
                get_all=lambda *_args, **_kwargs: self.fail(
                    "malformed relationship must not list declarations"
                ),
                get_build=lambda _build_id: self._build(True),
            )

    def test_mismatched_exact_build_link_cannot_use_separate_pending_proof(self):
        calls = []
        wrong = self._declaration(
            "wrong",
            state="APPROVED",
            appDescription="different product",
        )
        pending = self._declaration("pending", state="IN_REVIEW")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            return 200, {"data": wrong}

        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "mismatched",
        ):
            export_compliance.prepare_build_compliance_for_submission(
                self._build(False),
                app_id="app-id",
                request=request,
                get_all=lambda _path, _params=None: [pending],
                get_build=lambda _build_id: self._build(True),
            )

        self.assertFalse(any(call[0] in {"POST", "PATCH"} for call in calls))

    def test_approved_path_rejects_exact_build_id_substitution(self):
        approved = self._declaration("approved", state="APPROVED")

        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "exact build",
        ):
            export_compliance.prepare_build_compliance_for_submission(
                self._build(False) | {"id": "build-a"},
                app_id="app-id",
                request=lambda *_args, **_kwargs: (
                    200,
                    {"data": approved},
                ),
                get_all=lambda *_args, **_kwargs: [],
                get_build=lambda _build_id: (
                    self._build(True) | {"id": "build-b"}
                ),
            )

    def test_exact_linked_pending_declaration_is_not_duplicated(self):
        calls = []
        pending = self._declaration("pending", state="IN_REVIEW")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            if method == "GET":
                return 200, {"data": pending}
            raise AssertionError((method, path))

        build, proof = (
            export_compliance.prepare_build_compliance_for_submission(
                self._build(False),
                app_id="app-id",
                request=request,
                get_all=lambda *_args, **_kwargs: self.fail(
                    "exact linked pending declaration must not be relisted"
                ),
                get_build=lambda _build_id: self._build(True),
            )
        )

        self.assertIsNone(proof)
        self.assertTrue(build["attributes"]["usesNonExemptEncryption"])
        self.assertEqual([call[0] for call in calls], ["GET"])

    def test_exact_build_selector_never_falls_back_to_another_build(self):
        wrong = self._build(True)
        wrong["attributes"]["version"] = "4001006"
        self.assertIsNone(
            export_compliance.select_exact_build([wrong], "4001007")
        )
        exact = self._build(True)
        exact["attributes"]["version"] = "4001007"
        self.assertIs(
            export_compliance.select_exact_build([wrong, exact], "4001007"),
            exact,
        )
        malformed = dict(exact)
        malformed.pop("type")
        self.assertIsNone(
            export_compliance.select_exact_build([malformed], "4001007")
        )
        duplicate = dict(exact)
        duplicate["id"] = "duplicate-build"
        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "multiple exact builds",
        ):
            export_compliance.select_exact_build(
                [exact, duplicate],
                "4001007",
            )

    def test_live_marketing_version_selects_one_exact_build(self):
        older = self._build(True)
        older["id"] = "older-build"
        older["attributes"]["version"] = "4001007"
        exact = self._build(True)
        exact["id"] = "exact-build"
        exact["attributes"]["version"] = "4001007"
        live_versions = {
            "older-build": "4.1.4",
            "exact-build": "4.1.5",
        }

        selected = (
            export_compliance.select_unique_build_for_marketing_version(
                [older, exact],
                "4001007",
                "4.1.5",
                lambda build_id: live_versions[build_id],
            )
        )

        self.assertEqual(selected["id"], "exact-build")
        self.assertEqual(selected["_nvpnMarketingVersion"], "4.1.5")
        self.assertIsNone(
            export_compliance.select_unique_build_for_marketing_version(
                [older],
                "4001007",
                "4.1.5",
                lambda build_id: live_versions[build_id],
            )
        )
        duplicate = dict(exact)
        duplicate["id"] = "duplicate-build"
        live_versions["duplicate-build"] = "4.1.5"
        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "multiple exact builds",
        ):
            export_compliance.select_unique_build_for_marketing_version(
                [exact, duplicate],
                "4001007",
                "4.1.5",
                lambda build_id: live_versions[build_id],
            )
        malformed = dict(exact)
        malformed["id"] = 123
        self.assertIsNone(
            export_compliance.select_exact_build([malformed], "4001007")
        )

    def test_exact_app_selector_never_falls_back_or_accepts_numeric_id(self):
        exact = {
            "type": "apps",
            "id": "app-id",
            "attributes": {"bundleId": "fi.siriusbusiness.nvpn"},
        }
        wrong = {
            "type": "apps",
            "id": "wrong-app",
            "attributes": {"bundleId": "example.wrong"},
        }

        self.assertIsNone(
            export_compliance.select_exact_app(
                [wrong], "fi.siriusbusiness.nvpn"
            )
        )
        self.assertIs(
            export_compliance.select_exact_app(
                [wrong, exact], "fi.siriusbusiness.nvpn"
            ),
            exact,
        )
        malformed = dict(exact)
        malformed["id"] = 123
        self.assertIsNone(
            export_compliance.select_exact_app(
                [malformed], "fi.siriusbusiness.nvpn"
            )
        )
        duplicate = dict(exact)
        duplicate["id"] = "duplicate-app"
        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "multiple exact apps",
        ):
            export_compliance.select_exact_app(
                [exact, duplicate],
                "fi.siriusbusiness.nvpn",
            )

    def test_compliance_rejects_build_resource_without_jsonapi_type(self):
        malformed = self._build(True)
        malformed.pop("type")
        approved = self._declaration("approved", state="APPROVED")

        with self.assertRaises(export_compliance.ExportComplianceError):
            export_compliance.prepare_build_compliance_for_submission(
                malformed,
                app_id="app-id",
                request=lambda *_args, **_kwargs: (
                    200,
                    {"data": approved},
                ),
                get_all=lambda *_args, **_kwargs: [],
                get_build=lambda _build_id: malformed,
            )
        with self.assertRaises(ValueError):
            export_compliance.VerifiedBuildCompliance(
                build=malformed,
                build_id="build-id",
                declaration_id="approved",
            )

    def test_submission_preparation_keeps_france_enabled_while_pending(self):
        calls = []
        pending = self._declaration("pending", state="IN_REVIEW")
        build_reads = [
            self._build(False),
            self._build(False),
            self._build(True),
        ]

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            if method == "GET" and path.endswith("/appEncryptionDeclaration"):
                return 404, {"errors": []}
            if method == "PATCH" and path == "builds/build-id":
                return 200, {"data": self._build(True)}
            raise AssertionError((method, path))

        build, proof = (
            export_compliance.prepare_build_compliance_for_submission(
                self._build(False),
                app_id="app-id",
                request=request,
                get_all=lambda _path, _params=None: [pending],
                get_build=lambda _build_id: build_reads.pop(0),
            )
        )

        self.assertIsNone(proof)
        self.assertTrue(build["attributes"]["usesNonExemptEncryption"])
        self.assertEqual(
            [call for call in calls if call[0] == "PATCH"][0][3],
            export_compliance.non_exempt_build_update_request("build-id"),
        )
        self.assertFalse(any(call[0] == "POST" for call in calls))

    def test_ensure_treats_only_created_and_in_review_as_pending(self):
        for state in ("CREATED", "IN_REVIEW"):
            with self.subTest(state=state):
                calls = []
                pending = self._declaration("pending", state=state)

                def request(method, path, params=None, body=None):
                    calls.append((method, path, params, body))
                    if method == "GET":
                        return 404, {"errors": []}
                    raise AssertionError((method, path))

                with self.assertRaisesRegex(
                    export_compliance.ExportComplianceError,
                    f"not approved.*{state}",
                ):
                    export_compliance.ensure_build_compliance(
                        self._build(False),
                        app_id="app-id",
                        request=request,
                        get_all=lambda _path, _params=None: [pending],
                        get_build=lambda _build_id: self._build(True),
                    )

                self.assertFalse(
                    any(call[0] in {"POST", "PATCH"} for call in calls)
                )

    def test_ensure_replaces_terminal_declarations_instead_of_treating_them_pending(self):
        for state in ("REJECTED", "EXPIRED", "INVALID"):
            with self.subTest(state=state):
                calls = []
                builds = [self._build(True), self._build(True)]
                terminal = self._declaration("terminal", state=state)
                approved = self._declaration("replacement", state="APPROVED")

                def request(method, path, params=None, body=None):
                    calls.append((method, path, params, body))
                    if method == "GET":
                        get_count = len(
                            [call for call in calls if call[0] == "GET"]
                        )
                        if get_count == 1:
                            return 404, {"errors": []}
                        return 200, {"data": approved}
                    if method == "POST":
                        return 201, {"data": approved}
                    if method == "PATCH":
                        return 200, {"data": self._build(True)}
                    raise AssertionError((method, path))

                result = export_compliance.ensure_build_compliance(
                    self._build(False),
                    app_id="app-id",
                    request=request,
                    get_all=lambda _path, _params=None: [terminal],
                    get_build=lambda _build_id: builds.pop(0),
                )

                self.assertTrue(
                    result["attributes"]["usesNonExemptEncryption"]
                )
                self.assertEqual(
                    [call[0] for call in calls].count("POST"),
                    1,
                )
                self.assertEqual(
                    [call[0] for call in calls].count("PATCH"),
                    1,
                )

    def test_ensure_is_noop_when_truthful_declaration_is_already_linked(self):
        calls = []
        declaration = self._declaration("linked", state="APPROVED")

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            return 200, {"data": declaration}

        result = export_compliance.ensure_build_compliance(
            self._build(False),
            app_id="app-id",
            request=request,
            get_all=lambda *_args, **_kwargs: self.fail(
                "should not list declarations"
            ),
            get_build=lambda _build_id: self._build(True),
        )

        self.assertTrue(result["attributes"]["usesNonExemptEncryption"])
        self.assertEqual([call[0] for call in calls], ["GET"])

    def test_live_verifier_proves_exact_build_and_approved_link(self):
        declaration = self._declaration("linked", state="APPROVED")
        calls = []

        def request(method, path, params=None, body=None):
            calls.append((method, path, params, body))
            return 200, {"data": declaration}

        proof = export_compliance.verify_build_compliance(
            "build-id",
            request=request,
            get_build=lambda build_id: self._build(True) | {"id": build_id},
        )

        self.assertEqual(proof.build_id, "build-id")
        self.assertEqual(proof.declaration_id, "linked")
        self.assertEqual(proof.build["id"], "build-id")
        self.assertEqual(
            [call[1] for call in calls],
            ["builds/build-id/appEncryptionDeclaration"],
        )

    def test_live_verifier_rejects_unapproved_or_unlinked_build(self):
        for uses_non_exempt, state in (
            (False, "APPROVED"),
            (True, "IN_REVIEW"),
        ):
            with self.subTest(
                uses_non_exempt=uses_non_exempt,
                state=state,
            ):
                with self.assertRaises(export_compliance.ExportComplianceError):
                    export_compliance.verify_build_compliance(
                        "build-id",
                        request=lambda *_args, **_kwargs: (
                            200,
                            {"data": self._declaration("linked", state=state)},
                        ),
                        get_build=lambda build_id: (
                            self._build(uses_non_exempt) | {"id": build_id}
                        ),
                    )

    def test_shipper_has_no_false_or_manual_id_policy(self):
        shipper = (ROOT / "scripts" / "testflight-internal").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("NVPN_TESTFLIGHT_USES_NONEXEMPT_ENCRYPTION", shipper)
        self.assertNotIn("NVPN_TESTFLIGHT_APP_ENCRYPTION_DECLARATION_ID", shipper)
        self.assertNotIn("uses_nonexempt_encryption=False", shipper)
        self.assertIn("prepare_build_compliance_for_submission(", shipper)

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
            "appDescription": export_compliance.APP_DESCRIPTION,
            "usesEncryption": True,
            "exempt": False,
            "containsProprietaryCryptography": False,
            "containsThirdPartyCryptography": True,
            "availableOnFrenchStore": True,
            "platform": "IOS",
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
