import { spawnSync } from 'node:child_process'
import { lstatSync, readFileSync, realpathSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import {
  readWorkspaceVersionTag,
  semverFromTag,
  sha256FileSync,
} from './local-release-lib.mjs'

const scriptsDir = dirname(fileURLToPath(import.meta.url))
const defaultCandidateRoot = resolve(scriptsDir, '..')
const fipsPackageNames = ['fips-core', 'fips-endpoint', 'fips-identity']

function requireRegularFile(path, label) {
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file.`)
  }
}

function captureRequired(command, args, { cwd, env, label }) {
  const result = spawnSync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    stdio: 'pipe',
  })
  if (result.status !== 0) {
    const stderr = String(result.stderr ?? '').trim()
    throw new Error(
      stderr ||
        result.error?.message ||
        `${label} failed with status ${result.status ?? 'unknown'}.`,
    )
  }
  const output = String(result.stdout ?? '').trim()
  if (!output) {
    throw new Error(`${label} produced no output.`)
  }
  return output
}

function requireExactFields(receipt, expected, label) {
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    throw new Error(`${label} is missing.`)
  }
  for (const [field, value] of Object.entries(expected)) {
    if (receipt[field] !== value) {
      throw new Error(`${label} ${field} differs from the exact candidate.`)
    }
  }
}

function exactCleanGitCheckout({
  root,
  env,
  label,
  expectedCommit = '',
  expectedTree = '',
}) {
  const commit = captureRequired('git', ['rev-parse', 'HEAD'], {
    cwd: root,
    env,
    label: `${label} commit`,
  })
  const tree = captureRequired('git', ['rev-parse', 'HEAD^{tree}'], {
    cwd: root,
    env,
    label: `${label} tree`,
  })
  const status = spawnSync(
    'git',
    ['status', '--porcelain=v1', '--untracked-files=all'],
    {
      cwd: root,
      env,
      encoding: 'utf8',
      stdio: 'pipe',
    },
  )
  if (
    status.status !== 0 ||
    String(status.stdout ?? '').trim() ||
    (expectedCommit && commit !== expectedCommit) ||
    (expectedTree && tree !== expectedTree)
  ) {
    throw new Error(
      `${label} checkout is dirty or differs from the exact candidate.`,
    )
  }
  return { commit, tree }
}

export function exactFipsPublicationCandidate({
  env,
  candidateRoot = defaultCandidateRoot,
  label = 'Release publication',
}) {
  const exactCandidateRoot = realpathSync(candidateRoot)
  const commandEnv = { ...process.env, ...env }
  const configuredFipsRoot = String(env?.NVPN_FIPS_REPO_PATH ?? '').trim()
  if (!configuredFipsRoot) {
    throw new Error(`${label} requires the exact NVPN_FIPS_REPO_PATH.`)
  }
  const fipsRoot = realpathSync(resolve(exactCandidateRoot, configuredFipsRoot))
  const expectedFipsGitSha = String(
    env?.NVPN_EXPECTED_FIPS_GIT_SHA ?? '',
  ).trim()
  if (!/^[0-9a-f]{40}$/.test(expectedFipsGitSha)) {
    throw new Error(
      `${label} requires an exact lowercase NVPN_EXPECTED_FIPS_GIT_SHA.`,
    )
  }
  const fipsGit = exactCleanGitCheckout({
    root: fipsRoot,
    env: commandEnv,
    label: `${label} FIPS`,
    expectedCommit: expectedFipsGitSha,
  })

  const lockVerifierPath = join(
    exactCandidateRoot,
    'scripts',
    'verify-cargo-path-patch-lock.py',
  )
  requireRegularFile(lockVerifierPath, `${label} exact FIPS lock verifier`)
  const specifications = captureRequired(
    'python3',
    [lockVerifierPath, '--manifest-specs', fipsRoot],
    {
      cwd: exactCandidateRoot,
      env: commandEnv,
      label: `${label} exact FIPS package specifications`,
    },
  )
    .split(/\r?\n/)
    .filter(Boolean)
  const packageVersions = new Map()
  for (const specification of specifications) {
    const separator = specification.indexOf('=')
    const name = specification.slice(0, separator)
    const version = specification.slice(separator + 1)
    if (
      separator <= 0 ||
      !/^[0-9A-Za-z_.+-]+$/.test(name) ||
      !/^[0-9A-Za-z_.+-]+$/.test(version) ||
      packageVersions.has(name)
    ) {
      throw new Error(`${label} exact FIPS package specifications are invalid.`)
    }
    packageVersions.set(name, version)
  }
  if (
    packageVersions.size !== fipsPackageNames.length ||
    fipsPackageNames.some((name) => !packageVersions.has(name))
  ) {
    throw new Error(
      `${label} exact FIPS package set differs from the candidate.`,
    )
  }
  exactCleanGitCheckout({
    root: fipsRoot,
    env: commandEnv,
    label: `${label} FIPS`,
    expectedCommit: fipsGit.commit,
    expectedTree: fipsGit.tree,
  })

  return {
    fipsGitSha: fipsGit.commit,
    fipsGitTree: fipsGit.tree,
    fipsVersion: packageVersions.get('fips-core'),
    fipsSpecifications: fipsPackageNames.map(
      (name) => `${name}=${packageVersions.get(name)}`,
    ),
    fipsPatchedLockPackages: Object.fromEntries(
      fipsPackageNames.map((name) => [name, packageVersions.get(name)]),
    ),
    lockVerifierPath,
  }
}

export function validateWindowsPublicationFipsReceipts({
  artifactReceipt,
  installerReceipt,
  expectedFips,
}) {
  const expected = {
    fipsGitSha: expectedFips?.fipsGitSha,
    fipsGitTree: expectedFips?.fipsGitTree,
    fipsVersion: expectedFips?.fipsVersion,
  }
  if (
    !/^[0-9a-f]{40}$/.test(String(expected.fipsGitSha ?? '')) ||
    !/^[0-9a-f]{40}$/.test(String(expected.fipsGitTree ?? '')) ||
    !/^[0-9]+\.[0-9]+\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?$/.test(
      String(expected.fipsVersion ?? ''),
    )
  ) {
    throw new Error(
      'Windows publication exact candidate FIPS identity is invalid.',
    )
  }
  requireExactFields(
    artifactReceipt,
    expected,
    'Windows exact-artifact gate receipt',
  )
  requireExactFields(
    installerReceipt,
    expected,
    'Windows exact installer gate receipt',
  )
  return expected
}

export function linuxPublicationVerificationPlan({
  env,
  tag,
  candidateCommit,
  candidateTree,
  gateReceipt,
  packageInstallReceipt,
  bundlePath,
  bundleReceiptPath,
  bundleReceiptSha256,
  candidateRoot = defaultCandidateRoot,
  hostPlatform = process.platform,
  hostArch = process.arch,
}) {
  const builderMode = String(env?.NVPN_HOST_LINUX_VM_BUILDER_MODE ?? '').trim()
  if (!builderMode) {
    throw new Error(
      'Linux publication requires an explicit builder mode via NVPN_HOST_LINUX_VM_BUILDER_MODE.',
    )
  }
  if (!['local-docker', 'remote-native'].includes(builderMode)) {
    throw new Error(
      `Linux publication builder mode is unsupported: ${builderMode}`,
    )
  }
  if (
    builderMode === 'local-docker' &&
    hostPlatform === 'darwin' &&
    hostArch === 'arm64'
  ) {
    throw new Error(
      'Darwin arm64 Linux publication requires remote-native builder mode; local QEMU artifacts are not accepted.',
    )
  }
  if (
    builderMode === 'local-docker' &&
    (hostPlatform !== 'darwin' || hostArch !== 'x64')
  ) {
    throw new Error(
      'local-docker Linux publication requires a native x86_64 Darwin host.',
    )
  }
  if (
    builderMode === 'remote-native' &&
    !String(env?.NVPN_HOST_LINUX_VM_NATIVE_BUILDER_HOST ?? '').trim()
  ) {
    throw new Error(
      'remote-native Linux publication requires an explicit native builder host.',
    )
  }

  const exactCandidateRoot = realpathSync(candidateRoot)
  const commandEnv = { ...process.env, ...env }
  const candidateGit = exactCleanGitCheckout({
    root: exactCandidateRoot,
    env: commandEnv,
    label: 'Linux publication worktree',
    expectedCommit: candidateCommit,
    expectedTree: candidateTree,
  })
  const actualCommit = candidateGit.commit
  const actualTree = candidateGit.tree

  const rootManifestPath = join(exactCandidateRoot, 'Cargo.toml')
  requireRegularFile(rootManifestPath, 'Linux publication workspace manifest')
  const workspaceVersion = semverFromTag(
    readWorkspaceVersionTag(readFileSync(rootManifestPath, 'utf8')),
  )
  const appVersion = semverFromTag(tag)
  if (workspaceVersion !== appVersion) {
    throw new Error(
      'Linux publication tag differs from the exact workspace version.',
    )
  }

  const fips = exactFipsPublicationCandidate({
    env,
    candidateRoot: exactCandidateRoot,
    label: 'Linux publication',
  })
  const rootCargoLockPath = join(exactCandidateRoot, 'Cargo.lock')
  const linuxCargoLockPath = join(exactCandidateRoot, 'linux', 'Cargo.lock')
  requireRegularFile(rootCargoLockPath, 'Linux publication root Cargo lock')
  requireRegularFile(linuxCargoLockPath, 'Linux publication desktop Cargo lock')
  const rootCargoLockSha256 = sha256FileSync(rootCargoLockPath)
  const linuxCargoLockSha256 = sha256FileSync(linuxCargoLockPath)
  const realizedLock = (path, label) =>
    captureRequired(
      'python3',
      [
        fips.lockVerifierPath,
        '--expected-sha256',
        path,
        ...fips.fipsSpecifications,
      ],
      {
        cwd: exactCandidateRoot,
        env: commandEnv,
        label,
      },
    )
  const rootRealizedCargoLockSha256 = realizedLock(
    rootCargoLockPath,
    'Linux publication realized root Cargo lock',
  )
  const linuxRealizedCargoLockSha256 = realizedLock(
    linuxCargoLockPath,
    'Linux publication realized desktop Cargo lock',
  )
  for (const [label, value] of Object.entries({
    rootCargoLockSha256,
    rootRealizedCargoLockSha256,
    linuxCargoLockSha256,
    linuxRealizedCargoLockSha256,
  })) {
    if (!/^[0-9a-f]{64}$/.test(value)) {
      throw new Error(`Linux publication ${label} is invalid.`)
    }
  }

  const rustToolchain = String(
    env?.NVPN_HOST_LINUX_VM_RUST_TOOLCHAIN || '1.95.0',
  ).trim()
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(rustToolchain)) {
    throw new Error(
      'Linux publication Rust toolchain must be an exact stable version.',
    )
  }
  const dockerfilePath = join(exactCandidateRoot, 'Dockerfile.linux-vm-gate')
  const containerPayloadPath = join(
    exactCandidateRoot,
    'scripts',
    'build-host-linux-vm-bundle-in-container.sh',
  )
  requireRegularFile(dockerfilePath, 'Linux publication Dockerfile')
  requireRegularFile(
    containerPayloadPath,
    'Linux publication container payload',
  )
  const dockerfileSha256 = sha256FileSync(dockerfilePath)
  const containerPayloadSha256 = sha256FileSync(containerPayloadPath)
  const sourceDateEpoch = Number(
    captureRequired('git', ['log', '-1', '--format=%ct', actualCommit], {
      cwd: exactCandidateRoot,
      env: commandEnv,
      label: 'Linux publication source date epoch',
    }),
  )
  if (!Number.isSafeInteger(sourceDateEpoch) || sourceDateEpoch <= 0) {
    throw new Error(
      'Linux publication candidate has an invalid source date epoch.',
    )
  }

  const target = 'x86_64-unknown-linux-gnu'
  const expectedBuilder =
    builderMode === 'remote-native'
      ? {
          builtOnHostMac: false,
          builtOnRemoteVm: true,
          builderHostOs: 'Linux',
          builderHostArchitecture: 'x86_64',
        }
      : {
          builtOnHostMac: true,
          builtOnRemoteVm: false,
          builderHostOs: 'Darwin',
          builderHostArchitecture: 'x86_64',
        }
  requireExactFields(
    gateReceipt,
    {
      schema: 2,
      builderMode,
      ...expectedBuilder,
      appGitSha: actualCommit,
      appGitTree: actualTree,
      appVersion,
      fipsGitSha: fips.fipsGitSha,
      fipsGitTree: fips.fipsGitTree,
      fipsVersion: fips.fipsVersion,
      rootCargoLockSha256,
      rootRealizedCargoLockSha256,
      linuxCargoLockSha256,
      linuxRealizedCargoLockSha256,
      target,
      dockerPlatform: 'linux/amd64',
      containerBase: 'ubuntu:24.04',
      dockerfileSha256,
      containerPayloadSha256,
      sourceDateEpoch,
    },
    'Linux exact-artifact gate receipt',
  )
  const receiptFipsPackages = gateReceipt.fipsPatchedLockPackages
  if (
    !receiptFipsPackages ||
    typeof receiptFipsPackages !== 'object' ||
    Array.isArray(receiptFipsPackages) ||
    Object.keys(receiptFipsPackages).length !== fipsPackageNames.length ||
    fipsPackageNames.some(
      (name) =>
        receiptFipsPackages[name] !== fips.fipsPatchedLockPackages[name],
    )
  ) {
    throw new Error(
      'Linux exact-artifact gate receipt fipsPatchedLockPackages differs from the exact candidate.',
    )
  }
  if (
    !/^sha256:[0-9a-f]{64}$/.test(String(gateReceipt.containerImageId ?? '')) ||
    !String(gateReceipt.rustcVersion ?? '').startsWith(
      `rustc ${rustToolchain} `,
    ) ||
    !String(gateReceipt.cargoVersion ?? '').startsWith(
      `cargo ${rustToolchain} `,
    )
  ) {
    throw new Error(
      'Linux exact-artifact gate receipt has the wrong container or Rust toolchain.',
    )
  }

  const exactBundleReceiptSha256 = String(bundleReceiptSha256 ?? '').trim()
  if (!/^[0-9a-f]{64}$/.test(exactBundleReceiptSha256)) {
    throw new Error('Linux exact host-bundle receipt SHA-256 is invalid.')
  }
  requireExactFields(
    packageInstallReceipt,
    {
      schema: 2,
      artifactType: 'exact Debian package installed on Ubuntu VM',
      appGitSha: actualCommit,
      appGitTree: actualTree,
      fipsGitSha: fips.fipsGitSha,
      fipsGitTree: fips.fipsGitTree,
      appVersion,
      builderMode,
      ...expectedBuilder,
      containerImageId: gateReceipt.containerImageId,
      dockerfileSha256,
      containerPayloadSha256,
      bundleReceiptSha256: exactBundleReceiptSha256,
    },
    'Linux exact Debian package install receipt',
  )

  const exactBundlePath = realpathSync(bundlePath)
  const exactBundleReceiptPath = realpathSync(bundleReceiptPath)
  if (
    dirname(exactBundleReceiptPath) !== exactBundlePath ||
    basename(exactBundleReceiptPath) !== 'receipt.json'
  ) {
    throw new Error(
      'Linux exact host-bundle receipt is not inside the exact bundle.',
    )
  }
  const verifierPath = join(
    exactCandidateRoot,
    'scripts',
    'verify-host-linux-vm-bundle.py',
  )
  requireRegularFile(verifierPath, 'Linux exact host-bundle verifier')
  exactCleanGitCheckout({
    root: exactCandidateRoot,
    env: commandEnv,
    label: 'Linux publication worktree',
    expectedCommit: actualCommit,
    expectedTree: actualTree,
  })
  return {
    candidateRoot: exactCandidateRoot,
    verifierPath,
    verifierArgs: [
      exactBundlePath,
      exactBundleReceiptPath,
      actualCommit,
      actualTree,
      appVersion,
      fips.fipsGitSha,
      fips.fipsGitTree,
      fips.fipsVersion,
      rootCargoLockSha256,
      rootRealizedCargoLockSha256,
      linuxCargoLockSha256,
      linuxRealizedCargoLockSha256,
      target,
      builderMode,
      rustToolchain,
      dockerfileSha256,
      containerPayloadSha256,
      ...fips.fipsSpecifications,
    ],
  }
}
