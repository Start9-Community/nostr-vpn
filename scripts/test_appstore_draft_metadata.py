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
    @staticmethod
    def _published_localization():
        return {
            "attributes": {
                "description": "published description",
                "keywords": "published,keywords",
                "promotionalText": "published promotional text",
                "supportUrl": "https://example.invalid/support",
                "whatsNew": "published release notes",
                "marketingUrl": "https://example.invalid/marketing",
            }
        }

    @staticmethod
    def _screenshot_set(display_type, resource_id):
        return {
            "type": "appScreenshotSets",
            "id": resource_id,
            "attributes": {"screenshotDisplayType": display_type},
        }

    @staticmethod
    def _screenshots(prefix, count=3, state="COMPLETE"):
        return [
            {
                "type": "appScreenshots",
                "id": f"{prefix}-{index}",
                "attributes": {
                    "fileName": f"{index:02d}.png",
                    "assetDeliveryState": {"state": state},
                },
            }
            for index in range(1, count + 1)
        ]

    def test_existing_complete_screenshot_sets_are_reused_without_mutation(self):
        sets = [
            self._screenshot_set("APP_IPHONE_67", "iphone-set"),
            self._screenshot_set("APP_IPAD_PRO_3GEN_129", "ipad-set"),
        ]
        screenshots = {
            "iphone-set": self._screenshots("iphone"),
            "ipad-set": self._screenshots("ipad"),
        }

        mode, reused = metadata.reconcile_appstore_screenshots(
            environ={},
            screenshot_sets=lambda: sets,
            screenshots_for_set=lambda set_id: screenshots[set_id],
            replace_screenshots=lambda: self.fail(
                "default screenshot reuse must perform zero mutation"
            ),
        )

        self.assertEqual(mode, "reused")
        self.assertEqual(len(reused), 6)

    def test_existing_screenshot_reuse_fails_closed_for_missing_set(self):
        sets = [self._screenshot_set("APP_IPHONE_67", "iphone-set")]

        with self.assertRaisesRegex(ValueError, "required screenshot sets"):
            metadata.reconcile_appstore_screenshots(
                environ={},
                screenshot_sets=lambda: sets,
                screenshots_for_set=lambda _set_id: self._screenshots("iphone"),
                replace_screenshots=lambda: self.fail(
                    "incomplete screenshots must not trigger replacement"
                ),
            )

    def test_existing_screenshot_reuse_fails_closed_for_incomplete_asset(self):
        sets = [
            self._screenshot_set("APP_IPHONE_67", "iphone-set"),
            self._screenshot_set("APP_IPAD_PRO_3GEN_129", "ipad-set"),
        ]
        screenshots = {
            "iphone-set": self._screenshots("iphone"),
            "ipad-set": self._screenshots("ipad", state="PROCESSING"),
        }

        with self.assertRaisesRegex(ValueError, "not COMPLETE"):
            metadata.reconcile_appstore_screenshots(
                environ={},
                screenshot_sets=lambda: sets,
                screenshots_for_set=lambda set_id: screenshots[set_id],
                replace_screenshots=lambda: self.fail(
                    "incomplete screenshots must not trigger replacement"
                ),
            )

    def test_existing_screenshot_reuse_requires_exact_asset_counts(self):
        sets = [
            self._screenshot_set("APP_IPHONE_67", "iphone-set"),
            self._screenshot_set("APP_IPAD_PRO_3GEN_129", "ipad-set"),
        ]
        screenshots = {
            "iphone-set": self._screenshots("iphone", count=2),
            "ipad-set": self._screenshots("ipad"),
        }

        with self.assertRaisesRegex(ValueError, "exactly 3 screenshots"):
            metadata.reconcile_appstore_screenshots(
                environ={},
                screenshot_sets=lambda: sets,
                screenshots_for_set=lambda set_id: screenshots[set_id],
                replace_screenshots=lambda: self.fail(
                    "wrong screenshot counts must not trigger replacement"
                ),
            )

    def test_screenshot_replacement_requires_explicit_opt_in_and_revalidation(self):
        sets = [
            self._screenshot_set("APP_IPHONE_67", "iphone-set"),
            self._screenshot_set("APP_IPAD_PRO_3GEN_129", "ipad-set"),
        ]
        screenshots = {
            "iphone-set": self._screenshots("iphone"),
            "ipad-set": self._screenshots("ipad"),
        }
        replacements = []

        mode, replaced = metadata.reconcile_appstore_screenshots(
            environ={"NVPN_APPSTORE_REPLACE_SCREENSHOTS": "1"},
            screenshot_sets=lambda: sets,
            screenshots_for_set=lambda set_id: screenshots[set_id],
            replace_screenshots=lambda: replacements.append(True),
        )

        self.assertEqual(replacements, [True])
        self.assertEqual(mode, "replaced")
        self.assertEqual(len(replaced), 6)

    def test_appstore_draft_wires_reuse_as_the_only_default_screenshot_path(self):
        draft = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            "screenshot_mode, screenshots = reconcile_screenshots(",
            draft,
        )
        self.assertIn(
            "replace_screenshots=lambda: upload_screenshots(localization_id)",
            draft,
        )
        self.assertEqual(draft.count("upload_screenshots("), 2)
        self.assertNotIn(
            "screenshots = upload_screenshots(localization[\"id\"])",
            draft,
        )

    def test_existing_public_metadata_is_reused_without_a_patch(self):
        existing = self._published_localization()

        attrs = metadata.version_localization_attributes(existing, environ={})

        self.assertEqual(attrs, existing["attributes"])
        self.assertEqual(
            metadata.version_localization_patch(existing, environ={}),
            {},
        )
        draft = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )
        self.assertIn("if not attrs:\n            return existing", draft)

    def test_explicit_overrides_replace_only_selected_existing_fields(self):
        existing = self._published_localization()

        patch = metadata.version_localization_patch(
            existing,
            environ={
                "NVPN_APPSTORE_DESCRIPTION": "replacement description",
                "NVPN_APPSTORE_WHATS_NEW": "replacement release notes",
            },
        )

        self.assertEqual(
            patch,
            {
                "description": "replacement description",
                "whatsNew": "replacement release notes",
            },
        )

    def test_missing_localization_uses_safe_repository_defaults(self):
        attrs = metadata.version_localization_attributes(None, environ={})

        self.assertEqual(attrs["description"], metadata.DEFAULT_DESCRIPTION)
        self.assertEqual(attrs["keywords"], metadata.DEFAULT_KEYWORDS)
        self.assertEqual(
            attrs["promotionalText"],
            metadata.DEFAULT_PROMOTIONAL_TEXT,
        )
        self.assertEqual(attrs["supportUrl"], metadata.DEFAULT_SUPPORT_URL)
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
        self.assertIn("ITSAppUsesNonExemptEncryption=false", notes)
        self.assertIn("export-exempt", notes)
        self.assertNotIn("approved French-store", notes)
        self.assertIn("distribution excludes France", notes)
        self.assertIn("including China", notes)
        self.assertNotIn("worldwide", notes.lower())
        self.assertIn("Turning Wi-Fi off and on restores the same Wi-Fi", notes)
        self.assertIn("turn Wi-Fi off and back on", notes)
        self.assertNotIn("change the network connection", notes)
        self.assertNotIn("cellular", notes)
        self.assertNotIn("personal hotspot", notes)
        self.assertIn("Cloudflare encrypted DNS as the Automatic fallback", notes)
        self.assertIn("Quad9", notes)
        self.assertIn("custom DoH", notes)
        self.assertIn("DNS configured through the exit", notes)
        self.assertIn("select Direct", notes)
        self.assertIn("signed roster containing its identity", notes)
        self.assertIn("Manual join", notes)

    def test_public_metadata_reuse_does_not_prevent_reviewer_note_refresh(self):
        existing = self._published_localization()
        existing["attributes"]["notes"] = "stale reviewer notes"

        self.assertEqual(
            metadata.version_localization_patch(existing, environ={}),
            {},
        )
        notes = metadata.review_notes("4.1.5", existing, environ={})
        self.assertIn("Nostr VPN 4.1.5", notes)
        self.assertNotIn("stale reviewer notes", notes)

    def test_override_allows_territory_policy_and_unrelated_purchase_copy(self):
        notes = (
            "The iOS target contains no wallet or paid-exit UI/runtime, "
            "purchase path, or external purchase link. "
            "It uses NEPacketTunnelProvider plus app-implemented WireGuard "
            "and encrypted FIPS/Nostr transport. Distribution excludes France "
            "and includes China; the distribution is export-exempt."
        )

        self.assertEqual(
            metadata.review_notes(
                "4.1.5",
                None,
                environ={"NVPN_APPSTORE_REVIEW_NOTES": notes},
            ),
            notes,
        )
        self.assertEqual(
            metadata.testflight_review_notes(
                "4.1.5",
                None,
                environ={"NVPN_TESTFLIGHT_REVIEW_NOTES": notes},
            ),
            notes,
        )

    def test_overrides_cannot_claim_broader_storefront_availability(self):
        prohibited = (
            "App Store availability is worldwide.",
            "App Store distribution is enabled in France and China.",
            "The app is available in France.",
        )
        for notes in prohibited:
            with self.subTest(notes=notes):
                for environment_name, renderer in (
                    ("NVPN_APPSTORE_REVIEW_NOTES", metadata.review_notes),
                    ("NVPN_TESTFLIGHT_REVIEW_NOTES", metadata.testflight_review_notes),
                ):
                    with self.subTest(environment_name=environment_name):
                        with self.assertRaisesRegex(
                            ValueError,
                            "availability",
                        ):
                            renderer(
                                "4.1.5",
                                None,
                                environ={environment_name: notes},
                            )

    def test_default_notes_state_export_exempt_no_france_policy(self):
        notes = metadata.review_notes("4.1.5", None, environ={})

        self.assertIn("standard WireGuard and Nostr/FIPS cryptography", notes)
        self.assertIn("ITSAppUsesNonExemptEncryption=false", notes)
        self.assertIn("Apple treats this distribution as export-exempt", notes)
        self.assertIn("distribution excludes France", notes)
        self.assertIn("including China", notes)
        self.assertIn("No app encryption declaration", notes)
        self.assertNotIn("approved French-store", notes)
        self.assertNotIn("non-exempt encryption", notes)

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
        self.assertIn("ITSAppUsesNonExemptEncryption=false", notes)
        self.assertIn("export-exempt", notes)
        self.assertNotIn("approved French-store", notes)
        self.assertIn("distribution excludes France", notes)
        self.assertNotIn("worldwide", notes.lower())

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
        compliance = shipper.index("build = ensure_export_compliance(build)")
        notes = shipper.index("ensure_public_metadata()", compliance)
        submit = shipper.rindex("submit_beta_review(build)")
        self.assertLess(compliance, notes)
        self.assertLess(notes, submit)
        self.assertNotIn("appEncryptionDeclaration", shipper)
        self.assertNotIn("French approval", shipper)
        self.assertNotIn('or attrs.get("notes")', shipper)

    def test_appstore_submission_prepares_compliance_before_notes_and_submit(self):
        shipper = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )

        compliance = shipper.index("build = ensure_build_export_exempt(")
        notes = shipper.index("review_detail = ensure_review_detail(", compliance)
        submit = shipper.rindex("submit_review_submission(")
        self.assertLess(compliance, notes)
        self.assertLess(notes, submit)
        self.assertNotIn("appEncryptionDeclaration", shipper)

    def test_support_page_exists_in_repo(self):
        support_page = ROOT / "docs" / "support" / "index.html"
        self.assertTrue(support_page.is_file())
        contents = support_page.read_text(encoding="utf-8")
        self.assertIn("Nostr VPN Support", contents)
        self.assertIn("mailto:", contents)

    def test_territory_policy_requires_france_off_and_every_other_row_on(self):
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
            availability.require_territory_policy(
                [germany, france, china]
            ),
            [germany, france, china],
        )
        with self.assertRaises(availability.AppStoreAvailabilityError):
            availability.require_territory_policy(
                [
                    {**france, "attributes": {"available": True}},
                    germany,
                    china,
                ]
            )
        with self.assertRaises(availability.AppStoreAvailabilityError):
            availability.require_territory_policy([])

    def test_territory_patch_encodes_required_state(self):
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
        self.assertIn('ensure_territory_policy(app["id"])', draft)
        self.assertIn("required_territory_availability(territory)", draft)
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
    @staticmethod
    def _build(value, *, build_id="build-id", version="4001007"):
        return {
            "type": "builds",
            "id": build_id,
            "attributes": {
                "version": version,
                "usesNonExemptEncryption": value,
            },
        }

    def test_update_request_marks_only_the_exact_build_export_exempt(self):
        self.assertEqual(
            export_compliance.export_exempt_build_update_request("build-id"),
            {
                "data": {
                    "type": "builds",
                    "id": "build-id",
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
        )

    def test_exact_exempt_build_is_read_back_without_mutation(self):
        calls = []
        logs = []
        result = export_compliance.ensure_build_export_exempt(
            self._build(False),
            request=lambda *args, **kwargs: calls.append((args, kwargs)),
            get_build=lambda build_id: self._build(
                False,
                build_id=build_id,
            ),
            log=logs.append,
        )

        self.assertFalse(result["attributes"]["usesNonExemptEncryption"])
        self.assertEqual(calls, [])
        self.assertIn("no app encryption declaration", logs[0])

    def test_non_exempt_or_unknown_build_is_patched_false_and_read_back(self):
        for initial in (None, True):
            with self.subTest(initial=initial):
                calls = []
                reads = [
                    self._build(initial),
                    self._build(False),
                ]

                def request(method, path, params=None, body=None):
                    calls.append((method, path, params, body))
                    return 200, {"data": self._build(False)}

                result = export_compliance.ensure_build_export_exempt(
                    self._build(initial),
                    request=request,
                    get_build=lambda _build_id: reads.pop(0),
                )

                self.assertFalse(
                    result["attributes"]["usesNonExemptEncryption"]
                )
                self.assertEqual(
                    calls,
                    [
                        (
                            "PATCH",
                            "builds/build-id",
                            None,
                            export_compliance.export_exempt_build_update_request(
                                "build-id"
                            ),
                        )
                    ],
                )

    def test_export_exempt_readback_fails_closed(self):
        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "wrong exact build",
        ):
            export_compliance.ensure_build_export_exempt(
                self._build(False),
                request=lambda *_args, **_kwargs: self.fail(
                    "wrong build must not be patched"
                ),
                get_build=lambda _build_id: self._build(
                    False,
                    build_id="wrong-build",
                ),
            )

        reads = [self._build(True), self._build(True)]
        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "did not retain",
        ):
            export_compliance.ensure_build_export_exempt(
                self._build(True),
                request=lambda *_args, **_kwargs: (200, {}),
                get_build=lambda _build_id: reads.pop(0),
            )

    def test_exact_build_selector_never_falls_back(self):
        wrong = self._build(False, version="4001006")
        exact = self._build(False)
        self.assertIsNone(
            export_compliance.select_exact_build([wrong], "4001007")
        )
        self.assertIs(
            export_compliance.select_exact_build([wrong, exact], "4001007"),
            exact,
        )
        duplicate = self._build(False, build_id="duplicate")
        with self.assertRaisesRegex(
            export_compliance.ExportComplianceError,
            "multiple exact builds",
        ):
            export_compliance.select_exact_build(
                [exact, duplicate],
                "4001007",
            )

    def test_live_marketing_version_selects_one_exact_build(self):
        older = self._build(False, build_id="older")
        exact = self._build(False, build_id="exact")
        versions = {"older": "4.1.4", "exact": "4.1.5"}

        selected = (
            export_compliance.select_unique_build_for_marketing_version(
                [older, exact],
                "4001007",
                "4.1.5",
                versions.get,
            )
        )

        self.assertEqual(selected["id"], "exact")
        self.assertEqual(selected["_nvpnMarketingVersion"], "4.1.5")

    def test_exact_app_selector_never_falls_back(self):
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
                [wrong],
                "fi.siriusbusiness.nvpn",
            )
        )
        self.assertIs(
            export_compliance.select_exact_app(
                [wrong, exact],
                "fi.siriusbusiness.nvpn",
            ),
            exact,
        )

    def test_automation_contains_no_french_declaration_path(self):
        compliance = (
            ROOT / "scripts" / "testflight_export_compliance.py"
        ).read_text(encoding="utf-8")
        app_store = (ROOT / "scripts" / "appstore-draft").read_text(
            encoding="utf-8"
        )
        testflight = (ROOT / "scripts" / "testflight-internal").read_text(
            encoding="utf-8"
        )

        for contents in (compliance, app_store, testflight):
            self.assertNotIn("appEncryptionDeclarations", contents)
            self.assertNotIn("availableOnFrenchStore", contents)
            self.assertNotIn("FrenchDeclarationNotApproved", contents)
            self.assertNotIn(
                "prepare_build_compliance_for_submission",
                contents,
            )
        self.assertIn("ensure_build_export_exempt(", app_store)
        self.assertIn("ensure_build_export_exempt(", testflight)


if __name__ == "__main__":
    unittest.main()
