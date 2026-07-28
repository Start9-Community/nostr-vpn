import {
  closeSync,
  existsSync,
  fchmodSync,
  fsyncSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { createHash, randomUUID } from 'node:crypto'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'

import {
  assertAuthorizedFleetPublication,
} from './fleet-release-publication-lib.mjs'
import { sha256FileSync } from './local-release-lib.mjs'

const clockSkewSeconds = 300
const attemptIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

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
  if (!isDeepStrictEqual(binding, actual)) {
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

function journalMetadata(path, label) {
  let metadata
  try {
    metadata = lstatSync(path)
  } catch {
    throw new Error(`${label} is missing.`)
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file.`)
  }
  if ((metadata.mode & 0o777) !== 0o600) {
    throw new Error(`${label} mode must be 0600.`)
  }
  return metadata
}

function readPrivateJournal(path, label) {
  const before = journalMetadata(path, label)
  const bytes = readFileSync(path)
  const canonical = realpathSync(path)
  const after = journalMetadata(path, label)
  for (const key of ['dev', 'ino', 'mode', 'mtimeMs', 'size']) {
    if (before[key] !== after[key]) {
      throw new Error(`${label} changed while it was being validated.`)
    }
  }
  let value
  try {
    value = JSON.parse(bytes.toString('utf8'))
  } catch (error) {
    throw new Error(`${label} is invalid JSON: ${error.message}`)
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} is not a JSON object.`)
  }
  return {
    binding: {
      path: canonical,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      size: bytes.length,
    },
    bytes,
    path: canonical,
    value,
  }
}

function fsyncDirectory(path) {
  const descriptor = openSync(path, 'r')
  try {
    fsyncSync(descriptor)
  } finally {
    closeSync(descriptor)
  }
}

function writePrivateJournalNoReplace(path, value, label) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const bytes = Buffer.from(`${JSON.stringify(value, null, 2)}\n`)
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`
  let descriptor
  let created = false
  try {
    descriptor = openSync(temporary, 'wx', 0o600)
    fchmodSync(descriptor, 0o600)
    writeFileSync(descriptor, bytes)
    fsyncSync(descriptor)
    closeSync(descriptor)
    descriptor = undefined
    try {
      linkSync(temporary, path)
      created = true
      fsyncDirectory(dirname(path))
    } catch (error) {
      if (error?.code !== 'EEXIST') {
        throw error
      }
    }
  } finally {
    if (descriptor !== undefined) {
      closeSync(descriptor)
    }
    if (existsSync(temporary)) {
      unlinkSync(temporary)
      fsyncDirectory(dirname(path))
    }
  }
  const journal = readPrivateJournal(path, label)
  if (created && !isDeepStrictEqual(journal.value, value)) {
    throw new Error(`${label} changed after its immutable creation.`)
  }
  return { ...journal, created }
}

function configuredJournalPath(mutationEnv, name, fallback, label) {
  const configured = mutationEnv[name]
  if (configured && !isAbsolute(configured)) {
    throw new Error(`${label} path must be absolute.`)
  }
  return resolve(configured || fallback)
}

export function iosUploadReceiptPaths({ repoRoot, mutationEnv }) {
  const frozen = join(repoRoot, 'dist', 'ios', 'frozen')
  const intent = configuredJournalPath(
    mutationEnv,
    'NVPN_IOS_UPLOAD_INTENT_PATH',
    join(frozen, 'app-store-upload-intent.json'),
    'iOS upload intent',
  )
  const pending = configuredJournalPath(
    mutationEnv,
    'NVPN_IOS_PENDING_UPLOAD_RECEIPT_PATH',
    join(frozen, 'app-store-pending-upload-receipt.json'),
    'Pending iOS upload receipt',
  )
  const final = configuredJournalPath(
    mutationEnv,
    'NVPN_IOS_UPLOAD_RECEIPT_PATH',
    join(frozen, 'app-store-upload-receipt.json'),
    'Final iOS upload receipt',
  )
  if (new Set([intent, pending, final]).size !== 3) {
    throw new Error(
      'Intent, pending, and final iOS upload journal paths must differ.',
    )
  }
  return { final, intent, pending }
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
    || authorization.authorizedAt > Math.floor(Date.now() / 1000) + clockSkewSeconds
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

const identityKeys = [
  'appGitSha',
  'appGitTree',
  'buildNumber',
  'bundleId',
  'ipa',
  'ipaSha256',
  'ipaSize',
  'releaseTag',
  'stageRelease',
  'version',
]

function validateUploadIdentity({
  receipt,
  frozen,
  stagedManifest,
  mutationEnv,
}) {
  const expected = uploadIdentity({ frozen, stagedManifest, mutationEnv })
  for (const key of identityKeys) {
    if (key === 'stageRelease' || key === 'ipa') {
      validateFileBinding(receipt[key], `iOS upload ${key}`)
      if (!isDeepStrictEqual(receipt[key], expected[key])) {
        throw new Error('iOS upload journal differs from exact frozen staging.')
      }
    } else if (receipt[key] !== expected[key]) {
      throw new Error('iOS upload journal differs from exact frozen staging.')
    }
  }
}

const intentKeys = [
  ...identityKeys,
  'attemptId',
  'createdAt',
  'fleetAuthorization',
  'kind',
  'schema',
]

function validateIntentValue({
  repoRoot,
  receipt,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
}) {
  exactKeys(receipt, intentKeys, 'iOS upload intent')
  if (
    receipt.schema !== 1
    || receipt.kind !== 'nvpn-ios-app-store-upload-intent-v1'
    || !attemptIdPattern.test(receipt.attemptId)
    || !Number.isSafeInteger(receipt.createdAt)
    || receipt.createdAt <= 0
    || receipt.createdAt > Math.floor(Date.now() / 1000) + clockSkewSeconds
    || receipt.createdAt < receipt.fleetAuthorization?.authorizedAt
  ) {
    throw new Error('iOS upload intent is invalid.')
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

export function captureIosUploadIntent({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
}) {
  const value = {
    schema: 1,
    kind: 'nvpn-ios-app-store-upload-intent-v1',
    attemptId: randomUUID(),
    createdAt: Math.floor(Date.now() / 1000),
    ...uploadIdentity({ frozen, stagedManifest, mutationEnv }),
    fleetAuthorization: fleetAuthorization(mutationEnv),
  }
  return validateIntentValue({
    repoRoot,
    receipt: value,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
}

export function validateIosUploadIntent({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
}) {
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).intent
  if (!existsSync(path)) {
    throw new Error('Fleet-authorized iOS upload intent is missing.')
  }
  const journal = readPrivateJournal(
    path,
    'Fleet-authorized iOS upload intent',
  )
  validateIntentValue({
    repoRoot,
    receipt: journal.value,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
  return journal
}

function stableIntent(value) {
  const { attemptId, createdAt, ...stable } = value
  return stable
}

export function writeIosUploadIntent({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  intent,
  validatePublication,
}) {
  validateIntentValue({
    repoRoot,
    receipt: intent,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).intent
  const written = writePrivateJournalNoReplace(
    path,
    intent,
    'Fleet-authorized iOS upload intent',
  )
  validateIntentValue({
    repoRoot,
    receipt: written.value,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
  if (
    !written.created
    && !isDeepStrictEqual(stableIntent(written.value), stableIntent(intent))
  ) {
    throw new Error(
      'Existing iOS upload intent differs from this exact upload authorization.',
    )
  }
  return written
}

const pendingKeys = [
  'acceptanceSource',
  'acceptedAt',
  'attemptId',
  'intent',
  'kind',
  'schema',
]
const acceptanceSources = new Set([
  'app-store-connect-visible',
  'transporter-returned',
])

function validatePendingValue({
  repoRoot,
  receipt,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
  intentReceipt,
}) {
  exactKeys(receipt, pendingKeys, 'Pending iOS upload receipt')
  if (!intentReceipt) {
    throw new Error(
      'Pending iOS upload receipt exists without its intent predecessor.',
    )
  }
  validateFileBinding(receipt.intent, 'iOS upload intent')
  if (
    receipt.schema !== 1
    || receipt.kind !== 'nvpn-ios-app-store-upload-accepted-v1'
    || receipt.attemptId !== intentReceipt.value.attemptId
    || !isDeepStrictEqual(receipt.intent, intentReceipt.binding)
    || !acceptanceSources.has(receipt.acceptanceSource)
    || !Number.isSafeInteger(receipt.acceptedAt)
    || receipt.acceptedAt < intentReceipt.value.createdAt
    || receipt.acceptedAt > Math.floor(Date.now() / 1000) + clockSkewSeconds
  ) {
    throw new Error('Pending iOS upload receipt is invalid.')
  }
  return receipt
}

function readIosPendingUploadReceipt({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  validatePublication,
  intentReceipt,
}) {
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).pending
  if (!existsSync(path)) {
    throw new Error('Pending fleet-authorized iOS upload receipt is missing.')
  }
  const journal = readPrivateJournal(
    path,
    'Pending fleet-authorized iOS upload receipt',
  )
  validatePendingValue({
    repoRoot,
    receipt: journal.value,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
    intentReceipt,
  })
  return journal
}

export function validateIosPendingUploadReceipt(options) {
  const intentReceipt = validateIosUploadIntent(options)
  return readIosPendingUploadReceipt({ ...options, intentReceipt })
}

export function writeAcceptedIosPendingUpload({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  intentReceipt,
  acceptanceSource,
  validatePublication,
}) {
  const validatedIntent = validateIosUploadIntent({
    repoRoot,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
  if (
    intentReceipt?.path !== validatedIntent.path
    || !isDeepStrictEqual(intentReceipt?.value, validatedIntent.value)
  ) {
    throw new Error('Accepted iOS upload intent changed before journaling.')
  }
  const value = {
    schema: 1,
    kind: 'nvpn-ios-app-store-upload-accepted-v1',
    attemptId: validatedIntent.value.attemptId,
    acceptedAt: Math.floor(Date.now() / 1000),
    acceptanceSource,
    intent: validatedIntent.binding,
  }
  validatePendingValue({
    repoRoot,
    receipt: value,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
    intentReceipt: validatedIntent,
  })
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).pending
  const written = writePrivateJournalNoReplace(
    path,
    value,
    'Pending fleet-authorized iOS upload receipt',
  )
  validatePendingValue({
    repoRoot,
    receipt: written.value,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
    intentReceipt: validatedIntent,
  })
  if (
    !isDeepStrictEqual(written.value.intent, value.intent)
    || written.value.attemptId !== value.attemptId
  ) {
    throw new Error(
      'Existing pending iOS upload receipt belongs to another upload intent.',
    )
  }
  return written
}

function exactVisibleBuild(testflight, intent) {
  const uploadedMilliseconds = Date.parse(testflight?.uploadedDate)
  if (
    testflight?.buildPresent !== true
    || testflight.processingState !== 'VALID'
    || typeof testflight.buildId !== 'string'
    || !testflight.buildId
    || testflight.buildId.trim() !== testflight.buildId
    || typeof testflight.uploadedDate !== 'string'
    || !Number.isFinite(uploadedMilliseconds)
    || testflight.bundleId !== intent.bundleId
    || testflight.version !== intent.version
    || String(testflight.buildNumber) !== intent.buildNumber
    || Math.floor(uploadedMilliseconds / 1000)
      < intent.createdAt - clockSkewSeconds
  ) {
    throw new Error(
      'App Store Connect did not return one exact VALID build for this upload intent.',
    )
  }
}

const finalKeys = [
  'ascBuildId',
  'ascUploadedDate',
  'attemptId',
  'intent',
  'kind',
  'pending',
  'schema',
]

function validateFinalValue({
  receipt,
  testflight,
  intentReceipt,
  pendingReceipt,
}) {
  exactKeys(receipt, finalKeys, 'Final iOS upload receipt')
  if (!intentReceipt || !pendingReceipt) {
    throw new Error(
      'Final iOS upload receipt exists without every predecessor.',
    )
  }
  validateFileBinding(receipt.intent, 'iOS upload intent')
  validateFileBinding(receipt.pending, 'Pending iOS upload receipt')
  exactVisibleBuild(testflight, intentReceipt.value)
  if (
    receipt.schema !== 1
    || receipt.kind !== 'nvpn-ios-app-store-upload-final-v1'
    || receipt.attemptId !== intentReceipt.value.attemptId
    || receipt.attemptId !== pendingReceipt.value.attemptId
    || !isDeepStrictEqual(receipt.intent, intentReceipt.binding)
    || !isDeepStrictEqual(receipt.pending, pendingReceipt.binding)
    || receipt.ascBuildId !== testflight.buildId
    || receipt.ascUploadedDate !== testflight.uploadedDate
  ) {
    throw new Error('Final iOS upload receipt is invalid.')
  }
  return receipt
}

function readIosUploadReceipt({
  repoRoot,
  mutationEnv,
  testflight,
  intentReceipt,
  pendingReceipt,
}) {
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).final
  if (!existsSync(path)) {
    throw new Error(
      'Existing App Store Connect build has no fleet-bound exact upload receipt.',
    )
  }
  const journal = readPrivateJournal(
    path,
    'Fleet-bound iOS upload receipt',
  )
  validateFinalValue({
    receipt: journal.value,
    testflight,
    intentReceipt,
    pendingReceipt,
  })
  return journal
}

export function validateIosUploadReceipt(options) {
  const path = iosUploadReceiptPaths(options).final
  if (!existsSync(path)) {
    throw new Error(
      'Existing App Store Connect build has no fleet-bound exact upload receipt.',
    )
  }
  const intentReceipt = validateIosUploadIntent(options)
  const pendingReceipt = readIosPendingUploadReceipt({
    ...options,
    intentReceipt,
  })
  return readIosUploadReceipt({
    ...options,
    intentReceipt,
    pendingReceipt,
  })
}

export function finalizeIosUploadReceipt({
  repoRoot,
  frozen,
  stagedManifest,
  mutationEnv,
  pendingReceipt,
  testflight,
  validatePublication,
}) {
  const intentReceipt = validateIosUploadIntent({
    repoRoot,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
  })
  const validatedPending = readIosPendingUploadReceipt({
    repoRoot,
    frozen,
    stagedManifest,
    mutationEnv,
    validatePublication,
    intentReceipt,
  })
  if (
    pendingReceipt?.path !== validatedPending.path
    || !isDeepStrictEqual(pendingReceipt?.value, validatedPending.value)
  ) {
    throw new Error('Pending iOS upload receipt changed before finalization.')
  }
  exactVisibleBuild(testflight, intentReceipt.value)
  const value = {
    schema: 1,
    kind: 'nvpn-ios-app-store-upload-final-v1',
    attemptId: intentReceipt.value.attemptId,
    intent: intentReceipt.binding,
    pending: validatedPending.binding,
    ascBuildId: testflight.buildId,
    ascUploadedDate: testflight.uploadedDate,
  }
  const path = iosUploadReceiptPaths({ repoRoot, mutationEnv }).final
  const written = writePrivateJournalNoReplace(
    path,
    value,
    'Fleet-bound iOS upload receipt',
  )
  validateFinalValue({
    receipt: written.value,
    testflight,
    intentReceipt,
    pendingReceipt: validatedPending,
  })
  if (!isDeepStrictEqual(written.value, value)) {
    throw new Error(
      'Existing final iOS upload receipt differs from the exact ASC build.',
    )
  }
  return written
}

export function planIosUploadReconciliation({
  buildPresent,
  buildValid = buildPresent,
  finalReceipt,
  intentReceipt,
  pendingReceipt,
}) {
  if (pendingReceipt && !intentReceipt) {
    throw new Error(
      'Pending iOS upload receipt exists without its intent predecessor.',
    )
  }
  if (finalReceipt && (!intentReceipt || !pendingReceipt)) {
    throw new Error(
      'Final iOS upload receipt exists without every predecessor.',
    )
  }
  if (finalReceipt) {
    if (!buildPresent || !buildValid) {
      throw new Error(
        'Final fleet-bound iOS upload receipt has no exact VALID App Store Connect build.',
      )
    }
    return 'use-final'
  }
  if (pendingReceipt) {
    return buildPresent && buildValid
      ? 'finalize-pending'
      : 'wait-pending'
  }
  if (intentReceipt) {
    return buildPresent && buildValid
      ? 'recover-intent'
      : 'wait-intent'
  }
  if (buildPresent) {
    throw new Error(
      'Orphan App Store Connect build has no fleet-authorized upload intent.',
    )
  }
  return 'create-intent'
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
  const intentReceipt = existsSync(paths.intent)
    ? validateIosUploadIntent({
        repoRoot,
        frozen,
        stagedManifest,
        mutationEnv,
        validatePublication,
      })
    : null
  const pendingExists = existsSync(paths.pending)
  if (pendingExists && !intentReceipt) {
    throw new Error(
      'Pending iOS upload receipt exists without its intent predecessor.',
    )
  }
  const pendingReceipt = pendingExists
    ? readIosPendingUploadReceipt({
        repoRoot,
        frozen,
        stagedManifest,
        mutationEnv,
        validatePublication,
        intentReceipt,
      })
    : null
  const finalExists = existsSync(paths.final)
  if (finalExists && (!intentReceipt || !pendingReceipt)) {
    throw new Error(
      'Final iOS upload receipt exists without every predecessor.',
    )
  }
  const finalReceipt = finalExists
    ? readIosUploadReceipt({
        repoRoot,
        mutationEnv,
        testflight,
        intentReceipt,
        pendingReceipt,
      })
    : null
  const buildPresent = testflight.buildPresent === true
  const buildValid =
    buildPresent && testflight.processingState === 'VALID'
  if (intentReceipt && buildValid && !finalReceipt) {
    exactVisibleBuild(testflight, intentReceipt.value)
  }
  return {
    finalReceipt,
    intentReceipt,
    pendingReceipt,
    uploadAction: planIosUploadReconciliation({
      buildPresent,
      buildValid,
      finalReceipt,
      intentReceipt,
      pendingReceipt,
    }),
  }
}
