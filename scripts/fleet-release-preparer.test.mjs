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
} from './fleet-release-preparer-lib.mjs'
import { deriveFleetArtifacts } from './prepare-fleet-release-canary.mjs'

const hex = (character, length = 64) => character.repeat(length)
const sha256 = (value) =>
  createHash('sha256').update(value).digest('hex')
const validatedAtSeconds = 1_785_000_100

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
    catalogSha256: hex('e'),
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

function rosterCatalog(snapshot = rosterSnapshot()) {
  const capabilities = {
    'linux-main': {
      supported: true,
      reason: 'transactional Linux adapter is supported',
    },
    'current-mac': {
      supported: false,
      reason: 'current release host is never a fleet target',
    },
    'offline-edge': {
      supported: true,
      reason: 'transactional Linux adapter is supported',
    },
    'unsupported-mac': {
      supported: false,
      reason: 'production canary has no macOS transactional adapter',
    },
  }
  return {
    schema: 1,
    authority: 'nvpn-private-roster-catalog-v1',
    roles: snapshot.roles.map((role) => ({
      id: role.id,
      platform: role.target?.platform
        ?? (role.id === 'offline-edge' ? 'linux' : 'macos'),
      arch: role.target?.arch ?? 'aarch64',
      dependencies: [],
      capability: capabilities[role.id] ?? {
        supported: true,
        reason: 'transactional Linux adapter is supported',
      },
    })),
  }
}

function roleEvidence(snapshot, catalog = rosterCatalog(snapshot)) {
  const catalogById = new Map(
    catalog.roles.map((role) => [role.id, role]),
  )
  const kinds = {
    install: 'nvpn-roster-install-observation-v1',
    'excluded-current-mac': 'nvpn-roster-current-host-observation-v1',
    unreachable: 'nvpn-roster-unreachable-observation-v1',
    'unsupported-platform': 'nvpn-roster-capability-observation-v1',
  }
  return Object.fromEntries(snapshot.roles.map((role) => {
    const catalogRole = catalogById.get(role.id)
    return [
      role.id,
      {
        schema: 1,
        kind: kinds[role.disposition],
        roleId: role.id,
        disposition: role.disposition,
        observedAt: role.observedAt,
        machineIdentitySha256: role.machineIdentitySha256,
        platform: catalogRole.platform,
        arch: catalogRole.arch,
        reachable: role.disposition !== 'unreachable',
        installSupported: catalogRole.capability.supported,
        capabilityReason: catalogRole.capability.reason,
      },
    ]
  }))
}

function currentMacReceipt() {
  return {
    schema: 1,
    kind: 'nvpn-current-mac-measurement-v1',
    source: 'ioreg-IOPlatformUUID-sha256',
    measuredAt: 1_785_000_000,
    machineIdentitySha256: hex('7'),
  }
}

function inventoryArgs(snapshot = rosterSnapshot(), catalog = rosterCatalog(snapshot)) {
  return {
    catalog,
    catalogBinding: bound('/private/roster-catalog.json', 'e'),
    expectedCatalogSha256: hex('e'),
    snapshot,
    snapshotBinding: bound('/private/roster-snapshot.json', 'f'),
    currentMacReceipt: currentMacReceipt(),
    currentMacReceiptBinding: bound(
      '/private/current-mac-receipt.json',
      '0',
    ),
    roleEvidence: roleEvidence(snapshot, catalog),
    parallelProbes: 4,
    validatedAtSeconds,
    maxEvidenceAgeSeconds: 1_800,
  }
}

function releaseSource() {
  return {
    appGitSha: hex('a', 40),
    appGitTree: hex('b', 40),
    appVersion: '4.1.5',
    fipsGitSha: hex('c', 40),
    fipsGitTree: hex('d', 40),
    fipsVersion: '0.4.45',
  }
}

test('authoritative roster snapshot yields one exact install target and explicit coverage', () => {
  const snapshot = rosterSnapshot()
  const inventory = buildFrozenFleetInventory(inventoryArgs(snapshot))

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
  assert.equal(inventory.rosterCatalog.sha256, hex('e'))
  assert.equal(inventory.currentMacReceipt.sha256, hex('0'))
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

  const catalog = rosterCatalog(snapshot)
  catalog.roles[1].dependencies = ['linux-main']
  const inventory = buildFrozenFleetInventory(
    inventoryArgs(snapshot, catalog),
  )
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
      /current Mac/i,
    ],
    [
      (value) => {
        value.roles[1].machineIdentitySha256 = hex('9')
      },
      /current Mac.*(?:identity|measured receipt)/i,
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
        buildFrozenFleetInventory(inventoryArgs(snapshot)),
      error,
    )
  }
})

test('private roster catalog rejects omissions, fake evidence, staleness, and unsafe order', () => {
  const cases = [
    [
      (args) => {
        args.catalog.roles.pop()
      },
      /exact catalog role order/i,
    ],
    [
      (args) => {
        args.roleEvidence['linux-main'].kind = 'hand-authored-pass'
      },
      /schema or kind/i,
    ],
    [
      (args) => {
        args.freshnessCheckSeconds += 7_200
      },
      /stale/i,
    ],
    [
      (args) => {
        args.catalog.roles[0].dependencies = ['offline-edge']
      },
      /not topological/i,
    ],
    [
      (args) => {
        args.currentMacReceipt.source = 'typed-by-hand'
      },
      /provenance/i,
    ],
    [
      (args) => {
        args.expectedCatalogSha256 = hex('f')
      },
      /pinned SHA-256/i,
    ],
    [
      (args) => {
        const first = args.snapshot.roles[0]
        args.snapshot.roles[0] = args.snapshot.roles[1]
        args.snapshot.roles[1] = first
      },
      /exact catalog role order/i,
    ],
  ]
  for (const [mutate, error] of cases) {
    const args = inventoryArgs()
    args.freshnessCheckSeconds = validatedAtSeconds
    mutate(args)
    assert.throws(() => buildFrozenFleetInventory(args), error)
  }
})

test('public release roster rejects ARMv6 as an install target', () => {
  const snapshot = rosterSnapshot()
  const role = snapshot.roles[0]
  role.id = 'armv6-edge'
  role.target.id = role.id
  role.target.arch = 'armv6'
  const catalog = rosterCatalog(snapshot)
  assert.throws(
    () => buildFrozenFleetInventory(inventoryArgs(snapshot, catalog)),
    /architecture is unsupported/,
  )
})

test('private roster can represent fleet-only ARMv6 and unsupported ARMv7 as coverage', () => {
  for (const arch of ['armv6', 'armv7']) {
    const snapshot = rosterSnapshot()
    const catalog = rosterCatalog(snapshot)
    const role = catalog.roles.find(({ id }) => id === 'unsupported-mac')
    role.platform = 'linux'
    role.arch = arch
    role.capability.reason = `no staged ${arch} public release artifact`
    const snapshotRole = snapshot.roles.find(
      ({ id }) => id === 'unsupported-mac',
    )
    snapshotRole.reason = role.capability.reason
    const args = inventoryArgs(snapshot, catalog)
    assert.doesNotThrow(() => buildFrozenFleetInventory(args))
  }
})

test('preparer derives x86_64 receipts from public release archive bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-fleet-preparer-'))
  try {
    const stageDir = join(root, 'stage')
    const assetsDir = join(stageDir, 'assets')
    const bundleDir = join(root, 'bundle', 'nvpn')
    mkdirSync(assetsDir, { recursive: true })
    mkdirSync(bundleDir, { recursive: true })
    const executable = join(bundleDir, 'nvpn')
    writeFileSync(executable, 'exact candidate binary\n')
    const payloadSha256 = sha256(readFileSync(executable))
    const source = releaseSource()

    for (const { arch, assetName, payloadLabel } of [
      {
        arch: 'x86_64',
        assetName: 'nvpn-v4.1.5-x86_64-unknown-linux-musl.tar.gz',
        payloadLabel: 'nvpn_musl',
      },
    ]) {
      const receiptDir = join(root, `receipts-${arch}`)
      mkdirSync(receiptDir)
      const assetPath = join(assetsDir, assetName)
      const archived = spawnSync(
        'tar',
        ['-czf', assetPath, '-C', join(root, 'bundle'), 'nvpn/nvpn'],
        { encoding: 'utf8' },
      )
      assert.equal(archived.status, 0, archived.stderr)
      const assetSha256 = sha256(readFileSync(assetPath))
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
                [payloadLabel]: payloadSha256,
              },
            },
          },
        },
      }
      const snapshot = rosterSnapshot()
      snapshot.roles[0].target.arch = arch
      const inventory = buildFrozenFleetInventory(
        inventoryArgs(snapshot, rosterCatalog(snapshot)),
      )
      const prepared = deriveFleetArtifacts({
        stageDir,
        release,
        inventory,
        receiptDir,
        source,
      })
      assert.equal(prepared.artifacts.length, 1)
      assert.equal(prepared.artifacts[0].id, `linux-${arch}`)
      assert.equal(
        prepared.artifacts[0].installPayload.executableMember,
        'nvpn/nvpn',
      )
      const receipt = JSON.parse(
        readFileSync(prepared.artifacts[0].receipt.path, 'utf8'),
      )
      assert.equal(receipt.installedBinarySha256, payloadSha256)
      assert.deepEqual(receipt.releasePayloadLabels, {
        'nvpn/nvpn': payloadLabel,
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
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
