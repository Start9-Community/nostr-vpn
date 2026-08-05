import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import {
  chmodSync,
  existsSync,
  linkSync,
  lstatSync,
  readFileSync,
  realpathSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { isAbsolute, join, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'

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

function exactFleetJsonFile(path, label) {
  const binding = exactFleetFile(path, label)
  let value
  try {
    value = JSON.parse(readFileSync(binding.path, 'utf8'))
  } catch (error) {
    throw new Error(`${label} is invalid JSON: ${error.message}`)
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be a JSON object.`)
  }
  return { binding, value }
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
  return json ? exactFleetJsonFile(binding.path, label).value : null
}

export function fleetPublicationPaths({ repoRoot, options, env }) {
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
    proof:
      options.fleetProof
      || env.NVPN_FLEET_PROOF_PATH,
  }
  const supplied = Object.values(values).filter((value) => value).length
  if (supplied === 0) return null
  if (supplied !== Object.keys(values).length) {
    throw new Error('Fleet publication evidence paths must be supplied together.')
  }
  for (const [name, value] of Object.entries(values)) {
    if (!isAbsolute(value)) {
      throw new Error(
        `Fleet-gated publication requires an absolute --fleet-${name} path.`,
      )
    }
    values[name] = resolve(repoRoot, value)
  }
  return values
}

function exactKeys(value, keys, label) {
  if (
    !value
    || typeof value !== 'object'
    || Array.isArray(value)
    || !isDeepStrictEqual(Object.keys(value).sort(), [...keys].sort())
  ) {
    throw new Error(`${label} fields are not exact.`)
  }
}

function proofMetadata(path) {
  let metadata
  try {
    metadata = lstatSync(path)
  } catch {
    throw new Error(`Fleet authorization proof is missing: ${path}`)
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(
      'Fleet authorization proof must be a regular non-symlink file.',
    )
  }
  if ((metadata.mode & 0o777) !== 0o600) {
    throw new Error('Fleet authorization proof mode must be 0600.')
  }
  return {
    dev: metadata.dev,
    ino: metadata.ino,
    mode: metadata.mode,
    mtimeMs: metadata.mtimeMs,
    size: metadata.size,
  }
}

function assertProofMetadataUnchanged(path, before) {
  if (!isDeepStrictEqual(proofMetadata(path), before)) {
    throw new Error(
      'Fleet authorization proof changed while it was being validated.',
    )
  }
}

function readAuthorizationProof(path) {
  const before = proofMetadata(path)
  let value
  try {
    value = JSON.parse(readFileSync(realpathSync(path), 'utf8'))
  } catch (error) {
    throw new Error(
      `Fleet authorization proof is invalid JSON: ${error.message}`,
    )
  }
  exactKeys(
    value,
    [
      'evidence',
      'kind',
      'releaseTag',
      'schema',
      'source',
      'status',
      'targetCount',
      'targetSetSha256',
      'validatedAt',
    ],
    'Fleet authorization proof',
  )
  exactKeys(
    value.source,
    [
      'appGitSha',
      'appGitTree',
      'appVersion',
      'fipsGitSha',
      'fipsGitTree',
      'fipsVersion',
    ],
    'Fleet authorization proof source',
  )
  exactKeys(
    value.evidence,
    ['driver', 'inventory', 'manifest', 'release', 'result'],
    'Fleet authorization proof evidence',
  )
  for (const [name, binding] of Object.entries(value.evidence)) {
    exactKeys(
      binding,
      ['path', 'sha256', 'size'],
      `Fleet authorization proof ${name} binding`,
    )
  }
  if (
    value.schema !== 2
    || value.kind !== 'nvpn-fleet-publication-authorization-v2'
    || value.status !== 'passed'
    || !Number.isSafeInteger(value.validatedAt)
    || value.validatedAt <= 0
    || value.validatedAt > Math.floor(Date.now() / 1000) + 300
  ) {
    throw new Error('Fleet authorization proof metadata is invalid.')
  }
  assertProofMetadataUnchanged(path, before)
  return { before, value }
}

function buildAuthorizationProof({
  validatedAt,
  stagedManifest,
  source,
  files,
  inventory,
  result,
}) {
  return {
    schema: 2,
    kind: 'nvpn-fleet-publication-authorization-v2',
    status: 'passed',
    validatedAt,
    releaseTag: stagedManifest.tag,
    source,
    evidence: {
      result: files.result,
      manifest: files.manifest,
      inventory: files.inventory,
      release: files.release,
      driver: files.driver,
    },
    targetSetSha256: inventory.targetSetSha256,
    targetCount: result.targets.length,
  }
}

function writeAuthorizationProofNoReplace(path, proof) {
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`
  try {
    writeFileSync(temporary, `${JSON.stringify(proof, null, 2)}\n`, {
      flag: 'wx',
      mode: 0o600,
    })
    chmodSync(temporary, 0o600)
    try {
      linkSync(temporary, path)
    } catch (error) {
      if (error?.code !== 'EEXIST') {
        throw error
      }
    }
  } finally {
    if (existsSync(temporary)) {
      unlinkSync(temporary)
    }
  }
  const metadata = proofMetadata(path)
  const written = readAuthorizationProof(path)
  if (!isDeepStrictEqual(written.value, proof)) {
    throw new Error(
      'Existing fleet authorization proof differs from the exact authorization.',
    )
  }
  assertProofMetadataUnchanged(path, metadata)
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

function validateFleetPublication({
  repoRoot,
  options,
  env,
  stageDir,
  stagedManifest,
  validationTimeSeconds,
}) {
  const paths = fleetPublicationPaths({ repoRoot, options, env })
  const resultFile = exactFleetJsonFile(
    paths.result,
    'Fleet execute result',
  )
  const manifestFile = exactFleetJsonFile(
    paths.manifest,
    'Frozen fleet manifest',
  )
  const inventoryFile = exactFleetJsonFile(
    paths.inventory,
    'Frozen fleet inventory',
  )
  const result = resultFile.value
  const manifest = manifestFile.value
  const inventory = inventoryFile.value
  const catalog = verifyFleetBinding(
    inventory.rosterCatalog,
    'Private roster catalog',
    { json: true },
  )
  const snapshot = verifyFleetBinding(
    inventory.rosterSnapshot,
    'Authoritative roster snapshot',
    { json: true },
  )
  const currentMacReceipt = verifyFleetBinding(
    inventory.currentMacReceipt,
    'Measured current Mac receipt',
    { json: true },
  )
  const roleEvidence = {}
  for (const role of snapshot.roles ?? []) {
    verifyFleetBinding(
      role.evidence,
      `Authoritative roster evidence for ${role.id}`,
    )
    roleEvidence[role.id] = exactFleetJsonFile(
      role.evidence.path,
      `Authoritative roster evidence for ${role.id}`,
    ).value
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
    catalog,
    currentMacReceipt,
    roleEvidence,
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
      manifestSha256: manifestFile.binding.sha256,
      inventorySha256: inventoryFile.binding.sha256,
      driverSha256: driver.sha256,
      releaseGateManifestSha256: release.sha256,
    },
    helpers,
    manifest,
    result,
    rawReceipts,
    validationTimeSeconds,
  })
  replayCanonicalEvidence({ repoRoot, paths })
  return {
    files: {
      result: resultFile.binding,
      manifest: manifestFile.binding,
      inventory: inventoryFile.binding,
      release,
      driver,
    },
    inventory,
    manifest,
    paths,
    result,
    source: {
      appGitSha: stagedManifest.commit,
      appGitTree:
        stagedManifest.release_gate_attestation?.app_git_tree,
      appVersion: stagedManifest.tag.replace(/^v/, ''),
      fipsGitSha: manifest.fipsGitSha,
      fipsGitTree: manifest.fipsGitTree,
      fipsVersion: manifest.fipsVersion,
    },
    targetCount: result.targets.length,
  }
}

function assertProofMatchesValidation({
  proof,
  stagedManifest,
  validation,
}) {
  const expected = buildAuthorizationProof({
    validatedAt: proof.validatedAt,
    stagedManifest,
    source: validation.source,
    files: validation.files,
    inventory: validation.inventory,
    result: validation.result,
  })
  if (!isDeepStrictEqual(proof, expected)) {
    if (!isDeepStrictEqual(proof.evidence?.result, expected.evidence.result)) {
      throw new Error(
        'Fleet result differs from its authorization proof binding.',
      )
    }
    if (proof.releaseTag !== expected.releaseTag) {
      throw new Error('Release tag differs from its fleet authorization proof.')
    }
    if (!isDeepStrictEqual(proof.source, expected.source)) {
      throw new Error('Release source differs from its fleet authorization proof.')
    }
    throw new Error(
      'Fleet evidence differs from the exact authorization proof.',
    )
  }
}

export function authorizeFreshFleetPublication({
  repoRoot,
  options,
  env,
  stageDir,
  stagedManifest,
}) {
  const paths = fleetPublicationPaths({ repoRoot, options, env })
  const existing = existsSync(paths.proof)
    ? readAuthorizationProof(paths.proof)
    : null
  const validatedAt = Math.floor(Date.now() / 1000)
  const validation = validateFleetPublication({
    repoRoot,
    options,
    env,
    stageDir,
    stagedManifest,
    validationTimeSeconds: existing?.value.validatedAt ?? validatedAt,
  })
  if (existing) {
    assertProofMatchesValidation({
      proof: existing.value,
      stagedManifest,
      validation,
    })
    assertProofMetadataUnchanged(paths.proof, existing.before)
    return {
      proofPath: paths.proof,
      targetCount: validation.targetCount,
      validatedAt: existing.value.validatedAt,
    }
  }
  const proof = buildAuthorizationProof({
    validatedAt,
    stagedManifest,
    source: validation.source,
    files: validation.files,
    inventory: validation.inventory,
    result: validation.result,
  })
  writeAuthorizationProofNoReplace(paths.proof, proof)
  return {
    proofPath: paths.proof,
    targetCount: validation.targetCount,
    validatedAt,
  }
}

export function assertAuthorizedFleetPublication({
  repoRoot,
  options,
  env,
  stageDir,
  stagedManifest,
}) {
  const paths = fleetPublicationPaths({ repoRoot, options, env })
  const authorization = readAuthorizationProof(paths.proof)
  const validation = validateFleetPublication({
    repoRoot,
    options,
    env,
    stageDir,
    stagedManifest,
    validationTimeSeconds: authorization.value.validatedAt,
  })
  assertProofMatchesValidation({
    proof: authorization.value,
    stagedManifest,
    validation,
  })
  assertProofMetadataUnchanged(paths.proof, authorization.before)
  return {
    proofPath: paths.proof,
    targetCount: validation.targetCount,
    validatedAt: authorization.value.validatedAt,
  }
}
