#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath, pathToFileURL } from 'node:url'

import {
  sha256FileSync,
  validatePromotableReleaseManifest,
  validateStagedReleaseTree,
} from './local-release-lib.mjs'
import { validateFleetReleaseGateEvidence } from './fleet-release-gate-evidence.mjs'
import { buildFrozenFleetInventory } from './fleet-release-preparer-lib.mjs'

const scriptRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const driverProtocol = 'nvpn-fleet-ssh-transactional-v2'
const driverRelative = 'scripts/fleet_release_canary_ssh_driver.py'
const helperRelatives = [
  'scripts/fleet_release_canary_remote_linux.py',
  'scripts/fleet_release_canary_remote_windows.ps1',
]

function fail(message) {
  throw new Error(`Fleet release preparation rejected: ${message}`)
}

function parseArgs(argv) {
  const values = {
    root: scriptRoot,
    stageDir: '',
    rosterSnapshot: process.env.NVPN_FLEET_ROSTER_SNAPSHOT_PATH || '',
    rosterCatalog: process.env.NVPN_FLEET_ROSTER_CATALOG_PATH || '',
    rosterCatalogSha256:
      process.env.NVPN_FLEET_ROSTER_CATALOG_SHA256 || '',
    currentMacReceipt:
      process.env.NVPN_FLEET_CURRENT_MAC_RECEIPT_PATH || '',
    outputDir: '',
    releaseGateLogDir: '',
    releaseJoinResultDir: '',
    parallelProbes: 4,
    maxEvidenceAgeSeconds: 1_800,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    switch (argument) {
      case '--root':
        values.root = argv[++index] ?? ''
        break
      case '--stage-dir':
        values.stageDir = argv[++index] ?? ''
        break
      case '--roster-snapshot':
        values.rosterSnapshot = argv[++index] ?? ''
        break
      case '--roster-catalog':
        values.rosterCatalog = argv[++index] ?? ''
        break
      case '--roster-catalog-sha256':
        values.rosterCatalogSha256 = argv[++index] ?? ''
        break
      case '--current-mac-receipt':
        values.currentMacReceipt = argv[++index] ?? ''
        break
      case '--output-dir':
        values.outputDir = argv[++index] ?? ''
        break
      case '--release-gate-log-dir':
        values.releaseGateLogDir = argv[++index] ?? ''
        break
      case '--release-join-result-dir':
        values.releaseJoinResultDir = argv[++index] ?? ''
        break
      case '--parallel-probes':
        values.parallelProbes = Number(argv[++index] ?? '')
        break
      case '--max-evidence-age-seconds':
        values.maxEvidenceAgeSeconds = Number(argv[++index] ?? '')
        break
      case '--help':
      case '-h':
        console.log(`Usage: node scripts/prepare-fleet-release-canary.mjs \\
  --stage-dir DIR --roster-snapshot JSON --roster-catalog JSON \\
  --roster-catalog-sha256 SHA256 --current-mac-receipt JSON \\
  --output-dir DIR [options]

Creates the private inventory, exact artifact receipts, and fleet manifest from
the immutable staged release and authoritative roster snapshot. It never builds,
contacts, or installs on a fleet target.

Options:
  --root DIR                     Exact app checkout (default: script checkout)
  --release-gate-log-dir DIR     Release gate receipts directory
  --release-join-result-dir DIR  Desktop/mobile join receipts directory
  --parallel-probes N            Concurrent read-only probes (default: 4)
  --max-evidence-age-seconds N   Observation freshness limit (default/max: 1800)`)
        process.exit(0)
        break
      default:
        fail(`unknown argument ${argument}`)
    }
  }
  for (const field of [
    'stageDir',
    'rosterSnapshot',
    'rosterCatalog',
    'rosterCatalogSha256',
    'currentMacReceipt',
    'outputDir',
  ]) {
    if (!String(values[field]).trim()) {
      fail(`--${field.replace(/[A-Z]/g, (match) => `-${match.toLowerCase()}`)} is required`)
    }
  }
  return values
}

function requirePrivatePath(root, path, label) {
  if (typeof path !== 'string' || !path.trim()) {
    fail(`${label} path is required`)
  }
  const rootPath = resolve(root)
  const candidate = resolve(path)
  const relativePath = relative(rootPath, candidate)
  if (relativePath.startsWith('..') || relativePath === '') {
    return candidate
  }
  const ignored = spawnSync(
    'git',
    ['-C', rootPath, 'check-ignore', '-q', '--no-index', '--', relativePath],
    { stdio: 'ignore' },
  )
  if (ignored.status !== 0) {
    fail(`${label} must be outside the checkout or ignored as private`)
  }
  return candidate
}

function regularFile(path, label) {
  let metadata
  try {
    metadata = lstatSync(path)
  } catch {
    fail(`${label} is missing: ${path}`)
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    fail(`${label} must be a regular non-symlink file`)
  }
  return metadata
}

function readJson(path, label) {
  regularFile(path, label)
  try {
    const value = JSON.parse(readFileSync(path, 'utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      fail(`${label} must be a JSON object`)
    }
    return value
  } catch (error) {
    fail(`${label} is invalid JSON: ${error.message}`)
  }
}

function boundFile(path, label) {
  const requested = resolve(path)
  const metadata = regularFile(requested, label)
  const absolute = realpathSync(requested)
  return {
    path: absolute,
    sha256: sha256FileSync(absolute),
    size: metadata.size,
  }
}

function validateBoundFile(binding, label) {
  const actual = boundFile(binding.path, label)
  if (
    actual.path !== binding.path
    || actual.sha256 !== binding.sha256
    || actual.size !== binding.size
  ) {
    fail(`${label} differs from its authoritative binding`)
  }
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, {
    mode: 0o600,
  })
  chmodSync(path, 0o600)
}

function receiptPaths({ root, gateDir, joinDir }) {
  const mobileNetwork = join(gateDir, 'mobile-network')
  const desktopNetwork = join(gateDir, 'desktop-network')
  return {
    android: {
      physical: join(
        gateDir,
        'mobile-release-artifacts',
        'android.json',
      ),
      mobile_join: join(joinDir, 'summary.json'),
      wireguard_dns: join(mobileNetwork, 'android-wireguard-dns.json'),
      underlay_lifecycle: join(
        mobileNetwork,
        'android-underlay-lifecycle.json',
      ),
      replacement_singleton: join(
        mobileNetwork,
        'android-replacement-artifacts',
        'mobile-android-legacy-replacement.json',
      ),
    },
    ios: {
      frozen_archive: join(
        root,
        'dist',
        'ios',
        'frozen',
        'physical-gate-seal.json',
      ),
      mobile_artifact: join(
        root,
        'dist',
        'ios',
        'frozen',
        'physical-mobile-receipt.json',
      ),
      mobile_join: join(joinDir, 'summary.json'),
      desktop_mobile_join: join(joinDir, 'macos', 'summary.json'),
      wireguard_dns: join(mobileNetwork, 'ios-wireguard-dns.json'),
      underlay_lifecycle: join(
        mobileNetwork,
        'ios-underlay-lifecycle.json',
      ),
    },
    linux: {
      artifact: join(
        joinDir,
        'linux',
        'import',
        'host-bundle-receipt.json',
      ),
      public_ui_join: join(joinDir, 'linux', 'summary.json'),
      package_install: join(
        joinDir,
        'linux',
        'import',
        'debian-package-install.json',
      ),
      network: join(desktopNetwork, 'linux.json'),
    },
    macos: {
      artifact: join(joinDir, 'macos', 'artifact.json'),
      public_ui_join: join(joinDir, 'macos', 'summary.json'),
      network: join(desktopNetwork, 'macos.json'),
    },
    windows: {
      artifact: join(
        joinDir,
        'windows',
        'windows-release-artifact.json',
      ),
      installer: join(
        gateDir,
        'windows-installer',
        'installer-receipt.json',
      ),
      public_ui_join: join(joinDir, 'windows', 'summary.json'),
      network: join(desktopNetwork, 'windows.json'),
    },
  }
}

function commandBytes(command, args, label) {
  const result = spawnSync(command, args, {
    encoding: null,
    maxBuffer: 256 * 1024 * 1024,
  })
  if (result.status !== 0) {
    fail(`${label} failed`)
  }
  return result.stdout
}

function memberSha256(assetPath, format, member) {
  const bytes = format === 'tar-gz'
    ? commandBytes('tar', ['-xOzf', assetPath, member], `extract ${member}`)
    : commandBytes('unzip', ['-p', assetPath, member], `extract ${member}`)
  return createHash('sha256').update(bytes).digest('hex')
}

function payloadLabel(proof, digest, label) {
  const matches = Object.entries(proof?.payloads ?? {})
    .filter(([, value]) => value === digest)
    .map(([name]) => name)
  if (matches.length !== 1) {
    fail(`${label} does not map to exactly one staged payload proof`)
  }
  return matches[0]
}

function artifactShape(platform, arch, tag) {
  if (platform === 'linux' && ['x86_64', 'aarch64'].includes(arch)) {
    return {
      name: `nvpn-${tag}-${arch}-unknown-linux-musl.tar.gz`,
      format: 'tar-gz',
      executableMember: 'nvpn/nvpn',
      companionMembers: [],
    }
  }
  if (platform === 'windows' && arch === 'x86_64') {
    return {
      name: `nvpn-${tag}-x86_64-pc-windows-msvc.zip`,
      format: 'zip',
      executableMember: 'nvpn.exe',
      companionMembers: ['binaries/wintun.dll'],
    }
  }
  fail(`no staged fleet artifact supports ${platform}/${arch}`)
}

export function deriveFleetArtifacts({
  stageDir,
  release,
  inventory,
  receiptDir,
  source,
}) {
  const assetsByName = new Map(
    release.assets.map((asset) => [asset.name, asset]),
  )
  const targetKinds = []
  const seen = new Set()
  for (const target of inventory.targets) {
    const id = `${target.platform}-${target.arch}`
    if (!seen.has(id)) {
      targetKinds.push({
        id,
        platform: target.platform,
        arch: target.arch,
      })
      seen.add(id)
    }
  }

  const artifacts = []
  const receipts = []
  for (const target of targetKinds) {
    const shape = artifactShape(
      target.platform,
      target.arch,
      release.tag,
    )
    const asset = assetsByName.get(shape.name)
    if (!asset) {
      fail(`staged release has no exact ${shape.name}`)
    }
    const assetPath = join(stageDir, asset.path)
    regularFile(assetPath, `fleet artifact ${shape.name}`)
    if (
      sha256FileSync(assetPath) !== asset.sha256
      || statSync(assetPath).size !== asset.size
    ) {
      fail(`fleet artifact ${shape.name} differs from the staged manifest`)
    }
    const proof = release.release_gate_attestation?.asset_proofs?.[asset.path]
    if (
      proof?.platform !== target.platform
      || proof?.artifact_sha256 !== asset.sha256
    ) {
      fail(`fleet artifact ${shape.name} lacks an exact platform proof`)
    }
    const members = [
      shape.executableMember,
      ...shape.companionMembers,
    ]
    const installedPayloads = {}
    const releasePayloadLabels = {}
    for (const member of members) {
      const digest = memberSha256(assetPath, shape.format, member)
      installedPayloads[member] = digest
      releasePayloadLabels[member] = payloadLabel(
        proof,
        digest,
        `${shape.name}:${member}`,
      )
    }
    const receipt = {
      schema: 1,
      ...source,
      platform: target.platform,
      arch: target.arch,
      artifactSha256: asset.sha256,
      artifactSize: asset.size,
      installedBinarySha256:
        installedPayloads[shape.executableMember],
      installedPayloads,
      gateEvidenceIds: ['complete-release-gate'],
      releaseAssetPath: asset.path,
      releasePayloadLabels,
    }
    const receiptPath = join(receiptDir, `${target.id}.json`)
    writeJson(receiptPath, receipt)
    receipts.push(receiptPath)
    artifacts.push({
      id: target.id,
      platform: target.platform,
      arch: target.arch,
      path: realpathSync(resolve(assetPath)),
      sha256: asset.sha256,
      size: asset.size,
      installPayload: {
        format: shape.format,
        executableMember: shape.executableMember,
        companions: shape.companionMembers.map((member) => ({
          member,
          sha256: installedPayloads[member],
        })),
      },
      receipt: boundFile(receiptPath, `${target.id} receipt`),
    })
  }
  return { artifacts, receipts }
}

function boundReceiptPaths(paths) {
  return {
    releaseGateSummary: boundFile(
      paths.releaseGateSummary,
      'release-gate summary',
    ),
    platforms: Object.fromEntries(
      Object.entries(paths.platforms).map(([platform, receipts]) => [
        platform,
        Object.fromEntries(
          Object.entries(receipts).map(([name, path]) => [
            name,
            boundFile(path, `${platform}.${name} receipt`),
          ]),
        ),
      ]),
    ),
  }
}

export function prepareFleetReleaseCanary(options) {
  const root = resolve(options.root)
  const stageDir = resolve(options.stageDir)
  const rosterPath = requirePrivatePath(
    root,
    options.rosterSnapshot,
    'authoritative roster snapshot',
  )
  const catalogPath = requirePrivatePath(
    root,
    options.rosterCatalog,
    'private roster catalog',
  )
  const currentMacReceiptPath = requirePrivatePath(
    root,
    options.currentMacReceipt,
    'measured current Mac receipt',
  )
  const outputDir = requirePrivatePath(
    root,
    options.outputDir,
    'fleet preparation output',
  )
  if (existsSync(outputDir)) {
    fail(`output directory already exists: ${outputDir}`)
  }
  const releasePath = join(stageDir, 'release.json')
  const release = readJson(releasePath, 'staged release')
  validateStagedReleaseTree(stageDir, release)
  validatePromotableReleaseManifest(release)
  const catalog = readJson(catalogPath, 'private roster catalog')
  const currentMacReceipt = readJson(
    currentMacReceiptPath,
    'measured current Mac receipt',
  )
  const roster = readJson(rosterPath, 'authoritative roster snapshot')
  const roleEvidence = {}
  for (const role of roster.roles ?? []) {
    requirePrivatePath(
      root,
      role.evidence?.path,
      `roster evidence for ${role.id}`,
    )
    validateBoundFile(role.evidence, `roster evidence for ${role.id}`)
    roleEvidence[role.id] = readJson(
      role.evidence.path,
      `roster evidence for ${role.id}`,
    )
  }
  const validatedAtSeconds = Math.floor(Date.now() / 1000)
  const inventory = buildFrozenFleetInventory({
    catalog,
    catalogBinding: boundFile(catalogPath, 'private roster catalog'),
    expectedCatalogSha256: options.rosterCatalogSha256,
    snapshot: roster,
    snapshotBinding: boundFile(rosterPath, 'authoritative roster snapshot'),
    currentMacReceipt,
    currentMacReceiptBinding: boundFile(
      currentMacReceiptPath,
      'measured current Mac receipt',
    ),
    roleEvidence,
    parallelProbes: options.parallelProbes,
    validatedAtSeconds,
    maxEvidenceAgeSeconds: options.maxEvidenceAgeSeconds,
  })

  const gateDir = resolve(
    options.releaseGateLogDir
      || join(
        root,
        'artifacts',
        'release-gate-logs',
        `local-release-${release.tag}`,
      ),
  )
  const joinDir = resolve(
    options.releaseJoinResultDir
      || join(root, 'artifacts', 'mobile-release-join'),
  )
  const platforms = receiptPaths({ root, gateDir, joinDir })
  const releaseGateSummary = join(gateDir, 'release-gate-summary.json')
  const linuxArtifact = readJson(
    platforms.linux.artifact,
    'Linux exact artifact receipt',
  )
  const source = {
    appGitSha: release.commit,
    appGitTree: release.release_gate_attestation.app_git_tree,
    appVersion: release.tag.replace(/^v/, ''),
    fipsGitSha: linuxArtifact.fipsGitSha,
    fipsGitTree: linuxArtifact.fipsGitTree,
    fipsVersion: linuxArtifact.fipsVersion,
  }
  validateFleetReleaseGateEvidence({
    releasePath,
    source,
    receiptPaths: {
      releaseGateSummary,
      platforms,
    },
  })

  mkdirSync(outputDir, { recursive: true, mode: 0o700 })
  chmodSync(outputDir, 0o700)
  const receiptDir = join(outputDir, 'artifact-receipts')
  mkdirSync(receiptDir, { mode: 0o700 })
  const inventoryPath = join(outputDir, 'inventory.json')
  writeJson(inventoryPath, inventory)
  const { artifacts } = deriveFleetArtifacts({
    stageDir,
    release,
    inventory,
    receiptDir,
    source,
  })
  const driver = boundFile(
    join(root, driverRelative),
    'production fleet driver',
  )
  const helpers = helperRelatives.map((relative) =>
    boundFile(join(root, relative), `production fleet helper ${relative}`),
  )
  const gateEvidence = {
    id: 'complete-release-gate',
    kind: 'staged-release-attestation-v1',
    ...boundFile(releasePath, 'staged release manifest'),
    receiptPaths: boundReceiptPaths({
      releaseGateSummary,
      platforms,
    }),
  }
  const manifest = {
    schema: 2,
    inventorySha256: sha256FileSync(inventoryPath),
    ...source,
    driver: {
      ...driver,
      protocol: driverProtocol,
      helpers,
    },
    gateEvidence: [gateEvidence],
    artifacts,
  }
  const manifestPath = join(outputDir, 'manifest.json')
  writeJson(manifestPath, manifest)
  const evidenceDir = join(outputDir, 'evidence')
  mkdirSync(evidenceDir, { mode: 0o700 })
  return {
    inventoryPath,
    manifestPath,
    evidenceDir,
    source,
    targetIds: inventory.targets.map(({ id }) => id),
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2))
  const prepared = prepareFleetReleaseCanary(options)
  console.log(JSON.stringify(prepared, null, 2))
}

if (
  process.argv[1]
  && pathToFileURL(process.argv[1]).href === import.meta.url
) {
  try {
    main()
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
