import { spawnSync } from 'node:child_process'
import {
  lstatSync,
  readFileSync,
  realpathSync,
} from 'node:fs'
import { isAbsolute, join, resolve } from 'node:path'

import { sha256FileSync } from './local-release-lib.mjs'
import { validateFleetPublicationMetadata } from './fleet-release-preparer-lib.mjs'

function exactFleetFile(path, label) {
  if (!path || !isAbsolute(path)) {
    throw new Error(`${label} must be an absolute path.`)
  }
  let metadata
  try {
    metadata = lstatSync(path)
  } catch {
    throw new Error(`${label} is missing: ${path}`)
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file.`)
  }
  const canonicalPath = realpathSync(path)
  return {
    path: canonicalPath,
    sha256: sha256FileSync(canonicalPath),
    size: metadata.size,
  }
}

function exactFleetJson(path, label) {
  exactFleetFile(path, label)
  let value
  try {
    value = JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    throw new Error(`${label} is invalid JSON: ${error.message}`)
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be a JSON object.`)
  }
  return value
}

function verifyFleetBinding(binding, label, { json = false } = {}) {
  const actual = exactFleetFile(binding?.path, label)
  if (
    binding.path !== actual.path
    || binding.sha256 !== actual.sha256
    || binding.size !== actual.size
  ) {
    throw new Error(`${label} differs from its fleet evidence binding.`)
  }
  return json ? exactFleetJson(binding.path, label) : null
}

function fleetPublicationPaths({ repoRoot, options, env }) {
  const values = {
    result:
      options.fleetResult
      || env.NVPN_FLEET_RESULT_PATH,
    manifest:
      options.fleetManifest
      || env.NVPN_FLEET_MANIFEST_PATH,
    inventory:
      options.fleetInventory
      || env.NVPN_FLEET_INVENTORY_PATH,
  }
  for (const [name, value] of Object.entries(values)) {
    if (!String(value ?? '').trim()) {
      throw new Error(
        `Fleet-gated publication requires --fleet-${name} (or NVPN_FLEET_${name.toUpperCase()}_PATH).`,
      )
    }
    values[name] = resolve(repoRoot, value)
  }
  return values
}

function replayCanonicalEvidence({ repoRoot, paths }) {
  const replay = spawnSync(
    'python3',
    [
      join(repoRoot, 'scripts', 'fleet_release_result_replay.py'),
      '--result',
      paths.result,
      '--manifest',
      paths.manifest,
      '--inventory',
      paths.inventory,
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: 'pipe',
    },
  )
  if (replay.status !== 0) {
    throw new Error(
      replay.stderr.trim()
      || replay.stdout.trim()
      || 'Canonical fleet evidence replay failed.',
    )
  }
}

export function assertPassedFleetPublication({
  repoRoot,
  options,
  env,
  stageDir,
  stagedManifest,
}) {
  const paths = fleetPublicationPaths({ repoRoot, options, env })
  const result = exactFleetJson(paths.result, 'Fleet execute result')
  const manifest = exactFleetJson(paths.manifest, 'Frozen fleet manifest')
  const inventory = exactFleetJson(
    paths.inventory,
    'Frozen fleet inventory',
  )
  const snapshot = verifyFleetBinding(
    inventory.rosterSnapshot,
    'Authoritative roster snapshot',
    { json: true },
  )
  for (const role of snapshot.roles ?? []) {
    verifyFleetBinding(
      role.evidence,
      `Authoritative roster evidence for ${role.id}`,
    )
  }

  const driver = exactFleetFile(
    join(repoRoot, 'scripts', 'fleet_release_canary_ssh_driver.py'),
    'Production fleet driver',
  )
  const helpers = [
    'fleet_release_canary_remote_linux.py',
    'fleet_release_canary_remote_windows.ps1',
  ].map((name) =>
    exactFleetFile(
      join(repoRoot, 'scripts', name),
      `Production fleet helper ${name}`,
    ),
  )
  const rawReceipts = Object.fromEntries(
    (result.targets ?? []).map((target) => [
      target.id,
      {
        probe: {
          binding: target.evidence?.probe,
          value: verifyFleetBinding(
            target.evidence?.probe,
            `Fleet probe raw receipt for ${target.id}`,
            { json: true },
          ),
        },
        install: {
          binding: target.evidence?.install,
          value: verifyFleetBinding(
            target.evidence?.install,
            `Fleet install raw receipt for ${target.id}`,
            { json: true },
          ),
        },
      },
    ]),
  )
  const release = exactFleetFile(
    resolve(stageDir, 'release.json'),
    'Staged release manifest',
  )
  validateFleetPublicationMetadata({
    snapshot,
    inventory,
    source: {
      appGitSha: stagedManifest.commit,
      appGitTree:
        stagedManifest.release_gate_attestation?.app_git_tree,
      appVersion: stagedManifest.tag.replace(/^v/, ''),
      fipsGitSha: manifest.fipsGitSha,
      fipsGitTree: manifest.fipsGitTree,
      fipsVersion: manifest.fipsVersion,
    },
    paths: {
      release: release.path,
      driver: driver.path,
    },
    hashes: {
      manifestSha256: sha256FileSync(paths.manifest),
      inventorySha256: sha256FileSync(paths.inventory),
      driverSha256: driver.sha256,
      releaseGateManifestSha256: release.sha256,
    },
    helpers,
    manifest,
    result,
    rawReceipts,
  })
  replayCanonicalEvidence({ repoRoot, paths })
  return result.targets.length
}
