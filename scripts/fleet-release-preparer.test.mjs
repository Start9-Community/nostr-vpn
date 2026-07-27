import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  buildFrozenFleetInventory,
  validateFleetPublicationMetadata,
} from './fleet-release-preparer-lib.mjs'
import { deriveFleetArtifacts } from './prepare-fleet-release-canary.mjs'

const hex = (character, length = 64) => character.repeat(length)
const sha256 = (value) =>
  createHash('sha256').update(value).digest('hex')

function bound(path, character) {
  return {
    path,
    sha256: hex(character),
    size: 42,
  }
}

function installTarget(id = 'linux-main') {
  return {
    id,
    role: 'linux-service',
    platform: 'linux',
    arch: 'x86_64',
    transport: {
      kind: 'ssh',
      hostAlias: 'private-alias',
    },
    deployment: {
      binaryPath: '/usr/local/bin/nvpn',
      probeBinaryPath: '/usr/local/bin/nvpn',
      configPath: '/etc/nvpn/config.toml',
      serviceName: 'nvpn.service',
    },
    expected: {
      machineIdentitySha256: hex('1'),
      configSha256: hex('2'),
      signedRosterStoreSha256: hex('3'),
      rosterIdentitySha256: hex('4'),
      rosterPeerCount: 2,
      localDeviceIdentitySha256: hex('5'),
      networkIdentitySha256: hex('6'),
    },
    checks: {
      payloadTarget: '10.44.0.2',
      dnsName: 'example.com',
      directUrl: 'https://example.com/',
    },
  }
}

function rosterSnapshot() {
  return {
    schema: 1,
    authority: 'nvpn-known-host-roster-v1',
    capturedAt: 1_785_000_000,
    roles: [
      {
        id: 'linux-main',
        disposition: 'install',
        reason: 'reachable supported roster host',
        observedAt: 1_785_000_000,
        machineIdentitySha256: hex('1'),
        evidence: bound('/private/discovery-linux.json', 'a'),
        target: installTarget(),
      },
      {
        id: 'current-mac',
        disposition: 'excluded-current-mac',
        reason: 'release orchestrator host is explicitly excluded',
        observedAt: 1_785_000_000,
        machineIdentitySha256: hex('7'),
        evidence: bound('/private/discovery-current.json', 'b'),
        target: null,
      },
      {
        id: 'offline-edge',
        disposition: 'unreachable',
        reason: 'authoritative roster role was unreachable at capture time',
        observedAt: 1_785_000_000,
        machineIdentitySha256: null,
        evidence: bound('/private/discovery-offline.json', 'c'),
        target: null,
      },
      {
        id: 'unsupported-mac',
        disposition: 'unsupported-platform',
        reason: 'production canary has no macOS transactional adapter',
        observedAt: 1_785_000_000,
        machineIdentitySha256: hex('8'),
        evidence: bound('/private/discovery-unsupported.json', 'd'),
        target: null,
      },
    ],
  }
}

function publicationFixture() {
  const snapshot = rosterSnapshot()
  const snapshotBinding = bound('/private/roster-snapshot.json', 'e')
  const inventory = buildFrozenFleetInventory({
    snapshot,
    snapshotBinding,
    currentMacMachineIdentitySha256: hex('7'),
    parallelProbes: 4,
  })
  const source = {
    appGitSha: hex('a', 40),
    appGitTree: hex('b', 40),
    appVersion: '4.1.5',
    fipsGitSha: hex('c', 40),
    fipsGitTree: hex('d', 40),
    fipsVersion: '0.4.45',
  }
  const paths = {
    release: '/private/stage/release.json',
    driver: '/checkout/scripts/fleet_release_canary_ssh_driver.py',
  }
  const hashes = {
    manifestSha256: hex('f'),
    inventorySha256: hex('0'),
    driverSha256: hex('9'),
    releaseGateManifestSha256: hex('8'),
  }
  const helpers = [
    bound(
      '/checkout/scripts/fleet_release_canary_remote_linux.py',
      '6',
    ),
    bound(
      '/checkout/scripts/fleet_release_canary_remote_windows.ps1',
      '7',
    ),
  ]
  const manifest = {
    schema: 2,
    inventorySha256: hashes.inventorySha256,
    ...source,
    driver: {
      path: paths.driver,
      sha256: hashes.driverSha256,
      size: 42,
      protocol: 'nvpn-fleet-ssh-transactional-v2',
      helpers,
    },
    gateEvidence: [
      {
        id: 'complete-release-gate',
        kind: 'staged-release-attestation-v1',
        path: paths.release,
        sha256: hashes.releaseGateManifestSha256,
        size: 42,
        receiptPaths: {
          releaseGateSummary: bound('/private/gate-summary.json', '1'),
          platforms: {},
        },
      },
    ],
    artifacts: [{ id: 'linux-x86_64' }],
  }
  const probeBinding = bound('/private/probe-linux-main-raw.json', '2')
  const installBinding = bound('/private/install-linux-main-raw.json', '3')
  const result = {
    schema: 2,
    mode: 'execute',
    status: 'passed',
    manifestSha256: hashes.manifestSha256,
    inventorySha256: hashes.inventorySha256,
    driverSha256: hashes.driverSha256,
    releaseGateManifestSha256: hashes.releaseGateManifestSha256,
    ...source,
    targets: [
      {
        id: 'linux-main',
        status: 'passed',
        evidence: {
          probe: probeBinding,
          install: installBinding,
        },
      },
    ],
  }
  const rawReceipts = {
    'linux-main': {
      probe: {
        binding: probeBinding,
        value: {
          schema: 2,
          targetId: 'linux-main',
          realChecks: true,
          mocked: false,
          remoteBuildPerformed: false,
        },
      },
      install: {
        binding: installBinding,
        value: {
          schema: 2,
          targetId: 'linux-main',
          realChecks: true,
          mocked: false,
          remoteBuildPerformed: false,
          installAuthorized: true,
          transaction: { state: 'committed' },
          ...source,
        },
      },
    },
  }
  return {
    snapshot,
    inventory,
    source,
    paths,
    hashes,
    helpers,
    manifest,
    result,
    rawReceipts,
  }
}

test('authoritative roster snapshot yields one exact install target and explicit coverage', () => {
  const snapshot = rosterSnapshot()
  const inventory = buildFrozenFleetInventory({
    snapshot,
    snapshotBinding: bound('/private/roster-snapshot.json', 'e'),
    currentMacMachineIdentitySha256: hex('7'),
    parallelProbes: 4,
  })

  assert.equal(inventory.excludeCurrentHost, true)
  assert.deepEqual(
    inventory.targets.map(({ id, artifact }) => ({ id, artifact })),
    [{ id: 'linux-main', artifact: 'linux-x86_64' }],
  )
  assert.equal(
    inventory.targets[0].deployment.authorization,
    'install',
  )
  assert.deepEqual(
    inventory.rosterCoverage.map(({ id, disposition }) => ({
      id,
      disposition,
    })),
    [
      ['current-mac', 'excluded-current-mac'],
      ['linux-main', 'install'],
      ['offline-edge', 'unreachable'],
      ['unsupported-mac', 'unsupported-platform'],
    ].map(([id, disposition]) => ({ id, disposition })),
  )
  assert.equal(
    inventory.targetSetSha256,
    sha256('linux-main\n'),
  )
  assert.equal(
    inventory.currentMacExclusion.machineIdentitySha256,
    hex('7'),
  )
})

test('authoritative roster preserves explicit safe rollout order', () => {
  const snapshot = rosterSnapshot()
  const hypervisor = structuredClone(snapshot.roles[0])
  hypervisor.id = 'aaa-hypervisor'
  hypervisor.reason = 'transport host must install after its guest'
  hypervisor.machineIdentitySha256 = hex('9')
  hypervisor.target.id = hypervisor.id
  hypervisor.target.role = 'vm-hypervisor'
  hypervisor.target.expected.machineIdentitySha256 =
    hypervisor.machineIdentitySha256
  snapshot.roles.splice(1, 0, hypervisor)

  const inventory = buildFrozenFleetInventory({
    snapshot,
    snapshotBinding: bound('/private/roster-snapshot.json', 'e'),
    currentMacMachineIdentitySha256: hex('7'),
    parallelProbes: 4,
  })
  assert.deepEqual(
    inventory.targets.map(({ id }) => id),
    ['linux-main', 'aaa-hypervisor'],
  )
  assert.equal(
    inventory.targetSetSha256,
    sha256('aaa-hypervisor\nlinux-main\n'),
  )
})

test('authoritative roster snapshot rejects escape hatches and ambiguous coverage', () => {
  const cases = [
    [
      (value) => {
        value.roles[0].disposition = 'report-only'
      },
      /disposition/i,
    ],
    [
      (value) => {
        value.roles[0].target.artifact = 'hand-authored'
      },
      /artifact.*derived/i,
    ],
    [
      (value) => {
        value.roles.push(structuredClone(value.roles[0]))
      },
      /duplicate/i,
    ],
    [
      (value) => {
        value.roles = value.roles.filter(
          ({ disposition }) => disposition !== 'excluded-current-mac',
        )
      },
      /exactly one.*current Mac/i,
    ],
    [
      (value) => {
        value.roles[1].machineIdentitySha256 = hex('9')
      },
      /current Mac.*identity/i,
    ],
    [
      (value) => {
        value.roles[2].evidence.sha256 = 'not-a-digest'
      },
      /evidence/i,
    ],
    [
      (value) => {
        value.roles[0].target.deployment.authorization = 'install'
      },
      /authorization.*derived/i,
    ],
  ]

  for (const [mutate, error] of cases) {
    const snapshot = rosterSnapshot()
    mutate(snapshot)
    assert.throws(
      () =>
        buildFrozenFleetInventory({
          snapshot,
          snapshotBinding: bound(
            '/private/roster-snapshot.json',
            'e',
          ),
          currentMacMachineIdentitySha256: hex('7'),
          parallelProbes: 4,
        }),
      error,
    )
  }
})

test('publication accepts only exact executed all-passed fleet evidence', () => {
  const value = publicationFixture()
  const validated = validateFleetPublicationMetadata(value)
  assert.deepEqual(validated, value.source)
})

test('publication rejects forged hashes, source, target sets, and raw evidence', () => {
  const cases = [
    [
      (value) => {
        value.result.mode = 'plan'
      },
      /execute/i,
    ],
    [
      (value) => {
        value.result.status = 'incomplete'
      },
      /passed/i,
    ],
    [
      (value) => {
        value.result.appGitSha = hex('1', 40)
      },
      /appGitSha/i,
    ],
    [
      (value) => {
        value.result.fipsGitTree = hex('1', 40)
      },
      /fipsGitTree/i,
    ],
    [
      (value) => {
        value.result.manifestSha256 = hex('1')
      },
      /manifest SHA-256/i,
    ],
    [
      (value) => {
        value.result.inventorySha256 = hex('1')
      },
      /inventory SHA-256/i,
    ],
    [
      (value) => {
        value.result.driverSha256 = hex('1')
      },
      /driver SHA-256/i,
    ],
    [
      (value) => {
        value.result.releaseGateManifestSha256 = hex('1')
      },
      /staged release/i,
    ],
    [
      (value) => {
        value.result.targets.push(structuredClone(value.result.targets[0]))
      },
      /exact target set/i,
    ],
    [
      (value) => {
        value.result.targets[0].status = 'skipped-unreachable'
      },
      /pass/i,
    ],
    [
      (value) => {
        delete value.result.targets[0].evidence.install
      },
      /install, probe/i,
    ],
    [
      (value) => {
        value.result.targets[0].evidence.rollback = bound(
          '/private/rollback.json',
          '4',
        )
      },
      /install, probe/i,
    ],
    [
      (value) => {
        value.rawReceipts['linux-main'].install.value.mocked = true
      },
      /install.*real/i,
    ],
    [
      (value) => {
        value.rawReceipts['linux-main'].probe.value.targetId = 'other'
      },
      /targetId/i,
    ],
    [
      (value) => {
        value.inventory.targets.push({
          ...structuredClone(value.inventory.targets[0]),
          id: 'unsealed-target',
        })
      },
      /authoritative roster/i,
    ],
  ]

  for (const [mutate, error] of cases) {
    const value = publicationFixture()
    mutate(value)
    assert.throws(
      () => validateFleetPublicationMetadata(value),
      error,
    )
  }
})

test('preparer derives artifact receipts and payload labels from archive bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-fleet-preparer-'))
  try {
    const stageDir = join(root, 'stage')
    const assetsDir = join(stageDir, 'assets')
    const bundleDir = join(root, 'bundle', 'nvpn')
    const receiptDir = join(root, 'receipts')
    mkdirSync(assetsDir, { recursive: true })
    mkdirSync(bundleDir, { recursive: true })
    mkdirSync(receiptDir)
    const executable = join(bundleDir, 'nvpn')
    writeFileSync(executable, 'exact candidate binary\n')
    const assetName =
      'nvpn-v4.1.5-x86_64-unknown-linux-musl.tar.gz'
    const assetPath = join(assetsDir, assetName)
    const archived = spawnSync(
      'tar',
      ['-czf', assetPath, '-C', join(root, 'bundle'), 'nvpn/nvpn'],
      { encoding: 'utf8' },
    )
    assert.equal(archived.status, 0, archived.stderr)
    const assetSha256 = sha256(readFileSync(assetPath))
    const payloadSha256 = sha256(readFileSync(executable))
    const release = {
      tag: 'v4.1.5',
      assets: [
        {
          name: assetName,
          path: `assets/${assetName}`,
          sha256: assetSha256,
          size: statSync(assetPath).size,
        },
      ],
      release_gate_attestation: {
        asset_proofs: {
          [`assets/${assetName}`]: {
            platform: 'linux',
            artifact_sha256: assetSha256,
            payloads: {
              nvpn_musl: payloadSha256,
            },
          },
        },
      },
    }
    const inventory = buildFrozenFleetInventory({
      snapshot: rosterSnapshot(),
      snapshotBinding: bound('/private/roster-snapshot.json', 'e'),
      currentMacMachineIdentitySha256: hex('7'),
      parallelProbes: 4,
    })
    const source = publicationFixture().source
    const prepared = deriveFleetArtifacts({
      stageDir,
      release,
      inventory,
      receiptDir,
      source,
    })
    assert.equal(prepared.artifacts.length, 1)
    assert.equal(
      prepared.artifacts[0].installPayload.executableMember,
      'nvpn/nvpn',
    )
    const receipt = JSON.parse(
      readFileSync(prepared.artifacts[0].receipt.path, 'utf8'),
    )
    assert.equal(receipt.installedBinarySha256, payloadSha256)
    assert.deepEqual(receipt.releasePayloadLabels, {
      'nvpn/nvpn': 'nvpn_musl',
    })

    release.release_gate_attestation.asset_proofs[
      `assets/${assetName}`
    ].payloads.ambiguous = payloadSha256
    assert.throws(
      () =>
        deriveFleetArtifacts({
          stageDir,
          release,
          inventory,
          receiptDir,
          source,
        }),
      /exactly one staged payload proof/i,
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
