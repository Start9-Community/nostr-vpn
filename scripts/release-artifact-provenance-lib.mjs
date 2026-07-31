import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  readSync,
} from 'node:fs'
import { basename } from 'node:path'

const requiredReleaseGatePlatforms = [
  'android',
  'ios',
  'linux',
  'macos',
  'windows',
]

const startosExactPackageValidator = 'start-cli-s9pk-inspect-manifest'
const requiredFrozenIosRealDeviceGates = [
  'background-foreground-and-rapid-start-stop',
  'bidirectional-mobile-qr-and-manual-join',
  'desktop-mobile-manual-join',
  'wifi-radio-off-on-recovery',
  'wireguard-exit-and-five-dns-policies',
]
const mobileDnsEvidence = {
  'automatic-profile': {
    kind: 'dns-profile',
    increased: new Set(['query', 'profile']),
  },
  'cloudflare-doh': {
    kind: 'doh-cloudflare',
    increased: new Set(['cloudflare']),
  },
  'quad9-doh': {
    kind: 'doh-quad9',
    increased: new Set(['quad9']),
  },
  'custom-doh': {
    kind: 'doh-google',
    increased: new Set(['google']),
  },
  'through-exit': {
    kind: 'dns-through',
    increased: new Set(['query', 'through']),
  },
}
const mobileDnsCounters = [
  'query',
  'profile',
  'cloudflare',
  'quad9',
  'google',
  'through',
  'forward',
]
const desktopDnsCounters = {
  automatic: 'profile_dns',
  cloudflare: 'cloudflare',
  custom: 'google',
  quad9: 'quad9',
  'through-exit': 'fixture_dns',
}
const desktopDnsCounterNames = [
  'profile_dns',
  'cloudflare',
  'quad9',
  'google',
  'fixture_dns',
]
const desktopDnsUiSettings = {
  automatic: ['automatic', 'cloudflare'],
  cloudflare: ['encrypted', 'cloudflare'],
  quad9: ['encrypted', 'quad9'],
  custom: ['encrypted', 'custom'],
  'through-exit': ['through_exit', 'cloudflare'],
}

function sha256FileSync(path) {
  const hash = createHash('sha256')
  const descriptor = openSync(path, 'r')
  const chunk = Buffer.allocUnsafe(1024 * 1024)
  try {
    for (;;) {
      const bytesRead = readSync(descriptor, chunk, 0, chunk.length, null)
      if (bytesRead === 0) {
        break
      }
      hash.update(chunk.subarray(0, bytesRead))
    }
  } finally {
    closeSync(descriptor)
  }
  return hash.digest('hex')
}

function requireSha256(value, label) {
  if (!/^[0-9a-f]{64}$/.test(String(value ?? ''))) {
    throw new Error(`${label} is not a lowercase SHA-256 digest.`)
  }
}

function releaseAssetPlatform(path) {
  const name = basename(path)
  if (/-android-arm64\.(apk|aab)$/.test(name)) {
    return 'android'
  }
  if (
    /-macos-arm64\.(dmg|app\.tar\.gz)$/.test(name)
    || /-aarch64-apple-darwin\.tar\.gz$/.test(name)
  ) {
    return 'macos'
  }
  if (
    /-linux-x64\.(deb|AppImage)$/.test(name)
    || /-x86_64-unknown-linux-musl\.tar\.gz$/.test(name)
  ) {
    return 'linux'
  }
  if (
    /-windows-x64-setup\.exe$/.test(name)
    || /-x86_64-pc-windows-msvc\.zip$/.test(name)
  ) {
    return 'windows'
  }
  if (/-startos-(x86_64|aarch64)\.s9pk$/.test(name)) {
    return 'startos'
  }
  throw new Error(`Release asset ${path} has no exact platform-proof policy.`)
}

function commandOutputSha256(command, args, { cwd = process.cwd() } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'buffer',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 1024 * 1024 * 1024,
  })
  if (result.status !== 0) {
    const stderr = result.stderr?.toString('utf8').trim() || ''
    throw new Error(
      stderr || `${command} could not read the exact packaged payload.`,
    )
  }
  return createHash('sha256').update(result.stdout).digest('hex')
}

function zipMembers(path, { cwd = process.cwd() } = {}) {
  const result = spawnSync('unzip', ['-Z1', path], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.status !== 0) {
    throw new Error(
      result.stderr.trim() || `Could not inspect ZIP members in ${path}.`,
    )
  }
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
}

export function archiveMemberSha256(
  command,
  args,
  { cwd = process.cwd() } = {},
) {
  return commandOutputSha256(command, args, { cwd })
}

export function androidRuntimePayloads(
  apkPath,
  aabPath,
  { cwd = process.cwd() } = {},
) {
  const apkMembers = zipMembers(apkPath, { cwd })
  const aabMembers = zipMembers(aabPath, { cwd })
  const apkNative = 'lib/arm64-v8a/libnostr_vpn_app_core.so'
  const aabNative = 'base/lib/arm64-v8a/libnostr_vpn_app_core.so'
  if (!apkMembers.includes(apkNative) || !aabMembers.includes(aabNative)) {
    throw new Error('Android APK/AAB lacks the production arm64 app-core payload.')
  }

  const apkDex = apkMembers
    .filter((member) => /^classes[0-9]*\.dex$/.test(member))
    .sort()
  const aabDex = aabMembers
    .filter((member) => /^base\/dex\/classes[0-9]*\.dex$/.test(member))
    .sort()
  if (
    apkDex.length === 0
    || apkDex.length !== aabDex.length
    || apkDex.some(
      (member, index) => basename(member) !== basename(aabDex[index]),
    )
  ) {
    throw new Error('Android APK/AAB production DEX payload sets differ.')
  }

  const payloads = {
    app_core_arm64: commandOutputSha256(
      'unzip',
      ['-p', apkPath, apkNative],
      { cwd },
    ),
  }
  if (
    payloads.app_core_arm64
    !== commandOutputSha256('unzip', ['-p', aabPath, aabNative], { cwd })
  ) {
    throw new Error(
      'Android AAB native payload differs from the physically gated APK.',
    )
  }

  for (let index = 0; index < apkDex.length; index += 1) {
    const label = basename(apkDex[index]).replace(/\W/g, '_')
    const apkDigest = commandOutputSha256(
      'unzip',
      ['-p', apkPath, apkDex[index]],
      { cwd },
    )
    const aabDigest = commandOutputSha256(
      'unzip',
      ['-p', aabPath, aabDex[index]],
      { cwd },
    )
    if (apkDigest !== aabDigest) {
      throw new Error(
        `Android AAB ${basename(aabDex[index])} differs from the physically gated APK.`,
      )
    }
    payloads[label] = apkDigest
  }
  return payloads
}

export function exactArtifactProof({
  artifactPath,
  platform,
  gateReceiptPath,
  payloads,
  verification = 'gate-payload-identity',
  postBuildValidator,
}) {
  if (!existsSync(artifactPath)) {
    throw new Error(`Exact release artifact is missing: ${artifactPath}`)
  }
  if (!existsSync(gateReceiptPath)) {
    throw new Error(`Exact platform-gate receipt is missing: ${gateReceiptPath}`)
  }
  const proof = {
    platform,
    verification,
    artifact_sha256: sha256FileSync(artifactPath),
    gate_receipt_sha256: sha256FileSync(gateReceiptPath),
    payloads,
  }
  if (postBuildValidator) {
    proof.post_build_validator = postBuildValidator
  }
  return proof
}

export function mergeArtifactProofs(target, additions) {
  for (const [name, proof] of Object.entries(additions ?? {})) {
    if (target[name]) {
      throw new Error(`Duplicate exact-artifact proof for ${name}.`)
    }
    target[name] = proof
  }
}

export function readRequiredJson(path, label) {
  if (!existsSync(path)) {
    throw new Error(`${label} is missing: ${path}`)
  }
  let value
  try {
    value = JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''))
  } catch {
    throw new Error(`${label} is not valid JSON: ${path}`)
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} is not a JSON object: ${path}`)
  }
  return value
}

export function requireReceiptSource(receipt, { commit, tree, label }) {
  const source = receipt.artifact && typeof receipt.artifact === 'object'
    ? receipt.artifact
    : receipt.mobileArtifactEvidence
      && typeof receipt.mobileArtifactEvidence === 'object'
      ? receipt.mobileArtifactEvidence
      : receipt
  if (source.appGitSha !== commit || source.appGitTree !== tree) {
    throw new Error(`${label} is not for the exact clean release candidate.`)
  }
}

function requireReceiptComponentSource(receipt, label) {
  const appGitSha = String(receipt?.appGitSha ?? '')
  const appGitTree = String(receipt?.appGitTree ?? '')
  if (
    !/^[0-9a-f]{40}$/.test(appGitSha)
    || !/^[0-9a-f]{40}$/.test(appGitTree)
  ) {
    throw new Error(`${label} lacks an exact component-origin SHA/tree.`)
  }
  return { commit: appGitSha, tree: appGitTree }
}

export function validateWindowsInstallerGateReceipt({
  receipt,
  artifactReceipt,
  commit,
  tree,
  expectedTag = `v${artifactReceipt?.appVersion ?? ''}`,
}) {
  requireReceiptSource(receipt, {
    commit,
    tree,
    label: 'Windows exact installer gate receipt',
  })
  requireReceiptSource(artifactReceipt, {
    commit,
    tree,
    label: 'Windows exact payload gate receipt',
  })
  const expectedName =
    `nostr-vpn-${expectedTag}-windows-x64-setup.exe`
  if (
    receipt.receiptSchema !== 1
    || receipt.platform !== 'windows'
    || receipt.artifactType !== 'exact installed Windows Release setup'
    || receipt.tag !== expectedTag
    || receipt.installerName !== expectedName
    || !/^[0-9a-f]{64}$/.test(receipt.installerSha256 ?? '')
    || !Number.isSafeInteger(receipt.installerSize)
    || receipt.installerSize <= 0
    || receipt.installerInstalledAndLaunched !== true
    || receipt.installedAppStayedAlive !== true
    || !/^[0-9a-f]{64}$/.test(receipt.smokeReceiptSha256 ?? '')
    || receipt.builtOnWindowsVm !== true
    || receipt.builtOnHostMac !== false
  ) {
    throw new Error(
      'Windows exact installer gate receipt is incomplete.',
    )
  }
  const names = ['app', 'appCore', 'cli', 'wintun']
  if (
    JSON.stringify(Object.keys(receipt.payloads ?? {}).sort())
      !== JSON.stringify([...names].sort())
  ) {
    throw new Error(
      'Windows exact installer gate receipt has the wrong payload set.',
    )
  }
  for (const name of names) {
    const installed = receipt.payloads[name]
    const gated = artifactReceipt.artifacts?.[name]
    if (
      !/^[0-9a-f]{64}$/.test(installed?.sha256 ?? '')
      || !Number.isSafeInteger(installed?.size)
      || installed.size <= 0
      || installed.sha256 !== gated?.sha256
      || installed.size !== gated?.size
    ) {
      throw new Error(
        `Windows exact installer ${name} payload differs from the real platform gate.`,
      )
    }
  }
  return {
    installerName: receipt.installerName,
    installerSha256: receipt.installerSha256,
    installerSize: receipt.installerSize,
    payloads: Object.fromEntries(
      names.map((name) => [name, receipt.payloads[name].sha256]),
    ),
  }
}

function requirePublicUiJoinReceipt(receipt, platform, label, schema = 1) {
  if (
    receipt.schema !== schema
    || receipt.platform !== platform
    || receipt.publicUiOnly !== true
    || receipt.privateStateRead !== false
    || receipt.fixtureInvoked !== false
    || receipt.acceptedSelectorSemantics !== 'participant-state-not-pending'
    || receipt.desktopRelaunchDurability !== true
    || receipt.pixelRelaunchDurability !== true
  ) {
    throw new Error(`${label} is not a strict real public-UI join receipt.`)
  }
}

function requireExactDeliveryTimings(receipt, expectedLabels, label) {
  if (receipt.deliveryDeadlineMilliseconds !== 15_000) {
    throw new Error(`${label} does not enforce the 15-second delivery deadline.`)
  }
  const timings = receipt.deliveryMilliseconds
  if (!timings || typeof timings !== 'object' || Array.isArray(timings)) {
    throw new Error(`${label} has no delivery timing receipt.`)
  }
  const labels = Object.keys(timings).sort()
  const expected = [...expectedLabels].sort()
  if (
    labels.length !== expected.length
    || labels.some((value, index) => value !== expected[index])
    || labels.some(
      (value) =>
        !Number.isSafeInteger(timings[value])
        || timings[value] < 0
        || timings[value] > 15_000,
    )
  ) {
    throw new Error(`${label} has incomplete or slow delivery timings.`)
  }
}

function requireIdentityFieldsMatch(
  actual,
  expected,
  fields,
  label,
) {
  if (!actual || typeof actual !== 'object' || Array.isArray(actual)) {
    throw new Error(`${label} identity is missing.`)
  }
  for (const field of fields) {
    if (!expected[field] || actual[field] !== expected[field]) {
      throw new Error(`${label} identity differs at ${field}.`)
    }
  }
}

function requireMobileJoinReceipt({
  receipt,
  androidArtifact,
  androidArtifactReceiptSha256,
  iosArtifact,
  iosArtifactReceiptSha256,
}) {
  const contentWidth = receipt.contentWidth
  if (
    receipt.schema !== 1
    || receipt.platform !== 'mobile'
    || receipt.publicUiOnly !== true
    || receipt.opticalCameraQr !== true
    || receipt.privateAppStateRead !== false
    || receipt.appLaunchArgumentsOrEnvironment !== false
    || receipt.desktopMobileManual !== true
    || receipt.qr?.iphoneAdminPixelJoiner !== true
    || receipt.qr?.pixelAdminIphoneJoiner !== true
    || receipt.qr?.pendingQrBackgroundForeground !== true
    || receipt.qr?.exactRosterOnBothSides !== true
    || receipt.qr?.joinerRelaunchDurable !== true
    || receipt.qr?.androidJoinerRelaunchDurable !== true
    || receipt.qr?.iphoneJoinerRelaunchDurable !== true
    || receipt.manual?.iphoneAdminPixelJoiner !== true
    || receipt.manual?.pixelAdminIphoneJoiner !== true
    || receipt.manual?.exactRosterOnBothSides !== true
    || receipt.manual?.acceptedRosterOnly !== true
    || receipt.manual?.iphoneAdminPixelJoinerRelaunchDurable !== true
    || receipt.manual?.pixelAdminIphoneJoinerRelaunchDurable !== true
    || contentWidth?.minimumRequiredBasisPoints !== 9800
    || contentWidth?.maximumAllowedBasisPoints !== 10000
    || !Number.isSafeInteger(contentWidth?.androidObservedBasisPoints)
    || contentWidth.androidObservedBasisPoints < 9800
    || contentWidth.androidObservedBasisPoints > 10000
    || !Number.isSafeInteger(contentWidth?.iosObservedBasisPoints)
    || contentWidth.iosObservedBasisPoints < 9800
    || contentWidth.iosObservedBasisPoints > 10000
  ) {
    throw new Error(
      'Android/iOS mobile join receipt is not strict public-UI/relaunch evidence.',
    )
  }
  if (
    !/^[0-9a-f]{40}$/.test(String(receipt.harnessGitSha ?? ''))
    || !/^[0-9a-f]{40}$/.test(String(receipt.harnessGitTree ?? ''))
  ) {
    throw new Error('Android/iOS mobile join receipt lacks its harness identity.')
  }
  requireExactDeliveryTimings(
    receipt,
    [
      'iPhone-admin-to-Pixel-QR',
      'Pixel-admin-to-iPhone-QR',
      'iPhone-admin-to-Pixel-manual',
      'Pixel-admin-to-iPhone-manual',
    ],
    'Android/iOS mobile join receipt',
  )
  const artifact = receipt.artifact
  if (
    artifact.android?.artifactReceiptSha256
      !== androidArtifactReceiptSha256
    || artifact.ios?.artifactReceiptSha256
      !== iosArtifactReceiptSha256
  ) {
    throw new Error(
      'Android/iOS mobile join receipt is not bound to the exact artifact receipts.',
    )
  }
  requireIdentityFieldsMatch(
    artifact.android,
    androidArtifact,
    [
      'appGitSha',
      'appGitTree',
      'fipsGitSha',
      'fipsGitTree',
      'apkSha256',
      'installedApkSha256',
      'package',
      'signerCertificateSha256',
    ],
    'Android mobile join artifact',
  )
  requireIdentityFieldsMatch(
    artifact.ios,
    iosArtifact,
    [
      'appGitSha',
      'appGitTree',
      'fipsGitSha',
      'fipsGitTree',
      'appBundleTreeSha256',
      'appCodeDirectoryHash',
      'packetTunnelCodeDirectoryHash',
      'appExecutableSha256',
      'packetTunnelExecutableSha256',
      'signerCertificateSha256',
      'installedBundleIdentifier',
    ],
    'iOS mobile join artifact',
  )
}

function requireMacosJoinReceipt({
  receipt,
  artifactReceipt,
  artifactReceiptSha256,
  iosArtifact,
  iosArtifactReceiptSha256,
  commit,
  tree,
}) {
  requirePublicUiJoinReceipt(
    receipt,
    'macos',
    'macOS/mobile public-UI join receipt',
  )
  requireReceiptSource(receipt, {
    commit,
    tree,
    label: 'macOS/mobile public-UI join receipt',
  })
  if (
    receipt.appLaunchArgumentsOrEnvironment !== false
    || receipt.desktopAdminAndroidJoiner !== true
    || receipt.androidAdminDesktopJoiner !== true
    || receipt.desktopAdminIphoneJoiner !== true
    || receipt.iphoneAdminDesktopJoiner !== true
    || receipt.exactRosterOnBothSides !== true
    || receipt.acceptedRosterRetainedAcrossRelaunch !== true
    || receipt.desktopAdminIphoneJoinerRelaunchDurable !== true
    || receipt.iphoneAdminDesktopJoinerRelaunchDurable !== true
    || receipt.artifact?.artifactReceiptSha256 !== artifactReceiptSha256
    || receipt.artifact?.appExecutableSha256
      !== artifactReceipt.appExecutableSha256
    || receipt.artifact?.ios?.artifactReceiptSha256
      !== iosArtifactReceiptSha256
  ) {
    throw new Error('macOS/mobile public-UI join receipt is incomplete.')
  }
  requireIdentityFieldsMatch(
    receipt.artifact.ios,
    iosArtifact,
    [
      'appGitSha',
      'appGitTree',
      'fipsGitSha',
      'fipsGitTree',
      'appBundleTreeSha256',
      'appCodeDirectoryHash',
      'packetTunnelCodeDirectoryHash',
      'appExecutableSha256',
      'packetTunnelExecutableSha256',
      'signerCertificateSha256',
      'installedBundleIdentifier',
    ],
    'macOS/iOS join artifact',
  )
  requireExactDeliveryTimings(
    receipt,
    [
      'macOS-admin-to-Android-manual',
      'Android-admin-to-macOS-manual',
      'macOS-admin-to-iPhone-manual',
      'iPhone-admin-to-macOS-manual',
    ],
    'macOS/mobile public-UI join receipt',
  )
}

function requireDesktopMobileJoinReceipt({
  receipt,
  platform,
  desktopArtifact,
  desktopArtifactReceiptSha256,
  androidArtifact,
  androidArtifactReceiptSha256,
  androidInstallReceiptSha256,
  androidInstallReceiptSize,
}) {
  const label = `${platform} / Pixel public-UI join receipt`
  requirePublicUiJoinReceipt(receipt, platform, label, 2)
  if (
    receipt.appLaunchArgumentsOrEnvironment !== false
    || !Number.isSafeInteger(receipt.completionDeadlineSeconds)
    || receipt.completionDeadlineSeconds <= 0
    || receipt.completionDeadlineSeconds > 15
  ) {
    throw new Error(`${label} lacks a strict public-UI delivery deadline.`)
  }
  for (const roleName of [
    'desktopAdminPixelJoiner',
    'pixelAdminDesktopJoiner',
  ]) {
    const role = receipt[roleName]
    if (
      !role
      || role.desktopAccepted !== true
      || role.pixelAccepted !== true
      || role.desktopRelaunchAccepted !== true
      || role.pixelRelaunchAccepted !== true
      || !Number.isSafeInteger(role.deliveryMilliseconds)
      || role.deliveryMilliseconds < 0
      || role.deliveryMilliseconds
        > receipt.completionDeadlineSeconds * 1_000
    ) {
      throw new Error(`${label} has incomplete ${roleName} evidence.`)
    }
  }

  const evidence = receipt.artifact
  const desktop = evidence?.desktop
  const android = evidence?.android
  const artifacts = desktopArtifact.artifacts
  if (
    !desktop
    || desktop.artifactReceiptSha256 !== desktopArtifactReceiptSha256
    || desktop.appGitSha !== desktopArtifact.appGitSha
    || desktop.appGitTree !== desktopArtifact.appGitTree
    || desktop.fipsGitSha !== desktopArtifact.fipsGitSha
    || desktop.fipsGitTree !== desktopArtifact.fipsGitTree
    || desktop.fipsVersion !== desktopArtifact.fipsVersion
    || desktop.appSha256 !== artifacts?.app?.sha256
    || desktop.appSize !== artifacts?.app?.size
    || desktop.cliSha256 !== artifacts?.cli?.sha256
    || desktop.cliSize !== artifacts?.cli?.size
    || desktop.appVersion !== desktopArtifact.appVersion
    || !android
    || android.artifactReceiptSha256 !== androidArtifactReceiptSha256
    || android.appGitSha !== androidArtifact.appGitSha
    || android.appGitTree !== androidArtifact.appGitTree
    || android.fipsGitSha !== androidArtifact.fipsGitSha
    || android.fipsGitTree !== androidArtifact.fipsGitTree
    || android.fipsVersion !== androidArtifact.fipsCoreVersion
    || android.fipsMetadataReceiptSha256
      !== androidArtifact.fipsCargoMetadataReceiptSha256
    || android.apkSha256 !== androidArtifact.apkSha256
    || android.package !== androidArtifact.package
    || android.signerCertificateSha256
      !== androidArtifact.signerCertificateSha256
    || android.installReceiptSha256 !== androidInstallReceiptSha256
    || android.installReceiptSize !== androidInstallReceiptSize
  ) {
    throw new Error(`${label} is not bound to the exact desktop/Android artifacts.`)
  }
  if (
    platform === 'windows'
    && (
      desktop.appCoreSha256 !== artifacts?.appCore?.sha256
      || desktop.appCoreSize !== artifacts?.appCore?.size
    )
  ) {
    throw new Error(`${label} is not bound to the exact Windows app core.`)
  }
}

function requireAndroidInstallReceipt(receipt, artifact) {
  if (
    receipt.artifact !== 'Android Release APK'
    || receipt.apkSha256 !== artifact.apkSha256
    || receipt.installedApkSha256 !== artifact.installedApkSha256
    || receipt.signerCertificateSha256
      !== artifact.signerCertificateSha256
    || receipt.appGitSha !== artifact.appGitSha
    || receipt.appGitTree !== artifact.appGitTree
    || receipt.fipsGitSha !== artifact.fipsGitSha
    || receipt.fipsGitTree !== artifact.fipsGitTree
    || receipt.package !== artifact.package
    || typeof receipt.preexistingCanonicalPackage !== 'boolean'
    || receipt.replacementInstall !== true
    || receipt.replacementInstallVerified !== true
    || receipt.debuggable !== false
    || receipt.canonicalPackageCount !== 1
    || receipt.canonicalProcessCount !== 1
  ) {
    throw new Error(
      'Android install receipt is not bound to the exact physical artifact.',
    )
  }
}

function requireMobileNetworkReceipt({
  receipt,
  platform,
  mode,
  artifact,
  artifactReceiptSha256,
  commit,
  tree,
}) {
  const expectedCases = mode === 'wireguard-dns'
    ? [
        'automatic-profile',
        'cloudflare-doh',
        'quad9-doh',
        'custom-doh',
        'through-exit',
      ]
    : ['automatic-profile']
  if (
    receipt.receiptSchema !== 1
    || receipt.artifactType !== `physical ${platform} Release ${mode} gate`
    || receipt.platform !== platform
    || receipt.mode !== mode
    || receipt.appGitSha !== commit
    || receipt.appGitTree !== tree
    || receipt.fipsGitSha !== artifact.fipsGitSha
    || receipt.fipsGitTree !== artifact.fipsGitTree
    || receipt.artifactReceiptSha256 !== artifactReceiptSha256
  ) {
    throw new Error(`${platform} ${mode} receipt is not exact source/artifact evidence.`)
  }
  const identityFields = platform === 'android'
    ? [
        'apkSha256',
        'installedApkSha256',
        'package',
        'signerCertificateSha256',
      ]
    : [
        'appBundleTreeSha256',
        'appCodeDirectoryHash',
        'packetTunnelCodeDirectoryHash',
        'appExecutableSha256',
        'packetTunnelExecutableSha256',
        'signerCertificateSha256',
        'installedBundleIdentifier',
      ]
  requireIdentityFieldsMatch(
    receipt.artifactIdentity,
    artifact,
    identityFields,
    `${platform} ${mode} artifact`,
  )
  const labels = Object.keys(receipt.dnsCases ?? {}).sort()
  expectedCases.sort()
  if (
    labels.length !== expectedCases.length
    || labels.some((label, index) => label !== expectedCases[index])
  ) {
    throw new Error(`${platform} ${mode} receipt has the wrong DNS cases.`)
  }
  for (const label of labels) {
    const value = receipt.dnsCases[label]
    const dnsPolicy = mobileDnsEvidence[label]
    if (
      !dnsPolicy
      || value?.dnsEvidence !== dnsPolicy.kind
      || !Number.isSafeInteger(value?.wireGuardRxBytesBefore)
      || !Number.isSafeInteger(value?.wireGuardRxBytesAfter)
      || value.wireGuardRxBytesAfter <= value.wireGuardRxBytesBefore
      || !Number.isSafeInteger(value?.wireGuardTxBytesBefore)
      || !Number.isSafeInteger(value?.wireGuardTxBytesAfter)
      || value.wireGuardTxBytesAfter <= value.wireGuardTxBytesBefore
      || !Number.isSafeInteger(value?.forwardedPacketsBefore)
      || !Number.isSafeInteger(value?.forwardedPacketsAfter)
      || value.forwardedPacketsAfter <= value.forwardedPacketsBefore
      || !value.dnsPathCountersBefore
      || !value.dnsPathCountersAfter
    ) {
      throw new Error(`${platform} ${mode} ${label} lacks real packet counters.`)
    }
    const beforeLabels = Object.keys(value.dnsPathCountersBefore).sort()
    const afterLabels = Object.keys(value.dnsPathCountersAfter).sort()
    const expectedCounterLabels = [...mobileDnsCounters].sort()
    if (
      beforeLabels.length !== expectedCounterLabels.length
      || afterLabels.length !== expectedCounterLabels.length
      || beforeLabels.some(
        (counter, index) => counter !== expectedCounterLabels[index],
      )
      || afterLabels.some(
        (counter, index) => counter !== expectedCounterLabels[index],
      )
    ) {
      throw new Error(`${platform} ${mode} ${label} has incomplete DNS counters.`)
    }
    for (const counter of mobileDnsCounters) {
      const before = value.dnsPathCountersBefore[counter]
      const after = value.dnsPathCountersAfter[counter]
      if (
        !Number.isSafeInteger(before)
        || before < 0
        || !Number.isSafeInteger(after)
        || after < 0
        || (
          dnsPolicy.increased.has(counter)
            ? after <= before
            : after !== before
        )
      ) {
        throw new Error(
          `${platform} ${mode} ${label} used the wrong ${counter} DNS path.`,
        )
      }
    }
  }
  const evidenceFiles = Object.values(receipt.evidenceFiles ?? {})
  if (evidenceFiles.length === 0) {
    throw new Error(`${platform} ${mode} receipt has no concrete evidence files.`)
  }
  for (const digest of evidenceFiles) {
    requireSha256(digest, `${platform} ${mode} evidence file`)
  }
  if (
    mode === 'wireguard-dns'
    && receipt.support?.rapidStartStopCycles !== 8
  ) {
    throw new Error(`${platform} WireGuard/DNS receipt lacks eight rapid start/stop cycles.`)
  }
  if (
    mode === 'wireguard-dns'
    && platform === 'android'
    && receipt.support?.directBeforeConnectedAfter !== true
  ) {
    throw new Error('Android WireGuard/DNS receipt lacks Direct restoration evidence.')
  }
  if (mode === 'underlay-lifecycle') {
    const cycles = receipt.support?.underlayCycles
    const cycle = Array.isArray(cycles) ? cycles[0] : undefined
    const processCounts = cycle?.processIdentifierCounts
    const evidencePaths = Object.keys(receipt.evidenceFiles ?? {})
    const requiredEvidence = platform === 'android'
      ? [
          /underlay-.*-summary\.json$/,
          /underlay-.*-markers\.tsv$/,
          /underlay-.*-continuity\.log$/,
          /underlay-fresh-dns-fixture\.json$/,
          /radio-bounce-dns-.*\.log$/,
          /radio-bounce-udp-.*\.log$/,
        ]
      : [
          /continuity\.json$/,
          /host-markers\.tsv$/,
          /processes\.json$/,
          /reverse-payload\.log$/,
          /runner-markers\.log$/,
          /underlay-fresh-dns-fixture\.json$/,
        ]
    if (
      receipt.support?.lifecycleCycles !== 3
      || !Array.isArray(cycles)
      || cycles.length !== 1
      || cycle?.gate !== 'wifi-radio-off-on-recovery'
      || cycle?.outageReversePayloads !== 0
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\..+$/
        .test(String(cycle?.freshDnsQueryHost ?? ''))
      || !Number.isSafeInteger(cycle?.freshDnsFixtureExactQueryCount)
      || cycle.freshDnsFixtureExactQueryCount < 1
      || ![cycle?.dnsAndWireGuardRecoveryMilliseconds,
        cycle?.firstReversePayloadRecoveryMilliseconds].every(
        (value) => Number.isSafeInteger(value) && value >= 0 && value <= 4000,
      )
      || !Number.isSafeInteger(
        cycle?.noValidatedPhysicalFallbackEvidenceCount,
      )
      || cycle.noValidatedPhysicalFallbackEvidenceCount
        < (platform === 'android' ? 2 : 1)
      || cycle?.originalWifiRestoredEvidenceCount !== 1
      || processCounts?.app !== 1
      || ![processCounts?.packetTunnel, processCounts?.nativeTunnel].includes(1)
      || requiredEvidence.some(
        (pattern) => !evidencePaths.some((path) => pattern.test(path)),
      )
    ) {
      throw new Error(`${platform} underlay/lifecycle receipt is incomplete.`)
    }
  }
  if (
    mode === 'underlay-lifecycle'
    && platform === 'android'
    && receipt.support?.postForegroundDnsHttpsAndTunnelCycles !== 3
  ) {
    throw new Error(
      'Android lifecycle receipt lacks three post-foreground DNS/HTTPS/tunnel checks.',
    )
  }
}

function requireDesktopNetworkReceipt({
  receipt,
  platform,
  commit,
  tree,
  artifactReceiptPath,
}) {
  if (
    receipt.receiptSchema !== 1
    || receipt.artifactType !== `${platform} Release desktop network gate`
    || receipt.platform !== platform
    || receipt.appGitSha !== commit
    || receipt.appGitTree !== tree
  ) {
    throw new Error(
      `${platform} desktop network receipt is not exact source evidence.`,
    )
  }
  const evidenceFiles = Object.values(receipt.evidenceFiles ?? {})
  if (evidenceFiles.length === 0) {
    throw new Error(`${platform} desktop network receipt has no evidence files.`)
  }
  for (const digest of evidenceFiles) {
    requireSha256(digest, `${platform} desktop network evidence file`)
  }

  const summary = receipt.summary
  if (
    !summary
    || typeof summary !== 'object'
    || Array.isArray(summary)
    || summary.dnsPolicyCount !== 5
    || summary.directRestored !== true
    || summary.singletonAfterCrashRecovery !== true
  ) {
    throw new Error(`${platform} desktop network summary is incomplete.`)
  }
  const artifact = readRequiredJson(
    artifactReceiptPath,
    `${platform} exact desktop artifact receipt`,
  )
  const expectedAppSha256 = platform === 'macos'
    ? artifact.appExecutableSha256
    : artifact.artifacts?.app?.sha256
  const expectedCliSha256 = platform === 'macos'
    ? artifact.cliExecutableSha256
    : artifact.artifacts?.cli?.sha256
  const expectedUiCases = Object.keys(desktopDnsUiSettings).sort()
  const actualUiCases = Object.keys(summary.dnsUiCases ?? {}).sort()
  const expectedUiEvidence = expectedUiCases.map(
    (dnsCase) => `${dnsCase}.json`,
  )
  const actualUiEvidence = Object.keys(
    receipt.desktopDnsUiEvidenceFiles ?? {},
  ).sort()
  if (
    summary.dnsUiPolicyCount !== expectedUiCases.length
    || actualUiCases.length !== expectedUiCases.length
    || actualUiCases.some(
      (value, index) => value !== expectedUiCases[index],
    )
    || actualUiEvidence.length !== expectedUiEvidence.length
    || actualUiEvidence.some(
      (value, index) => value !== expectedUiEvidence[index],
    )
  ) {
    throw new Error(
      `${platform} desktop DNS UI receipt does not cover exactly five shipped settings.`,
    )
  }
  for (const dnsCase of expectedUiCases) {
    const value = summary.dnsUiCases[dnsCase]
    const [mode, provider] = desktopDnsUiSettings[dnsCase]
    const providerMatches = value?.provider === provider
      || (
        platform === 'macos'
        && ['automatic', 'through-exit'].includes(dnsCase)
        && value?.provider === ''
      )
    if (
      value?.mode !== mode
      || !providerMatches
      || value?.appExecutableSha256 !== expectedAppSha256
      || value?.cliExecutableSha256 !== expectedCliSha256
    ) {
      throw new Error(
        `${platform} ${dnsCase} DNS UI readback is not bound to the exact gated app and CLI.`,
      )
    }
    requireSha256(
      receipt.desktopDnsUiEvidenceFiles[`${dnsCase}.json`],
      `${platform} ${dnsCase} DNS UI evidence file`,
    )
  }
  if (platform === 'macos') {
    if (
      summary.artifactReceiptSha256 !== sha256FileSync(artifactReceiptPath)
      || !Array.isArray(summary.handoffRecoveryMilliseconds)
      || summary.handoffRecoveryMilliseconds.length !== 2
      || summary.handoffRecoveryMilliseconds.some(
        (milliseconds) =>
          !Number.isSafeInteger(milliseconds)
          || milliseconds < 0
          || milliseconds > 4_000,
      )
      || !Number.isSafeInteger(summary.crashRestartPayloadMilliseconds)
      || summary.crashRestartPayloadMilliseconds < 0
      || summary.crashRestartPayloadMilliseconds > 4_000
    ) {
      throw new Error('macOS desktop network receipt is incomplete.')
    }
    return
  }

  if (
    summary.testedCliSha256 !== artifact.artifacts?.cli?.sha256
    || summary.testedCliSize !== artifact.artifacts?.cli?.size
    || (
      platform === 'linux'
      && summary.artifactReceiptSha256
        !== sha256FileSync(artifactReceiptPath)
    )
  ) {
    throw new Error(
      `${platform} desktop network receipt is not bound to the packaged CLI.`,
    )
  }

  const expectedDnsCases = Object.keys(desktopDnsCounters).sort()
  const actualDnsCases = Object.keys(summary.dnsCases ?? {}).sort()
  const handoffs = summary.handoffs
  if (
    actualDnsCases.length !== expectedDnsCases.length
    || actualDnsCases.some(
      (value, index) => value !== expectedDnsCases[index],
    )
    || !handoffs
    || typeof handoffs !== 'object'
    || Array.isArray(handoffs)
  ) {
    throw new Error(`${platform} desktop DNS/handoff receipt is incomplete.`)
  }
  for (const label of expectedDnsCases) {
    const expectedCounter = desktopDnsCounters[label]
    const values = summary.dnsCases[label]
    if (
      !values
      || Object.keys(values).length !== desktopDnsCounterNames.length * 2
    ) {
      throw new Error(`${platform} ${label} used the wrong DNS resolver path.`)
    }
    for (const counter of desktopDnsCounterNames) {
      const before = values[`before_${counter}`]
      const after = values[`after_${counter}`]
      if (
        !Number.isSafeInteger(before)
        || before < 0
        || !Number.isSafeInteger(after)
        || (
          counter === expectedCounter
            ? after <= before
            : after !== before
        )
      ) {
        throw new Error(
          `${platform} ${label} used the wrong DNS resolver path.`,
        )
      }
    }
  }
  for (const label of ['primaryToSecondary', 'secondaryToPrimary']) {
    const handoff = handoffs[label]
    if (
      !handoff
      || !Number.isSafeInteger(handoff.recoveryMilliseconds)
      || handoff.recoveryMilliseconds < 0
      || handoff.recoveryMilliseconds > 4_000
      || !Number.isSafeInteger(handoff.payloadDelta)
      || handoff.payloadDelta <= 0
      || !Number.isSafeInteger(handoff.wireGuardPayloadDelta)
      || handoff.wireGuardPayloadDelta <= 0
      || handoff.rebindDelta !== 1
    ) {
      throw new Error(`${platform} ${label} receipt is incomplete.`)
    }
  }
  if (
    platform === 'linux'
    && (
      !Number.isSafeInteger(summary.crashRepairMilliseconds)
      || summary.crashRepairMilliseconds < 0
      || summary.crashRepairMilliseconds > 4_000
    )
  ) {
    throw new Error('Linux crash-repair receipt is incomplete.')
  }
  if (
    platform === 'windows'
    && summary.nativeWireGuardOwnerFilesRepaired !== true
  ) {
    throw new Error('Windows native WireGuard crash-repair receipt is incomplete.')
  }
}

export function collectReleaseGateReceipts({
  commit,
  tree,
  releaseGateSummaryPath,
  platformReceiptPaths,
}) {
  const summary = readRequiredJson(
    releaseGateSummaryPath,
    'Release-gate completion receipt',
  )
  if (
    !Number.isSafeInteger(summary.elapsedSeconds)
    || summary.elapsedSeconds <= 0
    || !Number.isSafeInteger(summary.targetSeconds)
    || summary.targetSeconds <= 0
    || !['met', 'missed'].includes(summary.targetStatus)
  ) {
    throw new Error('Release-gate completion receipt is incomplete.')
  }

  const android = readRequiredJson(
    platformReceiptPaths.android.physical,
    'Physical Android artifact receipt',
  )
  const androidSource = requireReceiptComponentSource(
    android,
    'Physical Android artifact receipt',
  )
  if (androidSource.commit !== commit || androidSource.tree !== tree) {
    throw new Error(
      'Physical Android artifact receipt does not match the current release candidate SHA/tree.',
    )
  }
  if (
    android.receiptSchema !== 2
    || android.artifactType !== 'Android Release APK'
    || android.apkDerivedFromAab !== true
    || !/^[0-9a-f]{64}$/.test(android.aabSha256 ?? '')
    || !/^[0-9a-f]{64}$/.test(android.bundleReceiptSha256 ?? '')
    || android.bundletoolVersion !== '1.18.3'
    || android.bundletoolSha256
      !== 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29'
  ) {
    throw new Error(
      'Physical Android artifact is not the APK derived from the sealed Play AAB.',
    )
  }
  const androidReceiptSha256 = sha256FileSync(
    platformReceiptPaths.android.physical,
  )
  const androidInstall = readRequiredJson(
    platformReceiptPaths.android.install,
    'Canonical Android Release install receipt',
  )
  requireAndroidInstallReceipt(androidInstall, android)
  const androidInstallReceiptSha256 = sha256FileSync(
    platformReceiptPaths.android.install,
  )
  const androidInstallReceiptSize = readFileSync(
    platformReceiptPaths.android.install,
  ).byteLength
  for (const [name, mode] of [
    ['wireguard_dns', 'wireguard-dns'],
    ['underlay_lifecycle', 'underlay-lifecycle'],
  ]) {
    const receipt = readRequiredJson(
      platformReceiptPaths.android[name],
      `Physical Android ${mode} receipt`,
    )
    requireMobileNetworkReceipt({
      receipt,
      platform: 'android',
      mode,
      artifact: android,
      artifactReceiptSha256: androidReceiptSha256,
      ...androidSource,
    })
  }
  const androidReplacement = readRequiredJson(
    platformReceiptPaths.android.replacement_singleton,
    'Android Release replacement/singleton receipt',
  )
  if (
    androidReplacement.receiptSchema !== 1
    || androidReplacement.artifactType
      !== 'Android Release replacement/singleton gate'
    || androidReplacement.appGitSha !== androidSource.commit
    || androidReplacement.appGitTree !== androidSource.tree
    || androidReplacement.artifactReceiptSha256 !== androidReceiptSha256
    || androidReplacement.apkSha256 !== android.apkSha256
    || androidReplacement.installedApkSha256 !== android.installedApkSha256
    || androidReplacement.package !== android.package
    || androidReplacement.signerCertificateSha256
      !== android.signerCertificateSha256
    || androidReplacement.canonicalPackageCount !== 1
    || androidReplacement.retiredPackageCount !== 0
    || androidReplacement.canonicalMainProcessCount !== 1
    || androidReplacement.canonicalUpdatePreservedData !== true
    || androidReplacement.shippedRemovalPrompt !== true
    || androidReplacement.vpnStartBlockedBeforeCleanup !== true
    || androidReplacement.systemUninstallConfirmed !== true
  ) {
    throw new Error(
      'Android replacement/singleton receipt is not exact physical evidence.',
    )
  }

  const ios = readRequiredJson(
    platformReceiptPaths.ios.frozen_archive,
    'Frozen iOS physical-gate seal',
  )
  if (
    ios.receiptSchema !== 1
    || ios.artifactType !== 'iOS frozen archive physical-gate seal'
    || !Array.isArray(ios.requiredRealDeviceGates)
    || ios.requiredRealDeviceGates.length
      !== requiredFrozenIosRealDeviceGates.length
    || ios.requiredRealDeviceGates.some(
      (gate, index) => gate !== requiredFrozenIosRealDeviceGates[index],
    )
  ) {
    throw new Error('Frozen iOS physical-gate seal is incomplete.')
  }
  requireReceiptSource(ios, {
    commit,
    tree,
    label: 'Frozen iOS physical-gate seal',
  })
  const iosArtifact = readRequiredJson(
    platformReceiptPaths.ios.mobile_artifact,
    'Sealed physical iOS artifact receipt',
  )
  requireReceiptSource(iosArtifact, {
    commit,
    tree,
    label: 'Sealed physical iOS artifact receipt',
  })
  const iosArtifactReceiptSha256 = sha256FileSync(
    platformReceiptPaths.ios.mobile_artifact,
  )
  if (
    iosArtifact.receiptSchema !== 2
    || iosArtifact.artifactType !== 'iOS company Ad Hoc Release app'
    || ios.mobileArtifactReceiptSha256 !== iosArtifactReceiptSha256
  ) {
    throw new Error(
      'Frozen iOS physical-gate seal is not bound to the exact tested iOS artifact.',
    )
  }
  const iosNetworkReceipts = {}
  for (const [name, mode] of [
    ['wireguard_dns', 'wireguard-dns'],
    ['underlay_lifecycle', 'underlay-lifecycle'],
  ]) {
    const path = platformReceiptPaths.ios[name]
    const receipt = readRequiredJson(path, `Physical iOS ${mode} receipt`)
    requireMobileNetworkReceipt({
      receipt,
      platform: 'ios',
      mode,
      artifact: iosArtifact,
      artifactReceiptSha256: iosArtifactReceiptSha256,
      commit,
      tree,
    })
    iosNetworkReceipts[name] = sha256FileSync(path)
  }

  if (
    platformReceiptPaths.android.mobile_join
    !== platformReceiptPaths.ios.mobile_join
  ) {
    throw new Error(
      'Android and iOS release evidence must use one exact mobile join receipt.',
    )
  }
  const mobileJoin = readRequiredJson(
    platformReceiptPaths.android.mobile_join,
    'Android/iOS mobile join receipt',
  )
  requireMobileJoinReceipt({
    receipt: mobileJoin,
    commit,
    tree,
    androidArtifact: android,
    androidArtifactReceiptSha256: androidReceiptSha256,
    iosArtifact,
    iosArtifactReceiptSha256,
  })

  const macosArtifact = readRequiredJson(
    platformReceiptPaths.macos.artifact,
    'macOS Release artifact receipt',
  )
  if (
    macosArtifact.receiptSchema !== 1
    || macosArtifact.companySigningVerified !== true
    || macosArtifact.builtOnHost !== true
    || macosArtifact.builtOnTestVm !== false
    || !/^[0-9a-f]{64}$/.test(macosArtifact.cliExecutableSha256 ?? '')
  ) {
    throw new Error('macOS Release artifact receipt is incomplete.')
  }
  requireReceiptSource(macosArtifact, {
    commit,
    tree,
    label: 'macOS Release artifact receipt',
  })
  if (
    platformReceiptPaths.macos.public_ui_join
    !== platformReceiptPaths.ios.desktop_mobile_join
  ) {
    throw new Error(
      'macOS and iOS release evidence must use one exact desktop/mobile join receipt.',
    )
  }
  const macosJoin = readRequiredJson(
    platformReceiptPaths.macos.public_ui_join,
    'macOS/mobile public-UI join receipt',
  )
  requireMacosJoinReceipt({
    receipt: macosJoin,
    artifactReceipt: macosArtifact,
    artifactReceiptSha256: sha256FileSync(
      platformReceiptPaths.macos.artifact,
    ),
    iosArtifact,
    iosArtifactReceiptSha256,
    commit,
    tree,
  })
  const macosNetwork = readRequiredJson(
    platformReceiptPaths.macos.network,
    'macOS desktop network receipt',
  )
  requireDesktopNetworkReceipt({
    receipt: macosNetwork,
    platform: 'macos',
    commit,
    tree,
    artifactReceiptPath: platformReceiptPaths.macos.artifact,
  })
  const expectedIosGateReceipts = {
    'background-foreground-and-rapid-start-stop': [
      iosNetworkReceipts.wireguard_dns,
      iosNetworkReceipts.underlay_lifecycle,
    ],
    'bidirectional-mobile-qr-and-manual-join': [
      sha256FileSync(platformReceiptPaths.ios.mobile_join),
    ],
    'desktop-mobile-manual-join': [
      sha256FileSync(platformReceiptPaths.ios.desktop_mobile_join),
    ],
    'wifi-radio-off-on-recovery': [
      iosNetworkReceipts.underlay_lifecycle,
    ],
    'wireguard-exit-and-five-dns-policies': [
      iosNetworkReceipts.wireguard_dns,
    ],
  }
  if (
    JSON.stringify(ios.realDeviceGateReceiptSha256)
    !== JSON.stringify(expectedIosGateReceipts)
  ) {
    throw new Error(
      'Frozen iOS gate labels are not backed by the exact concrete receipts.',
    )
  }

  for (const platform of ['linux', 'windows']) {
    const artifact = readRequiredJson(
      platformReceiptPaths[platform].artifact,
      `${platform} exact desktop artifact receipt`,
    )
    requireReceiptSource(artifact, {
      commit,
      tree,
      label: `${platform} exact desktop artifact receipt`,
    })
    if (platform === 'linux') {
      const packageInstall = readRequiredJson(
        platformReceiptPaths.linux.package_install,
        'Linux exact Debian package install receipt',
      )
      const deb = artifact.artifacts?.debianPackage
      const app = artifact.artifacts?.app
      const cli = artifact.artifacts?.cli
      const muslCli = artifact.artifacts?.muslCli
      const muslArchive = artifact.artifacts?.muslCliArchive
      if (
        artifact.schema !== 2
        || !['local-docker', 'remote-native'].includes(artifact.builderMode)
        || (
          artifact.builderMode === 'local-docker'
          && (
            artifact.builtOnHostMac !== true
            || artifact.builtOnRemoteVm !== false
            || artifact.builderHostOs !== 'Darwin'
            || !['arm64', 'x86_64'].includes(
              artifact.builderHostArchitecture,
            )
          )
        )
        || (
          artifact.builderMode === 'remote-native'
          && (
            artifact.builtOnHostMac !== false
            || artifact.builtOnRemoteVm !== true
            || artifact.builderHostOs !== 'Linux'
            || artifact.builderHostArchitecture !== 'x86_64'
          )
        )
        || !/^sha256:[0-9a-f]{64}$/.test(artifact.containerImageId ?? '')
        || !/^[0-9a-f]{64}$/.test(artifact.dockerfileSha256 ?? '')
        || !/^[0-9a-f]{64}$/.test(
          artifact.containerPayloadSha256 ?? '',
        )
        || packageInstall.schema !== 2
        || packageInstall.artifactType
          !== 'exact Debian package installed on Ubuntu VM'
        || packageInstall.appGitSha !== commit
        || packageInstall.appGitTree !== tree
        || packageInstall.fipsGitSha !== artifact.fipsGitSha
        || packageInstall.fipsGitTree !== artifact.fipsGitTree
        || packageInstall.builderMode !== artifact.builderMode
        || packageInstall.builtOnHostMac !== artifact.builtOnHostMac
        || packageInstall.builtOnRemoteVm !== artifact.builtOnRemoteVm
        || packageInstall.builderHostOs !== artifact.builderHostOs
        || packageInstall.builderHostArchitecture
          !== artifact.builderHostArchitecture
        || packageInstall.containerImageId !== artifact.containerImageId
        || packageInstall.dockerfileSha256 !== artifact.dockerfileSha256
        || packageInstall.containerPayloadSha256
          !== artifact.containerPayloadSha256
        || packageInstall.package !== 'nostr-vpn'
        || packageInstall.packageArchitecture !== 'amd64'
        || packageInstall.packageInstalledByDpkg !== true
        || packageInstall.installedStatus !== 'installed'
        || packageInstall.installedAppPath !== '/usr/bin/nostr-vpn'
        || packageInstall.installedCliPath !== '/usr/bin/nvpn'
        || packageInstall.debSha256 !== deb?.sha256
        || packageInstall.debSize !== deb?.size
        || packageInstall.installedAppSha256 !== app?.sha256
        || packageInstall.installedCliSha256 !== cli?.sha256
        || packageInstall.muslCliSha256 !== muslCli?.sha256
        || packageInstall.muslArchiveSha256 !== muslArchive?.sha256
        || packageInstall.bundleReceiptSha256
          !== sha256FileSync(platformReceiptPaths.linux.artifact)
        || packageInstall.packagePayloadVerifiedBeforeInstall !== true
        || packageInstall.desktopEntryPresent !== true
        || packageInstall.iconThemeAssetPresent !== true
        || packageInstall.muslArchiveExtractedAndExecuted !== true
      ) {
        throw new Error(
          'Linux exact Debian package was not installed and verified on the Ubuntu gate VM.',
        )
      }
    } else {
      const installer = readRequiredJson(
        platformReceiptPaths.windows.installer,
        'Windows exact installer gate receipt',
      )
      validateWindowsInstallerGateReceipt({
        receipt: installer,
        artifactReceipt: artifact,
        commit,
        tree,
      })
    }
    const receipt = readRequiredJson(
      platformReceiptPaths[platform].public_ui_join,
      `${platform} / Pixel public-UI join receipt`,
    )
    requireDesktopMobileJoinReceipt({
      receipt,
      platform,
      desktopArtifact: artifact,
      desktopArtifactReceiptSha256: sha256FileSync(
        platformReceiptPaths[platform].artifact,
      ),
      androidArtifact: android,
      androidArtifactReceiptSha256: androidReceiptSha256,
      androidInstallReceiptSha256,
      androidInstallReceiptSize,
    })
    const network = readRequiredJson(
      platformReceiptPaths[platform].network,
      `${platform} desktop network receipt`,
    )
    requireDesktopNetworkReceipt({
      receipt: network,
      platform,
      commit,
      tree,
      artifactReceiptPath: platformReceiptPaths[platform].artifact,
    })
  }

  return {
    releaseGateSummarySha256: sha256FileSync(releaseGateSummaryPath),
    platformGateReceipts: Object.fromEntries(
      Object.entries(platformReceiptPaths).map(([platform, receipts]) => [
        platform,
        Object.fromEntries(
          Object.entries(receipts).map(([name, path]) => [
            name,
            sha256FileSync(path),
          ]),
        ),
      ]),
    ),
  }
}

export function releaseAssetSetSha256(assets) {
  if (!Array.isArray(assets)) {
    throw new Error('Release asset set is missing.')
  }
  const records = assets
    .map((asset) => ({
      path: String(asset?.path ?? ''),
      sha256: String(asset?.sha256 ?? ''),
      size: Number(asset?.size),
    }))
    .sort((left, right) => left.path.localeCompare(right.path))
  for (const record of records) {
    if (
      !record.path.startsWith('assets/')
      || !Number.isSafeInteger(record.size)
      || record.size <= 0
    ) {
      throw new Error('Release asset-set attestation contains an invalid asset record.')
    }
    requireSha256(record.sha256, `Release asset ${record.path}`)
  }
  return createHash('sha256')
    .update(JSON.stringify(records))
    .digest('hex')
}

export function buildReleaseGateAttestation({
  commit,
  tree,
  assets,
  releaseGateSummarySha256,
  platformGateReceipts,
  assetProofs,
}) {
  const normalizedCommit = String(commit ?? '').trim()
  const normalizedTree = String(tree ?? '').trim()
  if (!/^[0-9a-f]{40}$/.test(normalizedCommit)) {
    throw new Error('Release-gate attestation has an invalid application commit.')
  }
  if (!/^[0-9a-f]{40}$/.test(normalizedTree)) {
    throw new Error('Release-gate attestation has an invalid application tree.')
  }
  requireSha256(releaseGateSummarySha256, 'Release-gate summary')

  const receiptNames = Object.keys(platformGateReceipts ?? {}).sort()
  if (
    receiptNames.length !== requiredReleaseGatePlatforms.length
    || receiptNames.some(
      (name, index) => name !== requiredReleaseGatePlatforms[index],
    )
  ) {
    throw new Error(
      `Release-gate attestation must include exactly: ${requiredReleaseGatePlatforms.join(', ')}.`,
    )
  }
  const receipts = {}
  for (const name of receiptNames) {
    const receipt = platformGateReceipts[name]
    if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
      throw new Error(`Release-gate ${name} receipt is missing.`)
    }
    const digests = Object.fromEntries(
      Object.entries(receipt).sort(([left], [right]) => left.localeCompare(right)),
    )
    if (Object.keys(digests).length === 0) {
      throw new Error(`Release-gate ${name} receipt is empty.`)
    }
    for (const [label, digest] of Object.entries(digests)) {
      requireSha256(digest, `Release-gate ${name}.${label} receipt`)
    }
    receipts[name] = digests
  }

  const expectedAssetPaths = [...assets]
    .map((asset) => String(asset?.path ?? ''))
    .sort()
  const proofPaths = Object.keys(assetProofs ?? {}).sort()
  if (
    proofPaths.length !== expectedAssetPaths.length
    || proofPaths.some((path, index) => path !== expectedAssetPaths[index])
  ) {
    throw new Error(
      'Release-gate attestation must contain exactly one proof for every staged asset.',
    )
  }

  const proofs = {}
  const knownReceiptDigests = new Set([
    releaseGateSummarySha256,
    ...Object.values(receipts).flatMap((receipt) => Object.values(receipt)),
  ])
  for (const asset of assets) {
    const proof = assetProofs[asset.path]
    if (!proof || typeof proof !== 'object' || Array.isArray(proof)) {
      throw new Error(`Release asset ${asset.path} has no exact-artifact proof.`)
    }
    if (
      ![
        'gate-payload-identity',
        'post-build-exact-package-gate',
      ].includes(proof.verification)
      || !/^[a-z0-9-]+$/.test(String(proof.platform ?? ''))
    ) {
      throw new Error(`Release asset ${asset.path} has an invalid verification policy.`)
    }

    const expectedPlatform = releaseAssetPlatform(asset.path)
    if (proof.platform !== expectedPlatform) {
      throw new Error(
        `Release asset ${asset.path} has a proof for the wrong platform.`,
      )
    }
    if (proof.artifact_sha256 !== asset.sha256) {
      throw new Error(`Release asset ${asset.path} differs from its exact-artifact proof.`)
    }
    requireSha256(
      proof.gate_receipt_sha256,
      `Release asset ${asset.path} gate receipt`,
    )
    if (!knownReceiptDigests.has(proof.gate_receipt_sha256)) {
      throw new Error(
        `Release asset ${asset.path} proof is not linked to the release-gate receipts.`,
      )
    }
    if (
      requiredReleaseGatePlatforms.includes(proof.platform)
      && !Object.values(receipts[proof.platform]).includes(
        proof.gate_receipt_sha256,
      )
    ) {
      throw new Error(
        `Release asset ${asset.path} proof is not linked to its platform gate.`,
      )
    }
    const payloads = Object.fromEntries(
      Object.entries(proof.payloads ?? {})
        .sort(([left], [right]) => left.localeCompare(right)),
    )
    if (Object.keys(payloads).length === 0) {
      throw new Error(`Release asset ${asset.path} has no verified payload hashes.`)
    }
    for (const [label, digest] of Object.entries(payloads)) {
      requireSha256(digest, `Release asset ${asset.path} payload ${label}`)
    }

    let postBuildValidator
    if (proof.verification === 'post-build-exact-package-gate') {
      if (
        proof.platform !== 'startos'
        || proof.post_build_validator !== startosExactPackageValidator
        || payloads.package !== asset.sha256
        || !payloads.manifest_json
      ) {
        throw new Error(
          `Release asset ${asset.path} lacks a real exact-package StartOS validation.`,
        )
      }
      postBuildValidator = proof.post_build_validator
    } else if (proof.platform === 'startos' || proof.post_build_validator) {
      throw new Error(
        `Release asset ${asset.path} has an invalid exact-package validation policy.`,
      )
    }

    proofs[asset.path] = {
      platform: proof.platform,
      verification: proof.verification,
      artifact_sha256: proof.artifact_sha256,
      gate_receipt_sha256: proof.gate_receipt_sha256,
      ...(postBuildValidator
        ? { post_build_validator: postBuildValidator }
        : {}),
      payloads,
    }
  }

  return {
    receipt_schema: 1,
    policy: 'immutable-locally-gated-assets',
    app_git_sha: normalizedCommit,
    app_git_tree: normalizedTree,
    release_gate_summary_sha256: releaseGateSummarySha256,
    platform_gate_receipts: receipts,
    asset_proofs: proofs,
    asset_set_sha256: releaseAssetSetSha256(assets),
  }
}

export function validateReleaseGateAttestation(manifest) {
  const attestation = manifest?.release_gate_attestation
  if (!attestation || typeof attestation !== 'object') {
    throw new Error('Staged release has no release-gate asset attestation.')
  }
  if (
    attestation.receipt_schema !== 1
    || attestation.policy !== 'immutable-locally-gated-assets'
  ) {
    throw new Error('Staged release-gate asset attestation has the wrong policy.')
  }
  if (
    attestation.app_git_sha !== manifest.commit
    || !/^[0-9a-f]{40}$/.test(String(attestation.app_git_tree ?? ''))
  ) {
    throw new Error('Staged release-gate attestation has the wrong source revision.')
  }
  requireSha256(
    attestation.release_gate_summary_sha256,
    'Staged release-gate summary',
  )
  const expected = buildReleaseGateAttestation({
    commit: manifest.commit,
    tree: attestation.app_git_tree,
    assets: manifest.assets,
    releaseGateSummarySha256: attestation.release_gate_summary_sha256,
    platformGateReceipts: attestation.platform_gate_receipts,
    assetProofs: attestation.asset_proofs,
  })
  if (attestation.asset_set_sha256 !== expected.asset_set_sha256) {
    throw new Error(
      'Staged release assets differ from the set sealed by the real platform gates.',
    )
  }
  return attestation
}

export { startosExactPackageValidator }
