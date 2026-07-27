import { spawnSync } from 'node:child_process'
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, resolve } from 'node:path'

import {
  semverFromTag,
  sha256FileSync,
} from './local-release-lib.mjs'

function exactFile(path, label) {
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file.`)
  }
  return metadata
}

function run(command, commandArgs, { cwd, env, capture = false } = {}) {
  const result = spawnSync(command, commandArgs, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: capture ? 'pipe' : 'inherit',
  })
  if (result.status !== 0) {
    throw new Error(
      (capture ? result.stderr.trim() || result.stdout.trim() : '')
      || `${command} ${commandArgs.join(' ')} failed.`,
    )
  }
  return capture ? result.stdout.trim() : ''
}

function exactJson(path, label) {
  exactFile(path, label)
  try {
    const value = JSON.parse(readFileSync(path, 'utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('not a JSON object')
    }
    return value
  } catch (error) {
    throw new Error(`${label} is invalid: ${error.message}`)
  }
}

function exactIpaPath(repoRoot) {
  const directory = join(repoRoot, 'dist', 'ios', 'export')
  const names = readdirSync(directory)
    .filter((name) => name.endsWith('.ipa'))
    .sort()
  if (names.length !== 1) {
    throw new Error(
      `Expected exactly one frozen App Store IPA; found ${names.length}.`,
    )
  }
  const path = join(directory, names[0])
  exactFile(path, 'Frozen App Store IPA')
  return path
}

function normalizedGate(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Staged release has no frozen iOS App Store gate.')
  }
  const keys = [
    'app_git_sha',
    'app_git_tree',
    'build_number',
    'bundle_id',
    'export_receipt_sha256',
    'ipa_sha256',
    'ipa_size',
    'marketing_version',
    'receipt_schema',
    'signer_certificate_sha256',
    'signing_team_id',
  ]
  if (
    JSON.stringify(Object.keys(value).sort())
    !== JSON.stringify(keys.sort())
  ) {
    throw new Error('Frozen iOS App Store gate fields are not exact.')
  }
  return value
}

export function validateFrozenIosPublication({ repoRoot, stagedManifest }) {
  const gate = normalizedGate(stagedManifest.ios_app_store_gate)
  const ipaPath = exactIpaPath(repoRoot)
  const receiptPath = join(
    repoRoot,
    'dist',
    'ios',
    'frozen',
    'app-store-receipt.json',
  )
  const receipt = exactJson(
    receiptPath,
    'Frozen iOS App Store export receipt',
  )
  const identity = receipt.identity ?? {}
  const signing = receipt.signing ?? {}
  const ipa = statSync(ipaPath)
  if (
    gate.receipt_schema !== 1
    || gate.app_git_sha !== stagedManifest.commit
    || gate.app_git_tree
      !== stagedManifest.release_gate_attestation?.app_git_tree
    || gate.marketing_version !== semverFromTag(stagedManifest.tag)
    || gate.bundle_id !== 'fi.siriusbusiness.nvpn'
    || !/^[1-9][0-9]*$/.test(String(gate.build_number ?? ''))
    || !/^[A-Z0-9]{10}$/.test(String(gate.signing_team_id ?? ''))
    || !/^[0-9a-f]{64}$/.test(
      String(gate.signer_certificate_sha256 ?? ''),
    )
    || !/^[0-9a-f]{64}$/.test(String(gate.ipa_sha256 ?? ''))
    || !/^[0-9a-f]{64}$/.test(
      String(gate.export_receipt_sha256 ?? ''),
    )
    || gate.ipa_size !== ipa.size
    || gate.ipa_sha256 !== sha256FileSync(ipaPath)
    || gate.export_receipt_sha256 !== sha256FileSync(receiptPath)
    || receipt.receiptSchema !== gate.receipt_schema
    || receipt.artifactType !== 'iOS export from frozen xcarchive'
    || receipt.distribution !== 'app-store-connect'
    || receipt.appGitSha !== gate.app_git_sha
    || receipt.appGitTree !== gate.app_git_tree
    || receipt.ipaSha256 !== gate.ipa_sha256
    || identity.appBundleIdentifier !== gate.bundle_id
    || identity.marketingVersion !== gate.marketing_version
    || String(identity.buildNumber) !== gate.build_number
    || identity.appBuildGitSha !== gate.app_git_sha
    || identity.packetTunnelBuildGitSha !== gate.app_git_sha
    || signing.signingTeamIdentifier !== gate.signing_team_id
    || signing.signerCertificateSha256
      !== gate.signer_certificate_sha256
  ) {
    throw new Error(
      'Frozen iOS App Store IPA or receipt differs from exact staging.',
    )
  }
  return { gate, ipaPath, receiptPath }
}

function parsePreflight(output, label) {
  const line = output.split(/\r?\n/).filter(Boolean).at(-1)
  try {
    const value = JSON.parse(line)
    if (!value || value.status !== 'passed') {
      throw new Error('status is not passed')
    }
    return value
  } catch (error) {
    throw new Error(`${label} returned invalid preflight evidence: ${error.message}`)
  }
}

function testflightPreflight({ repoRoot, mutationEnv }) {
  return parsePreflight(
    run(
      'bash',
      [join(repoRoot, 'scripts', 'testflight-internal'), 'preflight'],
      { cwd: repoRoot, env: mutationEnv, capture: true },
    ),
    'TestFlight',
  )
}

function uploadReceiptPath({ repoRoot, mutationEnv }) {
  return resolve(
    mutationEnv.NVPN_IOS_UPLOAD_RECEIPT_PATH
    || join(
      repoRoot,
      'dist',
      'ios',
      'frozen',
      'app-store-upload-receipt.json',
    ),
  )
}

function uploadReceiptValue({
  frozen,
  stagedManifest,
  mutationEnv,
  testflight,
}) {
  if (
    testflight.buildPresent !== true
    || typeof testflight.buildId !== 'string'
    || !testflight.buildId
    || typeof testflight.uploadedDate !== 'string'
    || !testflight.uploadedDate
  ) {
    throw new Error(
      'App Store Connect did not return an exact build ID and upload date.',
    )
  }
  return {
    schema: 1,
    kind: 'nvpn-ios-app-store-upload-v1',
    createdAt: Math.floor(Date.now() / 1000),
    appGitSha: stagedManifest.commit,
    appGitTree: stagedManifest.release_gate_attestation.app_git_tree,
    releaseTag: stagedManifest.tag,
    stageReleaseSha256: sha256FileSync(
      join(mutationEnv.NVPN_RELEASE_STAGE_DIR, 'release.json'),
    ),
    fleetResultSha256: sha256FileSync(
      mutationEnv.NVPN_FLEET_RESULT_PATH,
    ),
    fleetManifestSha256: sha256FileSync(
      mutationEnv.NVPN_FLEET_MANIFEST_PATH,
    ),
    fleetInventorySha256: sha256FileSync(
      mutationEnv.NVPN_FLEET_INVENTORY_PATH,
    ),
    ipaSha256: frozen.gate.ipa_sha256,
    ipaSize: frozen.gate.ipa_size,
    bundleId: frozen.gate.bundle_id,
    version: frozen.gate.marketing_version,
    buildNumber: frozen.gate.build_number,
    ascBuildId: testflight.buildId,
    ascUploadedDate: testflight.uploadedDate,
  }
}

export function validateIosUploadReceipt({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  testflight,
}) {
  const path = uploadReceiptPath({ repoRoot, mutationEnv })
  if (!existsSync(path)) {
    throw new Error(
      'Existing App Store Connect build has no fleet-bound exact upload receipt.',
    )
  }
  const actual = exactJson(path, 'Fleet-bound iOS upload receipt')
  const expected = uploadReceiptValue({
    frozen,
    stagedManifest,
    mutationEnv,
    testflight,
  })
  const keys = Object.keys(expected).sort()
  if (
    JSON.stringify(Object.keys(actual).sort()) !== JSON.stringify(keys)
    || keys.some(
      (key) => key !== 'createdAt' && actual[key] !== expected[key],
    )
    || !Number.isSafeInteger(actual.createdAt)
    || actual.createdAt <= 0
  ) {
    throw new Error(
      'Existing App Store Connect build differs from its fleet-bound upload receipt.',
    )
  }
  return path
}

function writeUploadReceipt({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  testflight,
}) {
  const path = uploadReceiptPath({ repoRoot, mutationEnv })
  const value = uploadReceiptValue({
    frozen,
    stagedManifest,
    mutationEnv,
    testflight,
  })
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.tmp-${process.pid}`
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    mode: 0o600,
  })
  chmodSync(temporary, 0o600)
  renameSync(temporary, path)
  chmodSync(path, 0o600)
  return path
}

export function preflightIosPublication({
  repoRoot,
  stagedManifest,
  mutationEnv,
  dryRun = false,
}) {
  const frozen = validateFrozenIosPublication({
    repoRoot,
    stagedManifest,
  })
  if (dryRun) {
    return { ...frozen, buildPresent: false, dryRun: true }
  }
  const transporter =
    mutationEnv.NVPN_ITMS_TRANSPORTER
    || '/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter'
  const transporterMetadata = exactFile(
    transporter,
    'Apple iTMSTransporter',
  )
  if ((transporterMetadata.mode & 0o111) === 0) {
    throw new Error(`Apple iTMSTransporter is not executable: ${transporter}`)
  }

  const testflight = testflightPreflight({ repoRoot, mutationEnv })
  const appStore = parsePreflight(
    run(
      'bash',
      [join(repoRoot, 'scripts', 'appstore-draft'), 'preflight'],
      { cwd: repoRoot, env: mutationEnv, capture: true },
    ),
    'App Store',
  )
  for (const evidence of [testflight, appStore]) {
    if (
      evidence.bundleId !== frozen.gate.bundle_id
      || evidence.version !== frozen.gate.marketing_version
      || String(evidence.buildNumber) !== frozen.gate.build_number
    ) {
      throw new Error('App Store Connect preflight differs from frozen iOS staging.')
    }
  }
  if (testflight.buildPresent) {
    validateIosUploadReceipt({
      repoRoot,
      frozen,
      stagedManifest,
      mutationEnv,
      testflight,
    })
  } else if (
    existsSync(uploadReceiptPath({ repoRoot, mutationEnv }))
  ) {
    throw new Error(
      'Fleet-bound iOS upload receipt exists but App Store Connect has no exact build.',
    )
  }
  return {
    ...frozen,
    appStore,
    buildPresent: testflight.buildPresent === true,
    dryRun: false,
    testflight,
  }
}

export function publishExactIosDistribution({
  repoRoot,
  stagedManifest,
  mutationEnv,
  preflight,
  dryRun = false,
}) {
  validateFrozenIosPublication({ repoRoot, stagedManifest })
  if (dryRun) {
    return { submitted: false, verified: true }
  }
  if (
    !preflight
    || preflight.dryRun
    || preflight.gate?.ipa_sha256
      !== stagedManifest.ios_app_store_gate.ipa_sha256
  ) {
    throw new Error('iOS publication preflight does not bind exact staging.')
  }

  if (!preflight.buildPresent) {
    validateFrozenIosPublication({ repoRoot, stagedManifest })
    run(
      'bash',
      [join(repoRoot, 'scripts', 'ios-build'), 'ios-upload'],
      { cwd: repoRoot, env: mutationEnv },
    )
    run(
      'bash',
      [join(repoRoot, 'scripts', 'testflight-internal'), 'wait'],
      { cwd: repoRoot, env: mutationEnv },
    )
    const uploaded = testflightPreflight({ repoRoot, mutationEnv })
    writeUploadReceipt({
      repoRoot,
      frozen: validateFrozenIosPublication({ repoRoot, stagedManifest }),
      stagedManifest,
      mutationEnv,
      testflight: uploaded,
    })
  } else {
    validateIosUploadReceipt({
      repoRoot,
      frozen: validateFrozenIosPublication({ repoRoot, stagedManifest }),
      stagedManifest,
      mutationEnv,
      testflight: preflight.testflight,
    })
  }
  for (const [script, action] of [
    ['testflight-internal', 'put'],
    ['testflight-internal', 'public'],
  ]) {
    run(
      'bash',
      [join(repoRoot, 'scripts', script), action],
      { cwd: repoRoot, env: mutationEnv },
    )
  }
  const submittedStates = new Set([
    'WAITING_FOR_REVIEW',
    'IN_REVIEW',
    'PENDING_APPLE_RELEASE',
    'PROCESSING_FOR_DISTRIBUTION',
    'READY_FOR_DISTRIBUTION',
    'READY_FOR_SALE',
  ])
  if (
    !submittedStates.has(preflight.appStore?.reviewState)
    && !submittedStates.has(preflight.appStore?.versionState)
  ) {
    run(
      'bash',
      [join(repoRoot, 'scripts', 'appstore-draft'), 'submit'],
      { cwd: repoRoot, env: mutationEnv },
    )
  }
  for (const [script, action] of [
    ['testflight-internal', 'public-status'],
    ['appstore-draft', 'status'],
  ]) {
    run(
      'bash',
      [join(repoRoot, 'scripts', script), action],
      { cwd: repoRoot, env: mutationEnv },
    )
  }
  return { submitted: true, verified: true }
}
