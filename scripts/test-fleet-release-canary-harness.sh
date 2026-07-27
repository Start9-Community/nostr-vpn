#!/usr/bin/env bash
# Adversarial contract harness for the post-gate fleet orchestrator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHESTRATOR="$ROOT/scripts/fleet_release_canary.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-fleet-canary.XXXXXX")"
APP="$WORK/app"
FIPS="$WORK/fips"
DRIVER="$APP/scripts/fleet_release_canary_ssh_driver.py"
LINUX_HELPER="$APP/scripts/fleet_release_canary_remote_linux.py"
WINDOWS_HELPER="$APP/scripts/fleet_release_canary_remote_windows.ps1"
GATE_VALIDATOR="$APP/scripts/fleet-release-gate-evidence.mjs"
PROVENANCE_LIB="$APP/scripts/release-artifact-provenance-lib.mjs"
DRIVER_LOG="$WORK/driver.log"
LOCAL_ID="$(
  PYTHONPATH="$ROOT/scripts" python3 - <<'PY'
from fleet_release_canary import local_machine_identity_sha256

print(local_machine_identity_sha256())
PY
)"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "fleet release canary harness failed: $*" >&2
  exit 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

json_status_is() {
  local path="$1" target="$2" expected="$3"
  python3 - "$path" "$target" "$expected" <<'PY'
import json
import sys

path, target, expected = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
matches = [row for row in value["targets"] if row["id"] == target]
if len(matches) != 1 or matches[0]["status"] != expected:
    raise SystemExit(f"{target} status was {matches!r}, expected {expected!r}")
PY
}

json_field_is() {
  local path="$1" field="$2" expected="$3"
  python3 - "$path" "$field" "$expected" <<'PY'
import json
import sys

path, field, expected = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
if value.get(field) != expected:
    raise SystemExit(
        f"{path} {field} was {value.get(field)!r}, expected {expected!r}"
    )
PY
}

json_target_evidence_is() {
  local path="$1" target="$2"
  shift 2
  python3 - "$path" "$target" "$@" <<'PY'
import hashlib
import json
import pathlib
import sys

path, target, *expected = sys.argv[1:]
value = json.load(open(path, encoding="utf-8"))
matches = [row for row in value["targets"] if row["id"] == target]
if len(matches) != 1:
    raise SystemExit(f"{target} result row was not unique")
evidence = matches[0].get("evidence")
if not isinstance(evidence, dict) or set(evidence) != set(expected):
    raise SystemExit(
        f"{target} evidence keys were {sorted((evidence or {}).keys())}, "
        f"expected {sorted(expected)}"
    )
paths = set()
receipts = set()
for action in expected:
    binding = evidence[action]
    if set(binding) != {"path", "sha256", "size"}:
        raise SystemExit(f"{target} {action} binding has extra/missing fields")
    raw = pathlib.Path(binding["path"])
    body = raw.read_bytes()
    observed = (hashlib.sha256(body).hexdigest(), len(body))
    claimed = (binding["sha256"], binding["size"])
    if observed != claimed:
        raise SystemExit(f"{target} {action} binding does not match raw bytes")
    if str(raw) in paths or claimed in receipts:
        raise SystemExit(f"{target} has a duplicate raw receipt binding")
    paths.add(str(raw))
    receipts.add(claimed)
PY
}

json_target_install_transition_is() {
  local path="$1" target="$2" expected="$3"
  python3 - "$path" "$target" "$expected" <<'PY'
import json
import pathlib
import sys

path, target, expected = sys.argv[1:]
value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
matches = [row for row in value["targets"] if row["id"] == target]
if len(matches) != 1:
    raise SystemExit(f"{target} result row was not unique")
raw_path = pathlib.Path(matches[0]["evidence"]["install"]["path"])
raw = json.loads(raw_path.read_text(encoding="utf-8"))
observed = raw["service"].get("installTransition")
if observed != expected:
    raise SystemExit(
        f"{target} transition was {observed!r}, expected {expected!r}"
    )
PY
}

write_inventory() {
  local output="$1"
  shift
  python3 - "$output" "$LOCAL_ID" "$@" <<'PY'
import hashlib
import json
import sys

output, local_id, *targets = sys.argv[1:]

def digest(label):
    return hashlib.sha256(label.encode()).hexdigest()

def identity(target):
    if target == "current":
        return local_id
    if target.startswith("duplicate-"):
        return "c" * 64
    return digest(target)

rows = []
for target in targets:
    authorization = "report-only" if target == "report-only" else "install"
    rows.append(
        {
            "id": target,
            "platform": "linux",
            "arch": "x86_64",
            "artifact": "linux-x86_64",
            "transport": {
                "kind": "ssh",
                "hostAlias": f"fixture-{target}",
            },
            "deployment": {
                "authorization": authorization,
                **(
                    {"reason": "fixture lacks install authority"}
                    if authorization == "report-only"
                    else {}
                ),
                "binaryPath": "/usr/local/bin/nvpn",
                "probeBinaryPath": "/tmp/nvpn-probe",
                "configPath": "/tmp/config.toml",
                "serviceName": "nvpn.service",
            },
            "expected": {
                "machineIdentitySha256": identity(target),
                "configSha256": digest(f"config:{target}"),
                "signedRosterStoreSha256": digest(
                    f"signed-roster-store:{target}"
                ),
                "rosterIdentitySha256": digest(f"roster:{target}"),
                "rosterPeerCount": 1,
                "localDeviceIdentitySha256": digest(f"device:{target}"),
                "networkIdentitySha256": digest(f"network:{target}"),
            },
            "checks": {
                "payloadTarget": "fixture-payload-target",
                "dnsName": "fixture-dns-name",
                "directUrl": "https://fixture.invalid/",
            },
        }
    )

payload = {
    "schema": 2,
    "excludeCurrentHost": True,
    "parallelProbes": 4,
    "targets": rows,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  if [[ -n "${MANIFEST:-}" && -f "${MANIFEST:-}" ]]; then
    python3 - "$MANIFEST" "$output" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, inventory_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["inventorySha256"] = hashlib.sha256(
    inventory_path.read_bytes()
).hexdigest()
manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  fi
}

mkdir -p "$APP/private" "$APP/artifacts" "$APP/scripts" "$FIPS"

sed 's/^+//' >"$DRIVER" <<'DRIVER'
+#!/usr/bin/env python3
+import argparse
+import hashlib
+import json
+import os
+import pathlib
+import sys
+
+def digest(label):
+    return hashlib.sha256(label.encode()).hexdigest()
+
+def atomic(path, value):
+    path.parent.mkdir(parents=True, exist_ok=True)
+    temporary = path.with_name(f".{path.name}.tmp")
+    temporary.write_text(
+        json.dumps(value, indent=2, sort_keys=True) + "\n",
+        encoding="utf-8",
+    )
+    temporary.replace(path)
+
+parser = argparse.ArgumentParser()
+parser.add_argument("action")
+parser.add_argument("--target", type=pathlib.Path, required=True)
+parser.add_argument("--output", type=pathlib.Path, required=True)
+parser.add_argument("--artifact")
+parser.add_argument("--receipt")
+parser.add_argument("--expectations", type=pathlib.Path)
+args = parser.parse_args()
+target = json.loads(args.target.read_text(encoding="utf-8"))
+target_id = target["id"]
+with open(os.environ["FAKE_DRIVER_LOG"], "a", encoding="utf-8") as handle:
+    handle.write(f"{args.action}:{target_id}\n")
+
+if args.action == "probe" and target_id == "unreachable":
+    raise SystemExit(75)
+if args.action == "probe" and target_id == "noaccess":
+    raise SystemExit(76)
+
+expected_target = target["expected"]
+inactive = target_id in {"inactive", "bad-process-inactive"}
+absent = target_id == "absent"
+exact_candidate = target_id in {"already-exact", "already-exact-wrong"}
+service = {
+    "installed": not absent,
+    "enabled": not (inactive or absent),
+    "running": not (inactive or absent),
+    "binaryPresent": not absent,
+    "binarySha256": (
+        None
+        if absent
+        else (
+            os.environ["FAKE_PROBE_BINARY_SHA256"]
+            if exact_candidate
+            else digest(f"prior-binary:{target_id}")
+        )
+    ),
+    "definitionSha256": (
+        None if absent else digest(f"definition:{target_id}")
+    ),
+    "processCount": 0 if inactive or absent else 1,
+    "pid": None if inactive or absent else 99,
+}
+config = {
+    "sha256": expected_target["configSha256"],
+    "signedRosterStoreSha256": expected_target[
+        "signedRosterStoreSha256"
+    ],
+    "rosterIdentitySha256": expected_target["rosterIdentitySha256"],
+    "rosterPeerCount": expected_target["rosterPeerCount"],
+    "localDeviceIdentitySha256": expected_target[
+        "localDeviceIdentitySha256"
+    ],
+    "networkIdentitySha256": expected_target["networkIdentitySha256"],
+}
+network = {
+    "directMode": True,
+    "wireguardExitEnabled": False,
+    "dnsResolved": True,
+    "publicInternet": True,
+    "resolverFingerprint": digest(f"resolver:{target_id}"),
+    "defaultRouteFingerprint": digest(f"default-route:{target_id}"),
+    "routeTableFingerprint": digest(f"routes:{target_id}"),
+    "ownedRouteCount": 0,
+    "ownedResolverArtifactCount": 0,
+}
+identity = expected_target["machineIdentitySha256"]
+
+if args.action == "probe":
+    pending = target_id == "pending"
+    probe_hash = (
+        service["binarySha256"]
+        if service["binaryPresent"]
+        else os.environ["FAKE_PROBE_BINARY_SHA256"]
+    )
+    probe_app_version = os.environ["FAKE_PROBE_APP_VERSION"]
+    probe_fips_version = os.environ["FAKE_PROBE_FIPS_CORE_VERSION"]
+    if exact_candidate:
+        probe_app_version = os.environ["FAKE_CANDIDATE_APP_VERSION"]
+        probe_fips_version = os.environ["FAKE_CANDIDATE_FIPS_CORE_VERSION"]
+    elif target_id == "same-version-transition":
+        probe_app_version = os.environ["FAKE_CANDIDATE_APP_VERSION"]
+    if target_id == "malformed-probe-hash":
+        probe_hash = "not-a-sha256"
+    value = {
+        "schema": 2,
+        "targetId": target_id,
+        "reachable": True,
+        "platform": target["platform"],
+        "arch": target["arch"],
+        "machineIdentitySha256": identity,
+        "realChecks": True,
+        "mocked": False,
+        "remoteBuildPerformed": False,
+        "probeBinarySha256": probe_hash,
+        "probeAppVersion": probe_app_version,
+        "probeFipsCoreVersion": probe_fips_version,
+        "transaction": {
+            "recoveryRequired": pending,
+            "pendingTransactionIds": ["b" * 32] if pending else [],
+        },
+        "service": service,
+        "config": config,
+        "network": network,
+    }
+else:
+    expectations = json.loads(args.expectations.read_text(encoding="utf-8"))
+    transaction_id = expectations["transactionId"]
+    if args.action == "rollback":
+        if target_id == "rollback-fail":
+            print("fixture rollback failed", file=sys.stderr)
+            raise SystemExit(1)
+        rollback_service = dict(service)
+        if (
+            rollback_service["running"]
+            and target_id != "rollback-stale-pid"
+        ):
+            rollback_service["pid"] = 199
+        if rollback_service["installed"]:
+            rollback_service.update(
+                {
+                    "configuredBinaryPath": target["deployment"]["binaryPath"],
+                    "configuredBinaryResolvedPath": target["deployment"][
+                        "binaryPath"
+                    ],
+                    "execStartPath": target["deployment"]["binaryPath"],
+                    "execStartResolvedPath": target["deployment"][
+                        "binaryPath"
+                    ],
+                    "mainProcessExePath": (
+                        target["deployment"]["binaryPath"]
+                        if rollback_service["running"]
+                        else None
+                    ),
+                    "mainProcessExeSha256": (
+                        digest("stale-rollback-process")
+                        if target_id == "rollback-stale-image"
+                        else rollback_service["binarySha256"]
+                        if rollback_service["running"]
+                        else None
+                    ),
+                }
+            )
+        value = {
+            "schema": 2,
+            "targetId": target_id,
+            "machineIdentitySha256": identity,
+            "remoteBuildPerformed": False,
+            "transaction": {
+                "id": transaction_id,
+                "state": "rolled-back",
+                "durableJournal": True,
+                "journalReceiptSha256": digest(
+                    f"rollback-journal:{target_id}"
+                ),
+            },
+            "service": rollback_service,
+            "config": config,
+            "network": network,
+            "snapshotReceiptSha256": digest(f"snapshot:{target_id}"),
+            "serviceReceiptSha256": digest(f"service:{target_id}"),
+            "configReceiptSha256": digest(f"config-receipt:{target_id}"),
+            "routesReceiptSha256": digest(f"routes-receipt:{target_id}"),
+            "resolverReceiptSha256": digest(
+                f"resolver-receipt:{target_id}"
+            ),
+            "processesReceiptSha256": digest(
+                f"processes-receipt:{target_id}"
+            ),
+        }
+    else:
+        wrong_roster = target_id == "wrong-roster"
+        preinstall_probe = dict(expectations["preinstallProbe"])
+        if target_id == "probe-drift-hash":
+            preinstall_probe["probeBinarySha256"] = digest("drifted-probe")
+        elif target_id == "probe-drift-app-version":
+            preinstall_probe["probeAppVersion"] = "4.1.3"
+        elif target_id == "probe-drift-fips-version":
+            preinstall_probe["probeFipsCoreVersion"] = (
+                "0.4.43 (rev 0000000000)"
+            )
+        value = {
+            "schema": 2,
+            "targetId": target_id,
+            "platform": target["platform"],
+            "arch": target["arch"],
+            "machineIdentitySha256": identity,
+            "realChecks": True,
+            "mocked": False,
+            "remoteBuildPerformed": target_id == "remote-build",
+            "installAuthorized": True,
+            **{
+                field: expectations[field]
+                for field in (
+                    "appGitSha",
+                    "appGitTree",
+                    "appVersion",
+                    "fipsGitSha",
+                    "fipsGitTree",
+                    "fipsVersion",
+                )
+            },
+            "artifactSha256": expectations["artifactSha256"],
+            "artifactSize": expectations["artifactSize"],
+            "stagedArtifactSha256": expectations["artifactSha256"],
+            "preinstallProbe": preinstall_probe,
+            "transaction": {
+                "id": transaction_id,
+                "state": "committed",
+                "durableJournal": True,
+                "rollbackAvailable": True,
+                "journalReceiptSha256": digest(
+                    f"install-journal:{target_id}"
+                ),
+                "snapshot": {
+                    "durable": True,
+                    "service": service,
+                    "config": config,
+                    "network": network,
+                    **{
+                        field: digest(f"{field}:{target_id}")
+                        for field in (
+                            "serviceReceiptSha256",
+                            "configReceiptSha256",
+                            "routesReceiptSha256",
+                            "resolverReceiptSha256",
+                            "processesReceiptSha256",
+                            "statusReceiptSha256",
+                        )
+                    },
+                },
+            },
+            "service": {
+                "installed": True,
+                "enabled": True,
+                "running": True,
+                "restartDurable": True,
+                "binarySha256": expectations["installedBinarySha256"],
+                "binaryVersion": f"nvpn {expectations['appVersion']}",
+                "fipsCoreVersion": (
+                    f"{expectations['fipsVersion']} "
+                    f"(rev {expectations['fipsGitSha'][:10]})"
+                ),
+                "priorInstalled": service["installed"],
+                "priorEnabled": service["enabled"],
+                "priorRunning": service["running"],
+                "priorBinaryPresent": service["binaryPresent"],
+                "priorBinarySha256": service["binarySha256"],
+                "installTransition": (
+                    "candidate-transition"
+                    if target_id == "already-exact-wrong"
+                    else expectations["installTransition"]
+                ),
+                "processCount": (
+                    2
+                    if target_id in {
+                        "bad-process",
+                        "bad-process-inactive",
+                        "rollback-fail",
+                        "rollback-stale-pid",
+                        "rollback-stale-image",
+                    }
+                    else 1
+                ),
+                "pidBeforeRestart": 100,
+                "pidAfterRestart": 101,
+                "configuredBinaryPath": target["deployment"]["binaryPath"],
+                "configuredBinaryResolvedPath": target["deployment"][
+                    "binaryPath"
+                ],
+                "execStartPath": target["deployment"]["binaryPath"],
+                "execStartResolvedPath": (
+                    "/usr/local/bin/stale-nvpn"
+                    if target_id == "misdirected-unit"
+                    else target["deployment"]["binaryPath"]
+                ),
+                "mainProcessExePath": (
+                    "/usr/local/bin/stale-nvpn"
+                    if target_id == "stale-main-process"
+                    else target["deployment"]["binaryPath"]
+                ),
+                "mainProcessExeSha256": (
+                    digest("stale-main-process")
+                    if target_id == "stale-main-process"
+                    else expectations["installedBinarySha256"]
+                ),
+            },
+            "config": {
+                "mutationOutsideInstall": False,
+                "sha256Before": config["sha256"],
+                "sha256After": config["sha256"],
+                "signedRosterStoreSha256Before": config[
+                    "signedRosterStoreSha256"
+                ],
+                "signedRosterStoreSha256After": config[
+                    "signedRosterStoreSha256"
+                ],
+                "rosterIdentitySha256Before": config[
+                    "rosterIdentitySha256"
+                ],
+                "rosterIdentitySha256After": (
+                    digest("wrong-roster")
+                    if wrong_roster
+                    else config["rosterIdentitySha256"]
+                ),
+                "rosterPeerCountBefore": config["rosterPeerCount"],
+                "rosterPeerCountAfter": config["rosterPeerCount"],
+                "localDeviceIdentitySha256Before": config[
+                    "localDeviceIdentitySha256"
+                ],
+                "localDeviceIdentitySha256After": config[
+                    "localDeviceIdentitySha256"
+                ],
+                "networkIdentitySha256Before": config[
+                    "networkIdentitySha256"
+                ],
+                "networkIdentitySha256After": config[
+                    "networkIdentitySha256"
+                ],
+            },
+            "roster": {
+                "meshReady": True,
+                "expectedPeerCount": config["rosterPeerCount"],
+                "connectedPeerCount": 1,
+                "payloadTarget": expectations["checks"]["payloadTarget"],
+                "payloadSuccess": True,
+                "txIncreased": True,
+                "rxIncreased": True,
+                "txBytesBefore": 10,
+                "txBytesAfter": 20,
+                "rxBytesBefore": 10,
+                "rxBytesAfter": 20,
+                "payloadReceiptSha256": digest(f"payload:{target_id}"),
+            },
+            "network": {
+                "directMode": True,
+                "wireguardExitEnabled": False,
+                "dnsResolvedBefore": True,
+                "dnsResolvedAfter": True,
+                "dnsRestored": True,
+                "defaultRouteRestored": True,
+                "routeTableRestored": True,
+                "publicInternetAfter": True,
+                "dnsName": expectations["checks"]["dnsName"],
+                "dnsAnswerCount": 1,
+                "directUrl": expectations["checks"]["directUrl"],
+                "directHttpStatus": 204,
+                "resolverFingerprintBefore": network[
+                    "resolverFingerprint"
+                ],
+                "resolverFingerprintAfter": network[
+                    "resolverFingerprint"
+                ],
+                "defaultRouteFingerprintBefore": network[
+                    "defaultRouteFingerprint"
+                ],
+                "defaultRouteFingerprintAfter": network[
+                    "defaultRouteFingerprint"
+                ],
+                "routeTableFingerprintBefore": network[
+                    "routeTableFingerprint"
+                ],
+                "routeTableFingerprintAfter": network[
+                    "routeTableFingerprint"
+                ],
+                "ownedRouteCountAfter": 0,
+                "ownedResolverArtifactCountAfter": 0,
+                **{
+                    field: digest(f"{field}:{target_id}")
+                    for field in (
+                        "dnsReceiptSha256",
+                        "directProbeReceiptSha256",
+                        "routesReceiptSha256",
+                        "resolverReceiptSha256",
+                        "processesReceiptSha256",
+                    )
+                },
+            },
+        }
+
+raw_path = args.output.with_name(f"{args.output.stem}-raw.json")
+atomic(raw_path, value)
+wrapped = {
+    **value,
+    "rawReceipt": {
+        "path": str(raw_path.resolve()),
+        "sha256": hashlib.sha256(raw_path.read_bytes()).hexdigest(),
+        "size": raw_path.stat().st_size,
+    },
+}
+if target_id == "bad-raw" and args.action == "install":
+    wrapped["machineIdentitySha256"] = digest("tampered-wrapper")
+atomic(args.output, wrapped)
DRIVER
chmod +x "$DRIVER"
printf '# fixture linux helper\n' >"$LINUX_HELPER"
printf '# fixture windows helper\n' >"$WINDOWS_HELPER"
cp "$ROOT/scripts/fleet-release-gate-evidence.mjs" "$GATE_VALIDATOR"
cp "$ROOT/scripts/release-artifact-provenance-lib.mjs" "$PROVENANCE_LIB"

git -C "$APP" init -q
git -C "$APP" config user.name fixture
git -C "$APP" config user.email fixture@example.invalid
printf 'private/\nartifacts/\n' >"$APP/.gitignore"
printf 'fixture app\n' >"$APP/source.txt"
git -C "$APP" add .gitignore source.txt scripts
git -C "$APP" commit -qm app

git -C "$FIPS" init -q
git -C "$FIPS" config user.name fixture
git -C "$FIPS" config user.email fixture@example.invalid
printf 'fixture fips\n' >"$FIPS/source.txt"
git -C "$FIPS" add source.txt
git -C "$FIPS" commit -qm fips

APP_SHA="$(git -C "$APP" rev-parse HEAD)"
APP_TREE="$(git -C "$APP" rev-parse 'HEAD^{tree}')"
FIPS_SHA="$(git -C "$FIPS" rev-parse HEAD)"
FIPS_TREE="$(git -C "$FIPS" rev-parse 'HEAD^{tree}')"
PAYLOAD="$APP/artifacts/nvpn"
ARTIFACT="$APP/artifacts/nvpn-v4.1.5-x86_64-unknown-linux-musl.tar.gz"
GATE_FIXTURE_ROOT="$APP/artifacts/release-gate"
GATE_FIXTURE="$GATE_FIXTURE_ROOT/fleet-gate-fixture.json"
GATE_RELEASE="$GATE_FIXTURE_ROOT/release.json"
RECEIPT="$APP/artifacts/linux-receipt.json"
MANIFEST="$APP/private/manifest.json"
INVENTORY="$APP/private/inventory.json"
EVIDENCE="$APP/private/evidence"

printf 'immutable candidate binary\n' >"$PAYLOAD"
tar -czf "$ARTIFACT" -C "$APP/artifacts" nvpn
PAYLOAD_SHA="$(sha256_file "$PAYLOAD")"
ARTIFACT_SHA="$(sha256_file "$ARTIFACT")"
ARTIFACT_SIZE="$(wc -c <"$ARTIFACT" | tr -d '[:space:]')"

NVPN_FLEET_GATE_FIXTURE_ROOT="$GATE_FIXTURE_ROOT" \
NVPN_FLEET_GATE_TARGET_STATUS=missed \
NVPN_FLEET_GATE_APP_GIT_SHA="$APP_SHA" \
NVPN_FLEET_GATE_APP_GIT_TREE="$APP_TREE" \
NVPN_FLEET_GATE_APP_VERSION=4.1.5 \
NVPN_FLEET_GATE_FIPS_GIT_SHA="$FIPS_SHA" \
NVPN_FLEET_GATE_FIPS_GIT_TREE="$FIPS_TREE" \
NVPN_FLEET_GATE_FIPS_VERSION=0.4.45 \
NVPN_FLEET_GATE_ARTIFACT_SHA256="$ARTIFACT_SHA" \
NVPN_FLEET_GATE_ARTIFACT_SIZE="$ARTIFACT_SIZE" \
NVPN_FLEET_GATE_PAYLOAD_SHA256="$PAYLOAD_SHA" \
  node --test \
    --test-name-pattern='release receipt collection requires exact source' \
    "$ROOT/scripts/release-artifact-provenance-lib.test.mjs" >/dev/null
GATE_RELEASE_SHA="$(sha256_file "$GATE_RELEASE")"

python3 - \
  "$RECEIPT" "$APP_SHA" "$APP_TREE" "$FIPS_SHA" "$FIPS_TREE" \
  "$ARTIFACT_SHA" "$ARTIFACT_SIZE" "$PAYLOAD_SHA" "$GATE_FIXTURE" <<'PY'
import json
import sys

(
    output,
    app_sha,
    app_tree,
    fips_sha,
    fips_tree,
    artifact_sha,
    artifact_size,
    payload_sha,
    fixture_path,
) = sys.argv[1:]
fixture = json.load(open(fixture_path, encoding="utf-8"))
value = {
    "schema": 1,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "appVersion": "4.1.5",
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": "0.4.45",
    "platform": "linux",
    "arch": "x86_64",
    "artifactSha256": artifact_sha,
    "artifactSize": int(artifact_size),
    "installedBinarySha256": payload_sha,
    "installedPayloads": {"nvpn": payload_sha},
    "gateEvidenceIds": ["complete-release-gate"],
    "releaseAssetPath": fixture["releaseAssetPath"],
    "releasePayloadLabels": {"nvpn": fixture["payloadLabel"]},
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

python3 - \
  "$MANIFEST" "$APP_SHA" "$APP_TREE" "$FIPS_SHA" "$FIPS_TREE" \
  "$DRIVER" "$LINUX_HELPER" "$WINDOWS_HELPER" \
  "$ARTIFACT" "$RECEIPT" "$GATE_FIXTURE" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    output,
    app_sha,
    app_tree,
    fips_sha,
    fips_tree,
    driver,
    linux_helper,
    windows_helper,
    artifact,
    receipt,
    fixture_path,
) = sys.argv[1:]

def bound(path):
    value = pathlib.Path(path)
    return {
        "path": str(value),
        "sha256": hashlib.sha256(value.read_bytes()).hexdigest(),
        "size": value.stat().st_size,
    }

artifact_bound = bound(artifact)
fixture = json.loads(pathlib.Path(fixture_path).read_text(encoding="utf-8"))
gate_request = fixture["request"]
gate_receipt_paths = {
    "releaseGateSummary": bound(
        gate_request["receiptPaths"]["releaseGateSummary"]
    ),
    "platforms": {
        platform: {
            name: bound(path)
            for name, path in receipts.items()
        }
        for platform, receipts in gate_request["receiptPaths"][
            "platforms"
        ].items()
    },
}
value = {
    "schema": 2,
    "inventorySha256": "0" * 64,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "appVersion": "4.1.5",
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": "0.4.45",
    "driver": {
        **bound(driver),
        "protocol": "nvpn-fleet-ssh-transactional-v2",
        "helpers": [bound(linux_helper), bound(windows_helper)],
    },
    "gateEvidence": [
        {
            "id": "complete-release-gate",
            "kind": "staged-release-attestation-v1",
            **bound(gate_request["releasePath"]),
            "receiptPaths": gate_receipt_paths,
        }
    ],
    "artifacts": [
        {
            "id": "linux-x86_64",
            "platform": "linux",
            "arch": "x86_64",
            **artifact_bound,
            "installPayload": {
                "format": "tar-gz",
                "executableMember": "nvpn",
                "companions": [],
            },
            "receipt": bound(receipt),
        }
    ],
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

common=(
  --root "$APP"
  --fips-root "$FIPS"
  --inventory "$INVENTORY"
  --manifest "$MANIFEST"
  --evidence-dir "$EVIDENCE"
)

run_execute() {
  NVPN_FLEET_INSTALL_AUTHORIZED=1 \
  FAKE_DRIVER_LOG="$DRIVER_LOG" \
  FAKE_PROBE_BINARY_SHA256="$PAYLOAD_SHA" \
  FAKE_PROBE_APP_VERSION="4.1.4" \
  FAKE_PROBE_FIPS_CORE_VERSION="0.4.44 (rev 1111111111)" \
  FAKE_CANDIDATE_APP_VERSION="4.1.5" \
  FAKE_CANDIDATE_FIPS_CORE_VERSION="0.4.45 (rev ${FIPS_SHA:0:10})" \
    python3 "$ORCHESTRATOR" execute "${common[@]}"
}

refresh_gate_binding() {
  python3 - "$MANIFEST" "$GATE_RELEASE" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, release_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
gate = manifest["gateEvidence"][0]
gate["sha256"] = hashlib.sha256(release_path.read_bytes()).hexdigest()
gate["size"] = release_path.stat().st_size
manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

python3 -m py_compile \
  "$ORCHESTRATOR" \
  "$ROOT/scripts/fleet_release_canary_evidence.py" \
  "$ROOT/scripts/fleet_release_canary_ssh_driver.py" \
  "$ROOT/scripts/fleet_release_canary_remote_linux.py" \
  "$DRIVER"
bash -n "$0"
if grep -Fq "NVPN_FLEET_LOCAL_MACHINE_ID_SHA256" \
  "$ORCHESTRATOR" \
  "$ROOT/scripts/fleet_release_canary_evidence.py" \
  "$ROOT/scripts/fleet_release_canary_ssh_driver.py" \
  "$ROOT/scripts/fleet_release_canary_remote_linux.py" \
  "$ROOT/scripts/fleet_release_canary_remote_windows.ps1"
then
  fail "fleet production path retains a current-host identity override"
fi
python3 - "$ORCHESTRATOR" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("fleet_canary", path)
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)
first = {
    "path": "/private/probe.json",
    "sha256": "a" * 64,
    "size": 1,
}
second = {
    "path": "/private/install.json",
    "sha256": "b" * 64,
    "size": 2,
}
accepted = canary.validate_result_evidence(
    {"probe": first, "install": second},
    {"probe", "install"},
    "fixture result evidence",
)
if set(accepted) != {"probe", "install"}:
    raise SystemExit("complete fleet result evidence was not retained")
for label, value, expected_error in (
    (
        "missing",
        {"probe": first},
        "must contain exactly",
    ),
    (
        "duplicate",
        {"probe": first, "install": dict(first)},
        "duplicate raw receipt binding",
    ),
    (
        "malformed",
        {
            "probe": first,
            "install": {**second, "sha256": "not-a-sha256"},
        },
        "install.sha256 is invalid",
    ),
):
    try:
        canary.validate_result_evidence(
            value,
            {"probe", "install"},
            f"{label} result evidence",
        )
    except (canary.CanaryError, canary.EvidenceError) as error:
        if expected_error not in str(error):
            raise SystemExit(f"{label} binding returned wrong error: {error}")
    else:
        raise SystemExit(f"{label} result evidence was accepted")

with tempfile.TemporaryDirectory(prefix="nvpn-raw-binding.") as raw:
    root = pathlib.Path(raw)
    receipt = root / "probe-raw.json"
    receipt.write_text('{"schema":2}\n', encoding="utf-8")
    wrapped = root / "probe.json"
    value = {
        "schema": 2,
        "rawReceipt": {
            "path": str(receipt),
            "sha256": hashlib.sha256(receipt.read_bytes()).hexdigest(),
            "size": receipt.stat().st_size,
        },
    }
    wrapped.write_text(json.dumps(value), encoding="utf-8")
    loaded = canary.load_driver_evidence(wrapped, root, "fixture probe")
    if loaded["rawReceipt"] != value["rawReceipt"]:
        raise SystemExit("valid raw binding changed during validation")
    value["rawReceipt"]["sha256"] = "0" * 64
    wrapped.write_text(json.dumps(value), encoding="utf-8")
    try:
        canary.load_driver_evidence(wrapped, root, "fixture probe")
    except (canary.CanaryError, canary.EvidenceError) as error:
        if "raw receipt SHA-256 mismatch" not in str(error):
            raise SystemExit(f"mismatched raw binding returned wrong error: {error}")
    else:
        raise SystemExit("mismatched raw receipt binding was accepted")
PY
python3 - "$ROOT/scripts/fleet_release_canary_remote_linux.py" <<'PY'
import copy
import hashlib
import os
import pathlib
import sys
import tempfile
import types

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
anchor = "\npayload = json.loads(base64.b64decode(FLEET_PAYLOAD_B64))"
definitions, separator, _ = source.partition(anchor)
if not separator:
    raise SystemExit("Linux fleet adapter entry point is ambiguous")
namespace = {"__name__": "fleet_adapter_probe_identity_contract"}
exec(compile(definitions, str(path), "exec"), namespace)

candidate = b"immutable candidate binary\n"
candidate_sha256 = hashlib.sha256(candidate).hexdigest()
preinstall_binary_sha256 = hashlib.sha256(
    b"older installed nvpn binary\n"
).hexdigest()
fips_sha = "b" * 40
preinstall_probe = {
    "probeBinarySha256": preinstall_binary_sha256,
    "probeAppVersion": "4.1.4",
    "probeFipsCoreVersion": "0.4.44 (rev 1111111111)",
}
frozen = {
    "machineIdentitySha256": "a" * 64,
    "configSha256": "c" * 64,
    "signedRosterStoreSha256": "d" * 64,
    "rosterIdentitySha256": "e" * 64,
    "rosterPeerCount": 1,
    "localDeviceIdentitySha256": "f" * 64,
    "networkIdentitySha256": "1" * 64,
}
base_state = {
    **preinstall_probe,
    "service": {
        "installed": False,
        "binaryPresent": False,
        "binarySha256": None,
    },
    "config": {
        "sha256": frozen["configSha256"],
        "signedRosterStoreSha256": frozen["signedRosterStoreSha256"],
        "rosterIdentitySha256": frozen["rosterIdentitySha256"],
        "rosterPeerCount": frozen["rosterPeerCount"],
        "localDeviceIdentitySha256": frozen["localDeviceIdentitySha256"],
        "networkIdentitySha256": frozen["networkIdentitySha256"],
    },
    "network": {
        "directMode": True,
        "ownedRouteCount": 0,
        "ownedResolverArtifactCount": 0,
    },
}
drifts = {
    "probeBinarySha256": (
        "2" * 64,
        "probe CLI binary changed after preflight",
    ),
    "probeAppVersion": (
        "4.1.3",
        "probe CLI app version changed after preflight",
    ),
    "probeFipsCoreVersion": (
        "0.4.45 (rev 0000000000)",
        "probe CLI FIPS version changed after preflight",
    ),
}
namespace["machine_identity"] = lambda: frozen["machineIdentitySha256"]

with tempfile.TemporaryDirectory(prefix="nvpn-linux-probe-drift.") as raw:
    work = pathlib.Path(raw)
    old_sudo_user = os.environ.get("SUDO_USER")
    os.environ["SUDO_USER"] = "fixture"
    namespace["pwd"] = types.SimpleNamespace(
        getpwnam=lambda _user: types.SimpleNamespace(pw_dir=str(work))
    )
    try:
        for index, (field, (bad_value, expected_error)) in enumerate(
            drifts.items()
        ):
            stage_name = (
                f".nvpn-fleet-{index + 1:032x}.artifact"
            )
            stage = work / stage_name
            stage.write_bytes(candidate)
            transaction_root = work / f"transaction-root-{index}"
            target = {
                "id": f"drift-{field}",
                "deployment": {
                    "authorization": "install",
                    "transactionRoot": str(transaction_root),
                },
                "expected": frozen,
                "checks": {},
            }
            expected = {
                "transactionId": f"{index + 1:032x}",
                "artifactSha256": candidate_sha256,
                "artifactSize": len(candidate),
                "installedBinarySha256": candidate_sha256,
                "installTransition": "fresh-install",
                "preinstallProbe": preinstall_probe,
                "appVersion": "4.1.5",
                "fipsVersion": "0.4.45",
                "fipsGitSha": fips_sha,
                "expected": frozen,
            }
            state = copy.deepcopy(base_state)
            state[field] = bad_value
            namespace["capture"] = lambda _target, *, checks: state
            mutations = []

            def snapshot(*_args):
                mutations.append("snapshot")
                raise RuntimeError("probe drift reached snapshot mutation")

            namespace["snapshot_transaction"] = snapshot
            try:
                namespace["install"](
                    {"stageName": stage_name},
                    target,
                    expected,
                )
            except RuntimeError as error:
                if expected_error not in str(error):
                    raise SystemExit(
                        f"{field} drift reached mutation or wrong guard: {error}"
                    ) from error
            else:
                raise SystemExit(f"{field} drift was accepted")
            if (
                mutations
                or transaction_root.exists()
                or not stage.is_file()
            ):
                raise SystemExit(
                    f"{field} drift mutated install state or user stage"
                )

        for index, failure in enumerate(
            ("hash-precondition", "snapshot", "extraction"),
            start=10,
        ):
            stage_name = (
                f".nvpn-fleet-{index + 1:032x}.artifact"
            )
            stage = work / stage_name
            stage.write_bytes(candidate)
            transaction_root = work / f"transaction-root-{index}"
            target = {
                "id": f"stage-cleanup-{failure}",
                "deployment": {
                    "authorization": "install",
                    "transactionRoot": str(transaction_root),
                },
                "expected": frozen,
                "checks": {},
            }
            expected = {
                "transactionId": f"{index + 1:032x}",
                "artifactSha256": candidate_sha256,
                "artifactSize": len(candidate),
                "installedBinarySha256": candidate_sha256,
                "installTransition": "fresh-install",
                "preinstallProbe": preinstall_probe,
                "installPayload": {
                    "format": "executable",
                    "companions": [],
                },
                "appVersion": "4.1.5",
                "fipsVersion": "0.4.45",
                "fipsGitSha": fips_sha,
                "expected": frozen,
            }
            namespace["capture"] = lambda _target, *, checks: copy.deepcopy(
                base_state
            )
            expected_error = {
                "hash-precondition": "staged artifact SHA-256 mismatch",
                "snapshot": "fixture snapshot failure",
                "extraction": "fixture extraction failure",
            }[failure]
            if failure == "hash-precondition":
                expected["artifactSha256"] = "9" * 64
            elif failure == "snapshot":
                namespace["snapshot_transaction"] = lambda *_args: (
                    namespace["fail"]("fixture snapshot failure")
                )
            else:
                def snapshot(transaction, *_args):
                    transaction.mkdir(parents=True)
                    return {}

                namespace["snapshot_transaction"] = snapshot
                namespace["extract_payload"] = lambda *_args: (
                    namespace["fail"]("fixture extraction failure")
                )
            try:
                namespace["install"](
                    {"stageName": stage_name},
                    target,
                    expected,
                )
            except RuntimeError as error:
                if expected_error not in str(error):
                    raise SystemExit(
                        f"{failure} returned the wrong failure: {error}"
                    ) from error
            else:
                raise SystemExit(f"{failure} was accepted")
            if (
                not stage.is_file()
                or (
                    transaction_root.exists()
                    and list(transaction_root.glob(".staged-*"))
                )
            ):
                raise SystemExit(
                    f"{failure} mutated user stage or left private residue"
                )

        symlink_target = work / "symlink-target"
        symlink_target.write_bytes(candidate)
        symlink_stage = work / f".nvpn-fleet-{'f' * 32}.artifact"
        symlink_stage.symlink_to(symlink_target)
        symlink_root = work / "transaction-root-symlink"
        target = {
            "id": "symlink-stage",
            "deployment": {
                "authorization": "install",
                "transactionRoot": str(symlink_root),
            },
            "expected": frozen,
            "checks": {},
        }
        expected = {
            "transactionId": "f" * 32,
            "artifactSha256": candidate_sha256,
            "artifactSize": len(candidate),
            "installedBinarySha256": candidate_sha256,
            "installTransition": "fresh-install",
            "preinstallProbe": preinstall_probe,
            "installPayload": {"format": "executable", "companions": []},
            "appVersion": "4.1.5",
            "fipsVersion": "0.4.45",
            "fipsGitSha": fips_sha,
            "expected": frozen,
        }
        try:
            namespace["install"](
                {"stageName": symlink_stage.name},
                target,
                expected,
            )
        except RuntimeError as error:
            if "could not be secured" not in str(error):
                raise SystemExit(
                    f"symlink stage returned the wrong guard: {error}"
                ) from error
        else:
            raise SystemExit("symlink staged artifact was accepted")
        if (
            not symlink_stage.is_symlink()
            or symlink_root.exists()
        ):
            raise SystemExit("symlink rejection mutated user or private stage")
        symlink_stage.unlink()
    finally:
        if old_sudo_user is None:
            os.environ.pop("SUDO_USER", None)
        else:
            os.environ["SUDO_USER"] = old_sudo_user

runtime_state = {
    "_configuredBinaryResolvedPath": "/usr/local/bin/nvpn",
    "_execStartPath": "/usr/local/bin/nvpn",
    "_execStartResolvedPath": "/usr/local/bin/nvpn",
    "_mainProcessExePath": "/usr/local/bin/nvpn",
    "_mainProcessExeSha256": candidate_sha256,
}
runtime = namespace["assert_service_runtime_binding"](
    runtime_state,
    pathlib.Path("/usr/local/bin/nvpn"),
    candidate_sha256,
)
if (
    runtime["configuredBinaryResolvedPath"] != "/usr/local/bin/nvpn"
    or runtime["execStartResolvedPath"] != "/usr/local/bin/nvpn"
    or runtime["mainProcessExePath"] != "/usr/local/bin/nvpn"
    or runtime["mainProcessExeSha256"] != candidate_sha256
):
    raise SystemExit("Linux runtime binding omitted exact service evidence")
for field, bad_value, expected_error in (
    (
        "_execStartResolvedPath",
        "/usr/local/bin/stale-nvpn",
        "systemd ExecStart does not resolve to the configured binary",
    ),
    (
        "_mainProcessExePath",
        "/usr/local/bin/stale-nvpn",
        "systemd MainPID does not execute the configured binary",
    ),
    (
        "_mainProcessExeSha256",
        "8" * 64,
        "systemd MainPID executable hash is not the expected binary",
    ),
):
    stale = copy.deepcopy(runtime_state)
    stale[field] = bad_value
    try:
        namespace["assert_service_runtime_binding"](
            stale,
            pathlib.Path("/usr/local/bin/nvpn"),
            candidate_sha256,
        )
    except RuntimeError as error:
        if expected_error not in str(error):
            raise SystemExit(
                f"Linux {field} drift returned the wrong guard: {error}"
            ) from error
    else:
        raise SystemExit(f"Linux {field} drift was accepted")
stopped = copy.deepcopy(runtime_state)
stopped["_mainProcessExePath"] = None
stopped["_mainProcessExeSha256"] = None
stopped_runtime = namespace["assert_service_runtime_binding"](
    stopped,
    pathlib.Path("/usr/local/bin/nvpn"),
    candidate_sha256,
    require_process=False,
)
if (
    stopped_runtime["mainProcessExePath"] is not None
    or stopped_runtime["mainProcessExeSha256"] is not None
):
    raise SystemExit("Linux stopped-service binding invented a process")
stopped["_mainProcessExePath"] = "/usr/local/bin/nvpn"
try:
    namespace["assert_service_runtime_binding"](
        stopped,
        pathlib.Path("/usr/local/bin/nvpn"),
        candidate_sha256,
        require_process=False,
    )
except RuntimeError as error:
    if "unexpectedly has a bound MainPID" not in str(error):
        raise SystemExit(
            f"Linux stopped-process drift returned the wrong guard: {error}"
        ) from error
else:
    raise SystemExit("Linux stopped service accepted a live process binding")
try:
    namespace["finish_staged_cleanup"](
        RuntimeError("primary adapter failure"),
        ["private cleanup failure"],
    )
except RuntimeError as error:
    if (
        "primary adapter failure" not in str(error)
        or "private cleanup failure" not in str(error)
    ):
        raise SystemExit("Linux cleanup masked the primary adapter failure")
else:
    raise SystemExit("Linux combined adapter/cleanup failure was accepted")
PY
python3 - "$ROOT/scripts/fleet_release_canary_ssh_driver.py" <<'PY'
import base64
import gzip
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("fleet_driver", path)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
payload = {
    "protocol": "nvpn-fleet-ssh-transactional-v2",
    "action": "unsupported-transport-contract-probe",
    "target": {"deployment": {}},
}

linux_source, linux_command = driver.render_adapter_invocation("linux", payload)
future_import = "from __future__ import annotations\n"
assignment = "FLEET_PAYLOAD_B64="
if linux_source.count(future_import) != 1:
    raise SystemExit("Linux fleet helper future-import structure is ambiguous")
if not linux_source.index(future_import) < linux_source.index(assignment):
    raise SystemExit("Linux fleet payload precedes the future import")
if linux_command != ["sudo", "-n", "python3", "-"]:
    raise SystemExit("Linux fleet transport command changed")
executed = subprocess.run(
    [sys.executable, "-"],
    input=linux_source,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if executed.returncode == 0 or "unsupported fleet action" not in executed.stderr:
    raise SystemExit(
        "generated Linux fleet adapter did not execute past payload loading"
    )
if "SyntaxError" in executed.stderr:
    raise SystemExit("generated Linux fleet adapter is syntactically invalid")

windows_source, windows_command = driver.render_adapter_invocation(
    "windows", payload
)
if windows_command[-2] != "-EncodedCommand":
    raise SystemExit("Windows fleet transport does not use EncodedCommand")
wrapper = base64.b64decode(windows_command[-1]).decode("utf-16le")
for required in (
    "[Console]::In.ReadToEnd()",
    "[IO.Compression.GzipStream]",
    "[IO.FileMode]::CreateNew",
    "[IO.FileAccess]::ReadWrite",
    "[IO.FileShare]::None",
    "$writeStream.Flush($true)",
    "$writeStream.Position = 0",
    "$initialHash",
    "$writeStream.Dispose()",
    "[IO.FileMode]::Open",
    "[IO.FileAccess]::Read",
    "[IO.FileShare]::Read",
    "$lockStream.Length -ne $bytes.Length",
    "$lockStream.Position = 0",
    "$lockStream.Dispose()",
    "[Security.Cryptography.SHA256]::Create()",
    "-File $path",
    "Remove-Item -LiteralPath $path",
    "transient fleet adapter cleanup failed",
):
    if required not in wrapper:
        raise SystemExit("Windows fleet stdin wrapper is incomplete")
if "[ScriptBlock]::Create" in wrapper:
    raise SystemExit("Windows fleet transport still uses the unreliable stdin scriptblock")
write_close = wrapper.index("$writeStream.Dispose()")
read_lock = wrapper.index("$lockStream = [IO.FileStream]::new(")
execute = wrapper.index("-File $path")
read_unlock = wrapper.index("$lockStream.Dispose()")
delete = wrapper.index("Remove-Item -LiteralPath $path")
if not write_close < read_lock < execute < read_unlock < delete:
    raise SystemExit("Windows fleet transient file is not read-locked through execution")
try:
    windows_raw_source = gzip.decompress(
        base64.b64decode(windows_source)
    ).decode()
except Exception as error:
    raise SystemExit("Windows fleet stdin is not compressed source") from error
if "$script:FleetPayloadB64" not in windows_raw_source:
    raise SystemExit("Windows fleet adapter lacks its private stdin payload")
if len(windows_source) >= len(windows_raw_source):
    raise SystemExit("Windows fleet adapter was not reduced for reliable stdin transport")
if any("FLEET_PAYLOAD" in argument for argument in windows_command):
    raise SystemExit("private fleet payload leaked into remote argv")

cleanup_name = f".nvpn-fleet-{'1' * 32}.artifact"
linux_cleanup, linux_cleanup_command = (
    driver.render_staged_artifact_cleanup("linux", cleanup_name)
)
if linux_cleanup_command != ["python3", "-"]:
    raise SystemExit("Linux staged artifact cleanup transport changed")
with tempfile.TemporaryDirectory(prefix="nvpn-fleet-cleanup.") as raw:
    home = pathlib.Path(raw)
    staged = home / cleanup_name
    staged.write_text("remote residue\n", encoding="utf-8")
    cleanup_env = {**os.environ, "HOME": str(home)}
    result = subprocess.run(
        [sys.executable, "-"],
        input=linux_cleanup,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=cleanup_env,
    )
    if result.returncode != 0 or staged.exists():
        raise SystemExit("Linux driver cleanup left a staged artifact")
    staged.mkdir()
    result = subprocess.run(
        [sys.executable, "-"],
        input=linux_cleanup,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=cleanup_env,
    )
    if result.returncode == 0 or not staged.is_dir():
        raise SystemExit("Linux driver cleanup did not fail closed on residue")

windows_cleanup, windows_cleanup_command = (
    driver.render_staged_artifact_cleanup("windows", cleanup_name)
)
if windows_cleanup:
    raise SystemExit("Windows cleanup unexpectedly uses remote stdin")
if windows_cleanup_command[-2] != "-EncodedCommand":
    raise SystemExit("Windows staged artifact cleanup is not encoded")
decoded_cleanup = base64.b64decode(
    windows_cleanup_command[-1]
).decode("utf-16le")
for required in (
    "Remove-Item -LiteralPath $path -Force -ErrorAction Stop",
    "staged artifact cleanup left remote residue",
):
    if required not in decoded_cleanup:
        raise SystemExit("Windows driver cleanup is not fail-closed")

driver_text = path.read_text(encoding="utf-8")
staged_adapter = driver_text[driver_text.index(
    "def invoke_staged_adapter"
):driver_text.index(
    "\n\ndef parse_args"
)]
for required in (
    "primary_error",
    "cleanup_error",
    "cleanup also failed",
):
    if required not in staged_adapter:
        raise SystemExit("driver cleanup masks the primary adapter failure")

original_stage = driver.stage_artifact
original_invoke = driver.invoke_adapter
original_cleanup = driver.cleanup_staged_artifact
try:
    driver.stage_artifact = lambda *_args: None
    driver.invoke_adapter = lambda *_args: (75, None, "primary adapter failure")

    def cleanup_failure(*_args):
        raise driver.DriverError("remote cleanup failure")

    driver.cleanup_staged_artifact = cleanup_failure
    preserved = driver.invoke_staged_adapter(
        {"platform": "linux"},
        {},
        pathlib.Path("/fixture"),
        cleanup_name,
    )
    if preserved[0] != 75 or not all(
        value in preserved[2]
        for value in ("primary adapter failure", "remote cleanup failure")
    ):
        raise SystemExit("driver cleanup replaced the primary adapter status")
finally:
    driver.stage_artifact = original_stage
    driver.invoke_adapter = original_invoke
    driver.cleanup_staged_artifact = original_cleanup

try:
    driver.run_transport(
        [sys.executable, "-c", "import time; time.sleep(1)"],
        input_text=None,
        timeout=0.01,
        label="fixture transport",
    )
except driver.DriverError as error:
    if "timed out" not in str(error):
        raise SystemExit("driver transport timeout returned the wrong error")
else:
    raise SystemExit("driver transport timeout was not bounded")
PY
windows_adapter="$ROOT/scripts/fleet_release_canary_remote_windows.ps1"
grep -Fq "[IO.Path]::IsPathFullyQualified" "$windows_adapter" \
  && fail "Windows fleet adapter requires unavailable modern .NET path APIs"
grep -Fq "[IO.Path]::IsPathRooted" "$windows_adapter" \
  || fail "Windows fleet adapter does not reject relative paths compatibly"
grep -Fq "\$script:NvpnServiceName = 'NvpnService'" "$windows_adapter" \
  || fail "Windows fleet adapter does not use the production service name"
grep -Fq \
  "if (\$serviceName -ne \$script:NvpnServiceName)" \
  "$windows_adapter" \
  || fail "Windows fleet adapter does not reject non-production service names"
if grep -Eq "else \\{ 'nvpn' \\}|must be nvpn" "$windows_adapter"; then
  fail "Windows fleet adapter retains the obsolete service name"
fi
python3 - "$windows_adapter" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for required in (
    "function ParseServiceExecutablePath",
    "function AssertServiceRuntimeBinding",
    "_execStartPath",
    "_mainProcessExePath",
    "_mainProcessExeSha256",
    "[StringComparison]::OrdinalIgnoreCase",
):
    if required not in text:
        raise SystemExit(
            f"Windows exact service/process binding lacks {required}"
        )
if ".Contains(" in text:
    raise SystemExit(
        "Windows service executable binding still accepts substring matches"
    )
restore = text[text.index("function RestoreTransaction"):text.index(
    "function InstallCandidate"
)]
for required in (
    "rollback did not prove a new restored Windows service process",
    "AssertServiceRuntimeBinding",
    "$restoredService",
):
    if required not in restore:
        raise SystemExit(
            "Windows rollback lacks PID-safe restored executable binding"
        )
delete = restore.index("sc.exe delete $name")
wait_deleted = restore.index("WaitServiceDeleted $name")
remove_binary = restore.index(
    "Remove-Item -LiteralPath $binary -Force -ErrorAction SilentlyContinue"
)
if not delete < wait_deleted < remove_binary:
    raise SystemExit(
        "Windows pristine-host rollback removes the candidate in the wrong order"
    )
if "& $binary service uninstall" in restore:
    raise SystemExit(
        "Windows pristine-host rollback invokes a potentially missing executable"
    )
required = (
    "cannot safely canary an installed Windows service whose binary is absent",
    "cannot safely roll back an installed Windows service whose prior binary was absent",
)
if any(value not in text for value in required):
    raise SystemExit(
        "Windows fleet adapter lacks fail-closed broken-service guards"
    )

guard = text[text.index("function AssertExpected"):text.index(
    "function WriteJournal"
)]
for observed, exact, message in (
    (
        "$State.probeBinarySha256",
        "$preinstallProbe.probeBinarySha256",
        "probe CLI binary changed after preflight",
    ),
    (
        "$State.probeAppVersion",
        "$preinstallProbe.probeAppVersion",
        "probe CLI app version changed after preflight",
    ),
    (
        "$State.probeFipsCoreVersion",
        "$preinstallProbe.probeFipsCoreVersion",
        "probe CLI FIPS version changed after preflight",
    ),
):
    if observed not in guard or exact not in guard or message not in guard:
        raise SystemExit(
            f"Windows fleet adapter lacks exact pre-mutation guard: {message}"
        )

install = text[text.index("function InstallStagedCandidate"):text.index(
    "function InstallCandidate"
)]
assertion = install.index("AssertExpected $before $Target $Expected")
for mutation in (
    "[IO.Directory]::CreateDirectory($root)",
    "SnapshotTransaction $transaction",
    "WriteJournal $transaction",
    "ExtractPayload $stage",
    "Stop-Service -Name $name",
    "AtomicInstall $extracted.candidate",
):
    if assertion >= install.index(mutation):
        raise SystemExit(
            f"Windows probe identity assertion follows mutation: {mutation}"
        )

wrapper = text[text.index("function InstallCandidate"):text.index(
    "\ntry {\n    $payloadBytes"
)]
for required in (
    "CopyStagedArtifact $stage $root $transactionId",
    "$result = InstallStagedCandidate",
    "$primary",
    "staged artifact cleanup also failed",
    "RemoveStagedArtifact ([string]$path)",
):
    if required not in wrapper:
        raise SystemExit(
            "Windows private-stage cleanup masks the primary failure"
        )
if "RemoveStagedArtifact $stage" in wrapper:
    raise SystemExit("Windows adapter duplicates driver-owned user-stage cleanup")
cleanup = text[text.index("function RemoveStagedArtifact"):text.index(
    "function InstallStagedCandidate"
)]
for required in (
    "Remove-Item -LiteralPath $Path -Force -ErrorAction Stop",
    "staged artifact cleanup failed",
    "staged artifact cleanup left remote residue",
):
    if required not in cleanup:
        raise SystemExit(
            "Windows staged artifact cleanup is not fail-closed"
        )
for required in (
    "[IO.FileShare]::Read",
    "[IO.FileMode]::CreateNew",
    "[IO.FileAttributes]::ReparsePoint",
    "$privateWrite.Flush($true)",
):
    if required not in cleanup:
        raise SystemExit(
            "Windows adapter does not secure one immutable private stage"
        )
PY
if grep -Eq 'cargo build|dotnet build|gradle|xcodebuild' \
  "$ORCHESTRATOR" \
  "$ROOT/scripts/fleet_release_canary_evidence.py" \
  "$ROOT/scripts/fleet_release_canary_ssh_driver.py"
then
  fail "fleet canary path contains a remote/local build command"
fi

write_inventory "$INVENTORY" good
rm -f "$DRIVER_LOG"
python3 "$ORCHESTRATOR" plan "${common[@]}" >/dev/null
[[ ! -s "$DRIVER_LOG" ]] || fail "plan contacted the fleet driver"
json_status_is "$EVIDENCE/fleet-canary-plan.json" good planned
json_field_is \
  "$EVIDENCE/fleet-canary-plan.json" \
  releaseGateManifestSha256 \
  "$GATE_RELEASE_SHA"

cp "$GATE_RELEASE" "$WORK/release-good.json"
printf '{"passed":true}\n' >"$GATE_RELEASE"
refresh_gate_binding
rm -f "$DRIVER_LOG"
if python3 "$ORCHESTRATOR" plan "${common[@]}" >/dev/null 2>&1; then
  fail "trivial passed gate evidence was accepted"
fi
[[ ! -s "$DRIVER_LOG" ]] \
  || fail "semantic gate rejection contacted the fleet driver"
cp "$WORK/release-good.json" "$GATE_RELEASE"
refresh_gate_binding

if FAKE_DRIVER_LOG="$DRIVER_LOG" \
  python3 "$ORCHESTRATOR" execute "${common[@]}" >/dev/null 2>&1
then
  fail "execute ran without explicit install authorization"
fi

write_inventory "$INVENTORY" good
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
run_execute >/dev/null
json_field_is "$EVIDENCE/fleet-canary-result.json" status passed
json_field_is \
  "$EVIDENCE/fleet-canary-result.json" \
  releaseGateManifestSha256 \
  "$GATE_RELEASE_SHA"
json_target_evidence_is \
  "$EVIDENCE/fleet-canary-result.json" good probe install

write_inventory \
  "$INVENTORY" \
  good inactive absent already-exact same-version-transition \
  unreachable noaccess report-only
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null
status=$?
set -e
[[ "$status" == 2 ]] || fail "incomplete access did not return status 2"
for target in good inactive absent already-exact same-version-transition; do
  json_status_is "$EVIDENCE/fleet-canary-result.json" "$target" passed
  grep -Fxq "install:$target" "$DRIVER_LOG" \
    || fail "$target was not installed"
done
json_target_install_transition_is \
  "$EVIDENCE/fleet-canary-result.json" good candidate-transition
json_target_install_transition_is \
  "$EVIDENCE/fleet-canary-result.json" absent fresh-install
json_target_install_transition_is \
  "$EVIDENCE/fleet-canary-result.json" already-exact reinstalled-exact
json_target_install_transition_is \
  "$EVIDENCE/fleet-canary-result.json" \
  same-version-transition candidate-transition
json_field_is \
  "$EVIDENCE/fleet-canary-result.json" \
  releaseGateManifestSha256 \
  "$GATE_RELEASE_SHA"
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" unreachable skipped-unreachable
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" noaccess skipped-unauthorized
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" report-only skipped-unauthorized
if grep -Eq 'install:(unreachable|noaccess|report-only)' "$DRIVER_LOG"; then
  fail "an unreachable or unauthorized target was installed"
fi

write_inventory "$INVENTORY" current
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null
status=$?
set -e
[[ "$status" == 2 ]] || fail "current-host exclusion did not return status 2"
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" current skipped-current-host
[[ ! -s "$DRIVER_LOG" ]] \
  || fail "current host was contacted despite frozen identity exclusion"

write_inventory "$INVENTORY" bad-process-inactive never
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null
status=$?
set -e
[[ "$status" == 1 ]] || fail "two-process result did not fail rollout"
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" \
  bad-process-inactive failed-rolled-back
json_target_evidence_is \
  "$EVIDENCE/fleet-canary-result.json" \
  bad-process-inactive probe install rollback
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" never blocked-by-prior-failure
grep -Fxq 'rollback:bad-process-inactive' "$DRIVER_LOG" \
  || fail "failed inactive-service target was not rolled back"
if grep -Fq 'install:never' "$DRIVER_LOG"; then
  fail "rollout continued after a failed canary"
fi

for adversary in \
  remote-build \
  wrong-roster \
  bad-raw \
  misdirected-unit \
  stale-main-process \
  already-exact-wrong
do
  write_inventory "$INVENTORY" "$adversary"
  rm -rf "$EVIDENCE"
  rm -f "$DRIVER_LOG"
  set +e
  run_execute >/dev/null
  status=$?
  set -e
  [[ "$status" == 1 ]] || fail "$adversary evidence was accepted"
  json_status_is \
    "$EVIDENCE/fleet-canary-result.json" "$adversary" failed-rolled-back
  if [[ "$adversary" == bad-raw ]]; then
    json_target_evidence_is \
      "$EVIDENCE/fleet-canary-result.json" \
      "$adversary" probe rollback
  else
    json_target_evidence_is \
      "$EVIDENCE/fleet-canary-result.json" \
      "$adversary" probe install rollback
  fi
  json_field_is \
    "$EVIDENCE/fleet-canary-result.json" \
    releaseGateManifestSha256 \
    "$GATE_RELEASE_SHA"
done

for adversary in rollback-fail rollback-stale-pid rollback-stale-image; do
  write_inventory "$INVENTORY" "$adversary"
  rm -rf "$EVIDENCE"
  rm -f "$DRIVER_LOG"
  set +e
  run_execute >/dev/null
  status=$?
  set -e
  [[ "$status" == 1 ]] || fail "$adversary rollback failure was accepted"
  json_status_is \
    "$EVIDENCE/fleet-canary-result.json" "$adversary" failed-rollback
  grep -Fxq "rollback:$adversary" "$DRIVER_LOG" \
    || fail "$adversary did not execute rollback"
done

write_inventory "$INVENTORY" pending never
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 1 ]] || fail "pending durable transaction was accepted"
if grep -Fq 'install:' "$DRIVER_LOG"; then
  fail "fleet mutation began after pending-transaction preflight failure"
fi

write_inventory "$INVENTORY" duplicate-one duplicate-two
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 1 ]] || fail "duplicate machine aliases were accepted"
if grep -Fq 'install:' "$DRIVER_LOG"; then
  fail "duplicate alias preflight mutated a target"
fi

write_inventory "$INVENTORY" malformed-probe-hash
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null
status=$?
set -e
[[ "$status" == 1 ]] || fail "malformed probe hash was accepted"
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" malformed-probe-hash probe-failed
json_field_is \
  "$EVIDENCE/fleet-canary-result.json" \
  releaseGateManifestSha256 \
  "$GATE_RELEASE_SHA"
if grep -Fq 'install:' "$DRIVER_LOG"; then
  fail "malformed probe evidence reached install"
fi

for adversary in \
  probe-drift-hash \
  probe-drift-app-version \
  probe-drift-fips-version
do
  write_inventory "$INVENTORY" "$adversary"
  rm -rf "$EVIDENCE"
  rm -f "$DRIVER_LOG"
  set +e
  run_execute >/dev/null
  status=$?
  set -e
  [[ "$status" == 1 ]] || fail "$adversary install evidence was accepted"
  json_status_is \
    "$EVIDENCE/fleet-canary-result.json" "$adversary" failed-rolled-back
  json_target_evidence_is \
    "$EVIDENCE/fleet-canary-result.json" \
    "$adversary" probe install rollback
  grep -Fxq "rollback:$adversary" "$DRIVER_LOG" \
    || fail "$adversary did not trigger rollback"
done

cp "$INVENTORY" "$APP/inventory-not-private.json"
if python3 "$ORCHESTRATOR" plan \
  --root "$APP" \
  --fips-root "$FIPS" \
  --inventory "$APP/inventory-not-private.json" \
  --manifest "$MANIFEST" \
  --evidence-dir "$EVIDENCE" >/dev/null 2>&1
then
  fail "unignored inventory was accepted"
fi
rm "$APP/inventory-not-private.json"

printf '# tamper\n' >>"$LINUX_HELPER"
if python3 "$ORCHESTRATOR" plan "${common[@]}" >/dev/null 2>&1; then
  fail "tampered checked-in driver helper was accepted"
fi
git -C "$APP" show HEAD:scripts/fleet_release_canary_remote_linux.py \
  >"$LINUX_HELPER"

printf 'tamper\n' >>"$ARTIFACT"
if python3 "$ORCHESTRATOR" plan "${common[@]}" >/dev/null 2>&1; then
  fail "tampered frozen artifact was accepted"
fi

printf 'fleet release canary adversarial harness passed\n'
