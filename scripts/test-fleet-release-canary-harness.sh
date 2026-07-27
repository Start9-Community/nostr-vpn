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
DRIVER_LOG="$WORK/driver.log"
LOCAL_ID="$(printf 'a%.0s' {1..64})"

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
+service = {
+    "installed": not absent,
+    "enabled": not (inactive or absent),
+    "running": not (inactive or absent),
+    "binaryPresent": not absent,
+    "binarySha256": (
+        None if absent else digest(f"prior-binary:{target_id}")
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
+            "service": service,
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
+                "processCount": (
+                    2
+                    if target_id in {
+                        "bad-process",
+                        "bad-process-inactive",
+                        "rollback-fail",
+                    }
+                    else 1
+                ),
+                "pidBeforeRestart": 100,
+                "pidAfterRestart": 101,
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
ARTIFACT="$APP/artifacts/nvpn"
GATE="$APP/artifacts/release-gate.json"
RECEIPT="$APP/artifacts/linux-receipt.json"
MANIFEST="$APP/private/manifest.json"
INVENTORY="$APP/private/inventory.json"
EVIDENCE="$APP/private/evidence"

printf 'immutable candidate binary\n' >"$ARTIFACT"
printf '{"passed":true}\n' >"$GATE"
ARTIFACT_SHA="$(sha256_file "$ARTIFACT")"
ARTIFACT_SIZE="$(wc -c <"$ARTIFACT" | tr -d '[:space:]')"
GATE_SHA="$(sha256_file "$GATE")"
GATE_SIZE="$(wc -c <"$GATE" | tr -d '[:space:]')"

python3 - \
  "$RECEIPT" "$APP_SHA" "$APP_TREE" "$FIPS_SHA" "$FIPS_TREE" \
  "$ARTIFACT_SHA" "$ARTIFACT_SIZE" <<'PY'
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
) = sys.argv[1:]
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
    "installedBinarySha256": artifact_sha,
    "installedPayloads": {"executable": artifact_sha},
    "gateEvidenceIds": ["full-release-gate"],
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

python3 - \
  "$MANIFEST" "$APP_SHA" "$APP_TREE" "$FIPS_SHA" "$FIPS_TREE" \
  "$DRIVER" "$LINUX_HELPER" "$WINDOWS_HELPER" \
  "$ARTIFACT" "$RECEIPT" "$GATE" <<'PY'
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
    gate,
) = sys.argv[1:]

def bound(path):
    value = pathlib.Path(path)
    return {
        "path": str(value),
        "sha256": hashlib.sha256(value.read_bytes()).hexdigest(),
        "size": value.stat().st_size,
    }

artifact_bound = bound(artifact)
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
    "gateEvidence": [{"id": "full-release-gate", **bound(gate)}],
    "artifacts": [
        {
            "id": "linux-x86_64",
            "platform": "linux",
            "arch": "x86_64",
            **artifact_bound,
            "installPayload": {
                "format": "executable",
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
  NVPN_FLEET_LOCAL_MACHINE_ID_SHA256="$LOCAL_ID" \
  FAKE_DRIVER_LOG="$DRIVER_LOG" \
    python3 "$ORCHESTRATOR" execute "${common[@]}"
}

python3 -m py_compile \
  "$ORCHESTRATOR" \
  "$ROOT/scripts/fleet_release_canary_evidence.py" \
  "$ROOT/scripts/fleet_release_canary_ssh_driver.py" \
  "$ROOT/scripts/fleet_release_canary_remote_linux.py" \
  "$DRIVER"
bash -n "$0"
windows_adapter="$ROOT/scripts/fleet_release_canary_remote_windows.ps1"
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
restore = text[text.index("function RestoreTransaction"):text.index(
    "function InstallCandidate"
)]
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

if NVPN_FLEET_LOCAL_MACHINE_ID_SHA256="$LOCAL_ID" \
  FAKE_DRIVER_LOG="$DRIVER_LOG" \
  python3 "$ORCHESTRATOR" execute "${common[@]}" >/dev/null 2>&1
then
  fail "execute ran without explicit install authorization"
fi

write_inventory \
  "$INVENTORY" good inactive absent unreachable noaccess report-only
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null
status=$?
set -e
[[ "$status" == 2 ]] || fail "incomplete access did not return status 2"
for target in good inactive absent; do
  json_status_is "$EVIDENCE/fleet-canary-result.json" "$target" passed
  grep -Fxq "install:$target" "$DRIVER_LOG" \
    || fail "$target was not installed"
done
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
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" never blocked-by-prior-failure
grep -Fxq 'rollback:bad-process-inactive' "$DRIVER_LOG" \
  || fail "failed inactive-service target was not rolled back"
if grep -Fq 'install:never' "$DRIVER_LOG"; then
  fail "rollout continued after a failed canary"
fi

for adversary in remote-build wrong-roster bad-raw; do
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
done

write_inventory "$INVENTORY" rollback-fail
rm -rf "$EVIDENCE"
rm -f "$DRIVER_LOG"
set +e
run_execute >/dev/null
status=$?
set -e
[[ "$status" == 1 ]] || fail "rollback failure was accepted"
json_status_is \
  "$EVIDENCE/fleet-canary-result.json" rollback-fail failed-rollback

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
