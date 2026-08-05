import { createHash } from 'node:crypto'
import { isAbsolute } from 'node:path'

import { validateFleetRosterInputs } from './fleet-roster-catalog-lib.mjs'

const fleetHex64 = /^[0-9a-f]{64}$/
const fleetRosterDispositions = new Set([
  'install',
  'excluded-current-mac',
  'unreachable',
  'unsupported-platform',
])

function requireFleetObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be a JSON object.`)
  }
  return value
}

function requireFleetExactKeys(value, expected, label) {
  requireFleetObject(value, label)
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (
    actual.length !== wanted.length
    || actual.some((key, index) => key !== wanted[index])
  ) {
    throw new Error(
      `${label} must contain exactly: ${wanted.join(', ')}.`,
    )
  }
  return value
}

function requireFleetHex(value, pattern, label) {
  if (typeof value !== 'string' || !pattern.test(value)) {
    throw new Error(`${label} must be an exact lowercase hexadecimal digest.`)
  }
  return value
}

function requireFleetPositiveInteger(value, label) {
  if (
    !Number.isSafeInteger(value)
    || typeof value !== 'number'
    || value <= 0
  ) {
    throw new Error(`${label} must be a positive integer.`)
  }
  return value
}

function requireFleetBoundFileMetadata(value, label) {
  requireFleetExactKeys(value, ['path', 'sha256', 'size'], label)
  if (typeof value.path !== 'string' || !isAbsolute(value.path)) {
    throw new Error(`${label}.path must be absolute.`)
  }
  requireFleetHex(value.sha256, fleetHex64, `${label}.sha256`)
  requireFleetPositiveInteger(value.size, `${label}.size`)
  return value
}

function requireFleetInstallTarget(target, role) {
  requireFleetObject(target, `Roster role ${role.id} target`)
  if (Object.hasOwn(target, 'artifact')) {
    throw new Error(
      `Roster role ${role.id} artifact mapping must be derived.`,
    )
  }
  requireFleetExactKeys(
    target,
    [
      'arch',
      'checks',
      'deployment',
      'expected',
      'id',
      'platform',
      'role',
      'transport',
    ],
    `Roster role ${role.id} target`,
  )
  if (target.id !== role.id) {
    throw new Error(`Roster role ${role.id} target id differs.`)
  }
  if (!['linux', 'windows'].includes(target.platform)) {
    throw new Error(`Roster role ${role.id} target platform is unsupported.`)
  }
  const arches = target.platform === 'windows'
    ? ['x86_64']
    : ['x86_64', 'aarch64']
  if (!arches.includes(target.arch)) {
    throw new Error(`Roster role ${role.id} target architecture is unsupported.`)
  }
  requireFleetObject(target.transport, `Roster role ${role.id} transport`)
  if (
    target.transport.kind !== 'ssh'
    || typeof target.transport.hostAlias !== 'string'
    || !target.transport.hostAlias.trim()
  ) {
    throw new Error(`Roster role ${role.id} requires an SSH transport.`)
  }
  requireFleetObject(target.deployment, `Roster role ${role.id} deployment`)
  if (
    Object.hasOwn(target.deployment, 'authorization')
    || Object.hasOwn(target.deployment, 'reason')
  ) {
    throw new Error(
      `Roster role ${role.id} deployment authorization must be derived.`,
    )
  }
  requireFleetObject(target.expected, `Roster role ${role.id} expected`)
  for (const field of [
    'machineIdentitySha256',
    'configSha256',
    'signedRosterStoreSha256',
    'rosterIdentitySha256',
    'localDeviceIdentitySha256',
    'networkIdentitySha256',
  ]) {
    requireFleetHex(
      target.expected[field],
      fleetHex64,
      `Roster role ${role.id} expected.${field}`,
    )
  }
  if (target.expected.machineIdentitySha256 !== role.machineIdentitySha256) {
    throw new Error(`Roster role ${role.id} machine identity differs.`)
  }
  if (
    !Number.isSafeInteger(target.expected.rosterPeerCount)
    || target.expected.rosterPeerCount < 0
  ) {
    throw new Error(`Roster role ${role.id} roster peer count is invalid.`)
  }
  requireFleetObject(target.checks, `Roster role ${role.id} checks`)
  for (const field of ['payloadTarget', 'dnsName', 'directUrl']) {
    if (
      typeof target.checks[field] !== 'string'
      || !target.checks[field].trim()
    ) {
      throw new Error(`Roster role ${role.id} checks.${field} is required.`)
    }
  }
}

function fleetTargetSetSha256(targets) {
  const text = targets
    .map(({ id }) => id)
    .sort()
    .map((id) => `${id}\n`)
    .join('')
  return createHash('sha256').update(text).digest('hex')
}

export function buildFrozenFleetInventory({
  catalog,
  catalogBinding,
  expectedCatalogSha256,
  snapshot,
  snapshotBinding,
  currentMacReceipt,
  currentMacReceiptBinding,
  roleEvidence,
  parallelProbes = 4,
  validatedAtSeconds,
  freshnessCheckSeconds = validatedAtSeconds,
  maxEvidenceAgeSeconds = 1_800,
}) {
  requireFleetExactKeys(
    snapshot,
    ['authority', 'capturedAt', 'catalogSha256', 'roles', 'schema'],
    'Authoritative roster snapshot',
  )
  if (
    snapshot.schema !== 1
    || snapshot.authority !== 'nvpn-known-host-roster-v1'
  ) {
    throw new Error('Authoritative roster snapshot schema or authority is invalid.')
  }
  requireFleetPositiveInteger(
    snapshot.capturedAt,
    'Authoritative roster snapshot capturedAt',
  )
  requireFleetBoundFileMetadata(snapshotBinding, 'Roster snapshot binding')
  requireFleetBoundFileMetadata(catalogBinding, 'Roster catalog binding')
  requireFleetBoundFileMetadata(
    currentMacReceiptBinding,
    'Measured current Mac receipt binding',
  )
  requireFleetPositiveInteger(
    validatedAtSeconds,
    'Roster inventory validation time',
  )
  requireFleetPositiveInteger(
    freshnessCheckSeconds,
    'Roster freshness check time',
  )
  validateFleetRosterInputs({
    catalog,
    catalogBinding,
    expectedCatalogSha256,
    snapshot,
    currentMacReceipt,
    currentMacReceiptBinding,
    roleEvidence,
    nowSeconds: freshnessCheckSeconds,
    maxAgeSeconds: maxEvidenceAgeSeconds,
  })
  const currentMacMachineIdentitySha256 =
    currentMacReceipt.machineIdentitySha256
  requireFleetHex(
    currentMacMachineIdentitySha256,
    fleetHex64,
    'Current Mac machine identity',
  )
  if (
    !Number.isSafeInteger(parallelProbes)
    || parallelProbes < 1
    || parallelProbes > 16
  ) {
    throw new Error('parallelProbes must be between 1 and 16.')
  }
  if (!Array.isArray(snapshot.roles) || snapshot.roles.length === 0) {
    throw new Error('Authoritative roster snapshot has no deployment roles.')
  }

  const seen = new Set()
  const installTargets = []
  const coverage = []
  const currentMacRoles = []
  for (const role of snapshot.roles) {
    requireFleetExactKeys(
      role,
      [
        'disposition',
        'evidence',
        'id',
        'machineIdentitySha256',
        'observedAt',
        'reason',
        'target',
      ],
      'Authoritative roster role',
    )
    if (typeof role.id !== 'string' || !role.id.trim()) {
      throw new Error('Authoritative roster role id is required.')
    }
    if (seen.has(role.id)) {
      throw new Error(`Authoritative roster contains duplicate role ${role.id}.`)
    }
    seen.add(role.id)
    if (!fleetRosterDispositions.has(role.disposition)) {
      throw new Error(
        `Authoritative roster role ${role.id} disposition is invalid.`,
      )
    }
    if (typeof role.reason !== 'string' || !role.reason.trim()) {
      throw new Error(`Authoritative roster role ${role.id} reason is required.`)
    }
    requireFleetPositiveInteger(
      role.observedAt,
      `Authoritative roster role ${role.id} observedAt`,
    )
    if (role.observedAt > snapshot.capturedAt) {
      throw new Error(
        `Authoritative roster role ${role.id} was observed after capture.`,
      )
    }
    requireFleetBoundFileMetadata(
      role.evidence,
      `Authoritative roster role ${role.id} evidence`,
    )
    if (role.machineIdentitySha256 !== null) {
      requireFleetHex(
        role.machineIdentitySha256,
        fleetHex64,
        `Authoritative roster role ${role.id} machine identity`,
      )
    }

    if (role.disposition === 'install') {
      requireFleetHex(
        role.machineIdentitySha256,
        fleetHex64,
        `Authoritative roster role ${role.id} machine identity`,
      )
      requireFleetInstallTarget(role.target, role)
      installTargets.push({
        ...role.target,
        artifact: `${role.target.platform}-${role.target.arch}`,
        deployment: {
          ...role.target.deployment,
          authorization: 'install',
        },
      })
    } else if (role.target !== null) {
      throw new Error(
        `Coverage-only roster role ${role.id} cannot carry an install target.`,
      )
    }
    if (role.disposition === 'excluded-current-mac') {
      currentMacRoles.push(role)
    }
    coverage.push({
      id: role.id,
      disposition: role.disposition,
      reason: role.reason,
      observedAt: role.observedAt,
      machineIdentitySha256: role.machineIdentitySha256,
      evidenceSha256: role.evidence.sha256,
    })
  }

  if (currentMacRoles.length !== 1) {
    throw new Error(
      'Authoritative roster must contain exactly one excluded current Mac.',
    )
  }
  const [currentMac] = currentMacRoles
  if (
    currentMac.machineIdentitySha256
    !== currentMacMachineIdentitySha256
  ) {
    throw new Error('Authoritative roster current Mac identity differs.')
  }
  if (installTargets.length === 0) {
    throw new Error('Authoritative roster has no installable fleet targets.')
  }
  if (
    installTargets.some(
      (target) =>
        target.expected.machineIdentitySha256
        === currentMacMachineIdentitySha256,
    )
  ) {
    throw new Error('Current Mac cannot appear in the fleet install targets.')
  }
  coverage.sort((left, right) => left.id.localeCompare(right.id))

  return {
    schema: 2,
    excludeCurrentHost: true,
    parallelProbes,
    rosterSnapshot: {
      ...snapshotBinding,
      authority: snapshot.authority,
      capturedAt: snapshot.capturedAt,
    },
    rosterCatalog: {
      ...catalogBinding,
      authority: catalog.authority,
    },
    currentMacReceipt: currentMacReceiptBinding,
    rosterFreshness: {
      validatedAt: validatedAtSeconds,
      maxAgeSeconds: maxEvidenceAgeSeconds,
    },
    currentMacExclusion: {
      id: currentMac.id,
      machineIdentitySha256: currentMac.machineIdentitySha256,
      observedAt: currentMac.observedAt,
      evidenceSha256: currentMac.evidence.sha256,
    },
    rosterCoverage: coverage,
    targetSetSha256: fleetTargetSetSha256(installTargets),
    targets: installTargets,
  }
}
