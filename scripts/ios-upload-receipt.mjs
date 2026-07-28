import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { randomUUID } from 'node:crypto'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'

import {
  assertAuthorizedFleetPublication,
} from './fleet-release-publication-lib.mjs'
import { sha256FileSync } from './local-release-lib.mjs'

function exactKeys(value, keys, label) {
  const actual = Object.keys(value ?? {}).sort()
  const expected = [...keys].sort()
  if (
    !value
    || typeof value !== 'object'
    || Array.isArray(value)
    || JSON.stringify(actual) !== JSON.stringify(expected)
  ) {
    throw new Error(`${label} fields are not exact.`)
  }
}

function exactFileBinding(path, label) {
  if (!path || !isAbsolute(path)) {
    throw new Error(`${label} path must be absolute.`)
  }
  let metadata
  try {
    metadata = lstatSync(path)
  } catch {
    throw new Error(`${label} is missing.`)
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file.`)
  }
  const canonical = realpathSync(path)
  return {
    path: canonical,
    sha256: sha256FileSync(canonical),
    size: metadata.size,
  }
}

function validateFileBinding(binding, label) {
  exactKeys(binding, ['path', 'sha256', 'size'], `${label} binding`)
  const actual = exactFileBinding(binding.path, label)
  if (
    binding.path !== actual.path
    || binding.sha256 !== actual.sha256
    || binding.size !== actual.size
  ) {
    throw new Error(`${label} differs from its upload authorization binding.`)
  }
  return actual
}

function exactJson(path, label) {
  exactFileBinding(path, label)
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

function writePrivateJson(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`
  let renamed = false
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      flag: 'wx',
      mode: 0o600,
    })
    chmodSync(temporary, 0o600)
    renameSync(temporary, path)
    renamed = true
    chmodSync(path, 0o600)
  } finally {
    if (!renamed && existsSync(temporary)) {
      unlinkSync(temporary)
    }
  }
}

export function iosUploadReceiptPaths({ repoRoot, mutationEnv }) {
  const final = resolve(
    mutationEnv.NVPN_IOS_UPLOAD_RECEIPT_PATH
    || join(
      repoRoot,
      'dist',
      'ios',
      'frozen',
      'app-store-upload-receipt.json',
    ),
  )
  const pending = resolve(
    mutationEnv.NVPN_IOS_PENDING_UPLOAD_RECEIPT_PATH
    || join(
      repoRoot,
      'dist',
      'ios',
      'frozen',
      'app-store-pending-upload-receipt.json',
    ),
  )
  if (final === pending) {
    throw new Error('Final and pending iOS upload receipt paths must differ.')
  }
  return { final, pending }
}

function uploadIdentity({ frozen, stagedManifest, mutationEnv }) {
  return {
    appGitSha: stagedManifest.commit,
    appGitTree: stagedManifest.release_gate_attestation.app_git_tree,
    releaseTag: stagedManifest.tag,
    stageRelease: exactFileBinding(
      join(mutationEnv.NVPN_RELEASE_STAGE_DIR, 'release.json'),
      'Staged release manifest',
    ),
    ipa: exactFileBinding(frozen.ipaPath, 'Frozen App Store IPA'),
    ipaSha256: frozen.gate.ipa_sha256,
    ipaSize: frozen.gate.ipa_size,
    bundleId: frozen.gate.bundle_id,
    version: frozen.gate.marketing_version,
    buildNumber: frozen.gate.build_number,
  }
}

function fleetAuthorization(mutationEnv) {
  const proof = exactFileBinding(
    mutationEnv.NVPN_FLEET_PROOF_PATH,
    'Historical fleet authorization proof',
  )
  const authorization = exactJson(
    proof.path,
    'Historical fleet authorization proof',
  )
  return {
    authorizedAt: authorization.validatedAt,
    result: exactFileBinding(
      mutationEnv.NVPN_FLEET_RESULT_PATH,
      'Historical fleet result',
    ),
    manifest: exactFileBinding(
      mutationEnv.NVPN_FLEET_MANIFEST_PATH,
      'Historical fleet manifest',
    ),
    inventory: exactFileBinding(
      mutationEnv.NVPN_FLEET_INVENTORY_PATH,
      'Historical fleet inventory',
    ),
    proof,
  }
}

export function validateHistoricalIosFleetAuthorization({
  repoRoot,
  authorization,
  stageDir,
  stagedManifest,
  env,
  validatePublication = assertAuthorizedFleetPublication,
}) {
  exactKeys(
    authorization,
    ['authorizedAt', 'inventory', 'manifest', 'proof', 'result'],
    'Historical iOS fleet authorization',
  )
  if (
    !Number.isSafeInteger(authorization.authorizedAt)
    || authorization.authorizedAt <= 0
    || authorization.authorizedAt > Math.floor(Date.now() / 1000) + 300
  ) {
    throw new Error('Historical iOS fleet authorization time is invalid.')
  }
  for (const [name, label] of [
    ['result', 'Historical fleet result'],
    ['manifest', 'Historical fleet manifest'],
    ['inventory', 'Historical fleet inventory'],
    ['proof', 'Historical fleet authorization proof'],
  ]) {
    validateFileBinding(authorization[name], label)
  }
  const validation = validatePublication({
    repoRoot,
    options: {
      fleetResult: authorization.result.path,
      fleetManifest: authorization.manifest.path,
      fleetInventory: authorization.inventory.path,
      fleetProof: authorization.proof.path,
    },
    env,
    stageDir,
    stagedManifest,
  })
  if (validation.validatedAt !== authorization.authorizedAt) {
    throw new Error(
      'Historical iOS fleet authorization time differs from its exact proof.',
    )
  }
  return authorization
}

function validateUploadIdentity({
  receipt,
  frozen,
  stagedManifest,
  mutationEnv,
}) {
  const expected = uploadIdentity({ frozen, stagedManifest, mutationEnv })
  for (const key of [
    'appGitSha',
    'appGitTree',
    'releaseTag',
    'ipaSha256',
    'ipaSize',
    'bundleId',
    'version',
    'buildNumber',
  ]) {
    if (receipt[key] !== expected[key]) {
      throw new Error('iOS upload receipt differs from exact frozen staging.')
    }
  }
  for (const key of ['stageRelease', 'ipa']) {
    validateFileBinding(receipt[key], `iOS upload ${key}`)
    if (JSON.stringify(receipt[key]) !== JSON.stringify(expected[key])) {
      throw new Error('iOS upload receipt differs from exact frozen staging.')
    }
  }
}

const pendingKeys = [
  'appGitSha',
  'appGitTree',
  'buildNumber',
  'bundleId',
  'fleetAuthorization',
  'ipa',
  'ipaSha256',
  'ipaSize',
  'kind',
  'releaseTag',
  'schema',
  'stageRelease',
  'transporterAcceptedAt',
  'version',
]

function validatePendingValue({
  repoRoot,
  receipt,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
}) {
  exactKeys(receipt, pendingKeys, 'Pending iOS upload receipt')
  if (
    receipt.schema !== 1
    || receipt.kind !== 'nvpn-ios-app-store-pending-upload-v1'
    || !Number.isSafeInteger(receipt.transporterAcceptedAt)
    || receipt.transporterAcceptedAt <= 0
    || receipt.transporterAcceptedAt > Math.floor(Date.now() / 1000) + 300
    || receipt.transporterAcceptedAt < receipt.fleetAuthorization?.authorizedAt
  ) {
    throw new Error('Pending iOS upload receipt is invalid.')
  }
  validateUploadIdentity({ receipt, frozen, stagedManifest, mutationEnv })
  validateHistoricalIosFleetAuthorization({
    repoRoot,
    authorization: receipt.fleetAuthorization,
    stageDir: mutationEnv.NVPN_RELEASE_STAGE_DIR,
    stagedManifest,
    env: mutationEnv,
    validatePublication,
  })
  return receipt
}

export function validateIosPendingUploadReceipt({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
}) {
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).pending
  if (!existsSync(path)) {
    throw new Error('Pending fleet-authorized iOS upload receipt is missing.')
  }
  return {
    path,
    value: validatePendingValue({
      repoRoot,
      receipt: exactJson(path, 'Pending fleet-authorized iOS upload receipt'),
      frozen,
      stagedManifest,
      mutationEnv,
      validatePublication,
    }),
  }
}

export function validateIosUploadReceipt({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  testflight,
  validatePublication,
}) {
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).final
  if (!existsSync(path)) {
    throw new Error(
      'Existing App Store Connect build has no fleet-bound exact upload receipt.',
    )
  }
  const receipt = exactJson(path, 'Fleet-bound iOS upload receipt')
  exactKeys(
    receipt,
    [...pendingKeys, 'ascBuildId', 'ascUploadedDate', 'createdAt'],
    'Final iOS upload receipt',
  )
  if (
    receipt.schema !== 2
    || receipt.kind !== 'nvpn-ios-app-store-upload-v2'
    || !Number.isSafeInteger(receipt.createdAt)
    || receipt.createdAt <= 0
    || receipt.createdAt > Math.floor(Date.now() / 1000) + 300
    || receipt.createdAt < receipt.transporterAcceptedAt
    || receipt.ascBuildId !== testflight.buildId
    || receipt.ascUploadedDate !== testflight.uploadedDate
  ) {
    throw new Error('Final iOS upload receipt is invalid.')
  }
  const pending = Object.fromEntries(
    pendingKeys.map((key) => [key, receipt[key]]),
  )
  pending.schema = 1
  pending.kind = 'nvpn-ios-app-store-pending-upload-v1'
  validatePendingValue({
    repoRoot,
    receipt: pending,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
  return path
}

export function captureIosPendingUploadAuthorization({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
}) {
  const value = {
    schema: 1,
    kind: 'nvpn-ios-app-store-pending-upload-v1',
    ...uploadIdentity({ frozen, stagedManifest, mutationEnv }),
    fleetAuthorization: fleetAuthorization(mutationEnv),
  }
  validateHistoricalIosFleetAuthorization({
    repoRoot,
    authorization: value.fleetAuthorization,
    stageDir: mutationEnv.NVPN_RELEASE_STAGE_DIR,
    stagedManifest,
    env: mutationEnv,
    validatePublication,
  })
  return value
}

export function writeAcceptedIosPendingUpload({
  repoRoot,
  mutationEnv,
  authorization,
  transporterAcceptedAt = Math.floor(Date.now() / 1000),
}) {
  exactKeys(
    authorization,
    pendingKeys.filter((key) => key !== 'transporterAcceptedAt'),
    'In-memory iOS upload authorization',
  )
  if (
    !Number.isSafeInteger(transporterAcceptedAt)
    || transporterAcceptedAt <= 0
    || transporterAcceptedAt > Math.floor(Date.now() / 1000) + 300
    || transporterAcceptedAt < authorization.fleetAuthorization?.authorizedAt
  ) {
    throw new Error('Transporter acceptance time is invalid.')
  }
  const value = { ...authorization, transporterAcceptedAt }
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).pending
  writePrivateJson(path, value)
  return { path, value }
}

export function finalizeIosUploadReceipt({
  repoRoot,
  mutationEnv,
  pendingReceipt,
  testflight,
  createdAt = Math.floor(Date.now() / 1000),
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
  if (
    !Number.isSafeInteger(createdAt)
    || createdAt <= 0
    || createdAt > Math.floor(Date.now() / 1000) + 300
    || createdAt < pendingReceipt.value?.transporterAcceptedAt
  ) {
    throw new Error('Final iOS upload receipt time is invalid.')
  }
  const value = {
    ...pendingReceipt.value,
    schema: 2,
    kind: 'nvpn-ios-app-store-upload-v2',
    createdAt,
    ascBuildId: testflight.buildId,
    ascUploadedDate: testflight.uploadedDate,
  }
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).final
  writePrivateJson(path, value)
  return { path, value }
}

export function removeIosPendingUploadReceipt(pendingReceipt) {
  if (pendingReceipt) {
    unlinkSync(pendingReceipt.path)
  }
}

export function planIosUploadReconciliation({
  buildPresent,
  finalReceipt,
  pendingReceipt,
  matchingReceiptPair = false,
}) {
  if (finalReceipt && pendingReceipt) {
    if (!buildPresent) {
      throw new Error(
        'Final fleet-bound iOS upload receipt exists but App Store Connect has no exact build.',
      )
    }
    if (!matchingReceiptPair) {
      throw new Error(
        'Final and pending iOS upload receipts coexist, but a matching pair was not proven.',
      )
    }
    return 'cleanup-pending-use-final'
  }
  if (buildPresent && !finalReceipt && !pendingReceipt) {
    throw new Error(
      'Existing App Store Connect build has no fleet-authorized exact upload receipt.',
    )
  }
  if (!buildPresent && finalReceipt) {
    throw new Error(
      'Final fleet-bound iOS upload receipt exists but App Store Connect has no exact build.',
    )
  }
  if (finalReceipt) {
    return 'use-final'
  }
  if (pendingReceipt) {
    return buildPresent ? 'finalize-pending' : 'wait-pending'
  }
  return 'upload'
}

export function reconcileIosUploadReceipts({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  testflight,
  validatePublication,
}) {
  const paths = iosUploadReceiptPaths({ repoRoot, mutationEnv })
  const finalExists = existsSync(paths.final)
  const finalReceipt = finalExists && testflight.buildPresent
    ? validateIosUploadReceipt({
        repoRoot,
        frozen,
        stagedManifest,
        mutationEnv,
        testflight,
        validatePublication,
      })
    : finalExists
      ? paths.final
      : null
  const pendingReceipt = existsSync(paths.pending)
    ? validateIosPendingUploadReceipt({
        repoRoot,
        frozen,
        stagedManifest,
        mutationEnv,
        validatePublication,
      })
    : null
  let matchingReceiptPair = false
  if (finalReceipt && pendingReceipt) {
    const finalValue = exactJson(
      paths.final,
      'Fleet-bound iOS upload receipt',
    )
    const finalPendingValue = Object.fromEntries(
      pendingKeys.map((key) => [key, finalValue[key]]),
    )
    finalPendingValue.schema = 1
    finalPendingValue.kind = 'nvpn-ios-app-store-pending-upload-v1'
    if (!isDeepStrictEqual(finalPendingValue, pendingReceipt.value)) {
      throw new Error(
        'Pending and final iOS upload receipts differ; refusing cleanup.',
      )
    }
    matchingReceiptPair = true
  }
  return {
    finalReceipt,
    pendingReceipt,
    uploadAction: planIosUploadReconciliation({
      buildPresent: testflight.buildPresent === true,
      finalReceipt,
      pendingReceipt,
      matchingReceiptPair,
    }),
  }
}
