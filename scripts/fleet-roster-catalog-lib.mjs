import { isDeepStrictEqual } from 'node:util'

const hex64 = /^[0-9a-f]{64}$/
const dispositions = new Set([
  'install',
  'excluded-current-mac',
  'unreachable',
  'unsupported-platform',
])
const evidenceKinds = {
  install: 'nvpn-roster-install-observation-v1',
  'excluded-current-mac': 'nvpn-roster-current-host-observation-v1',
  unreachable: 'nvpn-roster-unreachable-observation-v1',
  'unsupported-platform': 'nvpn-roster-capability-observation-v1',
}

function objectValue(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be a JSON object.`)
  }
  return value
}

function exactKeys(value, keys, label) {
  objectValue(value, label)
  const actual = Object.keys(value).sort()
  const expected = [...keys].sort()
  if (!isDeepStrictEqual(actual, expected)) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}.`)
  }
}

function digest(value, label) {
  if (typeof value !== 'string' || !hex64.test(value)) {
    throw new Error(`${label} must be an exact lowercase SHA-256 digest.`)
  }
  return value
}

function timestamp(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${label} must be a positive Unix timestamp.`)
  }
  return value
}

function nonempty(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${label} is required.`)
  }
  return value
}

function requireFresh({
  value,
  nowSeconds,
  maxAgeSeconds,
  label,
}) {
  timestamp(value, label)
  if (value > nowSeconds + 300) {
    throw new Error(`${label} is implausibly in the future.`)
  }
  if (nowSeconds - value > maxAgeSeconds) {
    throw new Error(`${label} is stale.`)
  }
}

function validateCatalog({
  catalog,
  catalogBinding,
  expectedCatalogSha256,
}) {
  exactKeys(
    catalog,
    ['authority', 'roles', 'schema'],
    'Private roster catalog',
  )
  if (
    catalog.schema !== 1
    || catalog.authority !== 'nvpn-private-roster-catalog-v1'
  ) {
    throw new Error('Private roster catalog schema or authority is invalid.')
  }
  digest(catalogBinding?.sha256, 'Private roster catalog binding')
  digest(expectedCatalogSha256, 'Pinned private roster catalog SHA-256')
  if (catalogBinding.sha256 !== expectedCatalogSha256) {
    throw new Error('Private roster catalog differs from its pinned SHA-256.')
  }
  if (!Array.isArray(catalog.roles) || catalog.roles.length === 0) {
    throw new Error('Private roster catalog has no deployment roles.')
  }

  const roles = new Map()
  for (const [index, role] of catalog.roles.entries()) {
    exactKeys(
      role,
      ['arch', 'capability', 'dependencies', 'id', 'platform'],
      `Private roster catalog role ${index}`,
    )
    nonempty(role.id, `Private roster catalog role ${index} id`)
    if (roles.has(role.id)) {
      throw new Error(`Private roster catalog contains duplicate role ${role.id}.`)
    }
    if (!['linux', 'windows', 'macos'].includes(role.platform)) {
      throw new Error(`Private roster catalog role ${role.id} platform is invalid.`)
    }
    const validArches = role.platform === 'windows'
      ? ['x86_64']
      : ['x86_64', 'aarch64', 'armv6', 'armv7']
    if (!validArches.includes(role.arch)) {
      throw new Error(
        `Private roster catalog role ${role.id} architecture is invalid.`,
      )
    }
    exactKeys(
      role.capability,
      ['reason', 'supported'],
      `Private roster catalog role ${role.id} capability`,
    )
    if (typeof role.capability.supported !== 'boolean') {
      throw new Error(
        `Private roster catalog role ${role.id} capability.supported must be boolean.`,
      )
    }
    nonempty(
      role.capability.reason,
      `Private roster catalog role ${role.id} capability reason`,
    )
    if (
      !Array.isArray(role.dependencies)
      || new Set(role.dependencies).size !== role.dependencies.length
    ) {
      throw new Error(
        `Private roster catalog role ${role.id} dependencies are invalid.`,
      )
    }
    for (const dependency of role.dependencies) {
      nonempty(
        dependency,
        `Private roster catalog role ${role.id} dependency`,
      )
      if (!roles.has(dependency)) {
        throw new Error(
          `Private roster catalog is not topological: ${role.id} must follow ${dependency}.`,
        )
      }
    }
    roles.set(role.id, role)
  }
  return roles
}

function validateCurrentMacReceipt({
  currentMacReceipt,
  currentMacReceiptBinding,
  nowSeconds,
  maxAgeSeconds,
}) {
  exactKeys(
    currentMacReceipt,
    ['kind', 'machineIdentitySha256', 'measuredAt', 'schema', 'source'],
    'Measured current Mac receipt',
  )
  if (
    currentMacReceipt.schema !== 1
    || currentMacReceipt.kind !== 'nvpn-current-mac-measurement-v1'
    || currentMacReceipt.source !== 'ioreg-IOPlatformUUID-sha256'
  ) {
    throw new Error('Measured current Mac receipt provenance is invalid.')
  }
  digest(
    currentMacReceipt.machineIdentitySha256,
    'Measured current Mac identity',
  )
  requireFresh({
    value: currentMacReceipt.measuredAt,
    nowSeconds,
    maxAgeSeconds,
    label: 'Measured current Mac receipt',
  })
  digest(
    currentMacReceiptBinding?.sha256,
    'Measured current Mac receipt binding',
  )
  return currentMacReceipt
}

function validateRoleEvidence({
  role,
  catalogRole,
  evidence,
  nowSeconds,
  maxAgeSeconds,
}) {
  exactKeys(
    evidence,
    [
      'arch',
      'capabilityReason',
      'disposition',
      'installSupported',
      'kind',
      'machineIdentitySha256',
      'observedAt',
      'platform',
      'reachable',
      'roleId',
      'schema',
    ],
    `Roster evidence for ${role.id}`,
  )
  if (
    evidence.schema !== 1
    || evidence.kind !== evidenceKinds[role.disposition]
  ) {
    throw new Error(`Roster evidence for ${role.id} has the wrong schema or kind.`)
  }
  for (const [field, expected] of [
    ['roleId', role.id],
    ['disposition', role.disposition],
    ['platform', catalogRole.platform],
    ['arch', catalogRole.arch],
    ['observedAt', role.observedAt],
    ['machineIdentitySha256', role.machineIdentitySha256],
    ['installSupported', catalogRole.capability.supported],
    ['capabilityReason', catalogRole.capability.reason],
  ]) {
    if (evidence[field] !== expected) {
      throw new Error(`Roster evidence for ${role.id} ${field} differs.`)
    }
  }
  if (typeof evidence.reachable !== 'boolean') {
    throw new Error(`Roster evidence for ${role.id} reachable must be boolean.`)
  }
  requireFresh({
    value: evidence.observedAt,
    nowSeconds,
    maxAgeSeconds,
    label: `Roster evidence for ${role.id}`,
  })

  if (role.disposition === 'install') {
    if (!catalogRole.capability.supported || evidence.reachable !== true) {
      throw new Error(`Install roster role ${role.id} lacks supported reachability.`)
    }
  } else if (role.disposition === 'unreachable') {
    if (!catalogRole.capability.supported || evidence.reachable !== false) {
      throw new Error(`Unreachable roster role ${role.id} evidence is inconsistent.`)
    }
  } else if (role.disposition === 'unsupported-platform') {
    if (
      catalogRole.capability.supported
      || role.reason !== catalogRole.capability.reason
    ) {
      throw new Error(
        `Unsupported roster role ${role.id} lacks its catalog capability reason.`,
      )
    }
  } else if (evidence.reachable !== true) {
    throw new Error(`Excluded current Mac ${role.id} must be measured reachable.`)
  }
}

export function validateFleetRosterInputs({
  catalog,
  catalogBinding,
  expectedCatalogSha256,
  snapshot,
  currentMacReceipt,
  currentMacReceiptBinding,
  roleEvidence,
  nowSeconds,
  maxAgeSeconds,
}) {
  timestamp(nowSeconds, 'Roster validation time')
  if (
    !Number.isSafeInteger(maxAgeSeconds)
    || maxAgeSeconds < 300
    || maxAgeSeconds > 1_800
  ) {
    throw new Error('Roster evidence max age must be between 300 and 1800 seconds.')
  }
  const catalogRoles = validateCatalog({
    catalog,
    catalogBinding,
    expectedCatalogSha256,
  })
  exactKeys(
    snapshot,
    ['authority', 'capturedAt', 'catalogSha256', 'roles', 'schema'],
    'Authoritative roster snapshot',
  )
  if (snapshot.catalogSha256 !== expectedCatalogSha256) {
    throw new Error('Authoritative roster snapshot catalog SHA-256 differs.')
  }
  requireFresh({
    value: snapshot.capturedAt,
    nowSeconds,
    maxAgeSeconds,
    label: 'Authoritative roster snapshot',
  })
  if (!Array.isArray(snapshot.roles)) {
    throw new Error('Authoritative roster snapshot roles must be an array.')
  }
  const catalogIds = [...catalogRoles.keys()]
  const snapshotIds = snapshot.roles.map((role) => role?.id)
  if (!isDeepStrictEqual(snapshotIds, catalogIds)) {
    throw new Error(
      'Authoritative roster snapshot must contain the exact catalog role order.',
    )
  }
  objectValue(roleEvidence, 'Roster evidence records')
  if (!isDeepStrictEqual(Object.keys(roleEvidence).sort(), [...catalogIds].sort())) {
    throw new Error('Roster evidence must contain the exact catalog role set.')
  }

  const measured = validateCurrentMacReceipt({
    currentMacReceipt,
    currentMacReceiptBinding,
    nowSeconds,
    maxAgeSeconds,
  })
  const currentRoles = []
  for (const role of snapshot.roles) {
    if (!dispositions.has(role.disposition)) {
      throw new Error(`Authoritative roster role ${role.id} disposition is invalid.`)
    }
    const catalogRole = catalogRoles.get(role.id)
    if (role.observedAt > snapshot.capturedAt) {
      throw new Error(
        `Authoritative roster role ${role.id} was observed after capture.`,
      )
    }
    validateRoleEvidence({
      role,
      catalogRole,
      evidence: roleEvidence[role.id],
      nowSeconds,
      maxAgeSeconds,
    })
    if (role.disposition === 'install') {
      if (
        role.target?.platform !== catalogRole.platform
        || role.target?.arch !== catalogRole.arch
      ) {
        throw new Error(
          `Install roster role ${role.id} target differs from its catalog capability.`,
        )
      }
    }
    if (role.disposition === 'excluded-current-mac') {
      currentRoles.push(role)
    }
  }
  if (
    currentRoles.length !== 1
    || currentRoles[0].machineIdentitySha256
      !== measured.machineIdentitySha256
    || roleEvidence[currentRoles[0].id].machineIdentitySha256
      !== measured.machineIdentitySha256
  ) {
    throw new Error(
      'Authoritative roster current Mac differs from the measured receipt.',
    )
  }
  return {
    catalogRoles,
    currentMacRole: currentRoles[0],
  }
}
