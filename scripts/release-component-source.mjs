import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'

const platforms = ['android', 'ios', 'linux', 'macos', 'windows']
const sharedRoots = ['.cargo', 'assets', 'crates', 'docker', 'src', 'tools']
const sharedFiles = [
  'Cargo.lock', 'Cargo.toml', 'build.rs', 'rust-toolchain',
  'rust-toolchain.toml', 'scripts/sync-versions.mjs',
]
const harnessOnlyScripts = new Set([
  'scripts/lib-mobile-ios-release-network.sh',
])
const buildScripts = {
  android: [/prepare-android-release-from-bundle/, /lib-mobile-android-release-gate/],
  ios: [/scripts\/ios-build$/, /lib-mobile-ios-release-artifact/],
  linux: [/build-host-linux-/, /build-nvpn-linux-musl$/, /host-linux-native-builder-/, /host_linux_package_content/, /lib-host-linux-/],
  macos: [/build-.*macos/, /scripts\/macos-build$/, /lib-macos-release-app-ownership/, /verify-macos-release-publication-artifacts/],
  windows: [/windows-build\.ps1$/, /windows-release-publication-proof/],
}

function git(root, args, label) {
  const result = spawnSync('git', args, {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  })
  if (result.status !== 0) {
    throw new Error(`${label}: ${String(result.stderr || result.error?.message || 'git failed').trim()}`)
  }
  return String(result.stdout ?? '').trim()
}

function isProductInput(path, platform) {
  const root = path.split('/')[0]
  if (sharedFiles.includes(path) || sharedRoots.includes(root)) return true
  if (platforms.includes(root)) {
    return root === platform && !/\/(?:UI)?Tests?\//.test(`/${path}/`)
  }
  if (path.startsWith('scripts/')) {
    if (harnessOnlyScripts.has(path)) return false
    for (const [owner, patterns] of Object.entries(buildScripts)) {
      if (patterns.some((pattern) => pattern.test(path))) return owner === platform
    }
    if (/^scripts\/test-|release-gate|release-artifact-provenance|release-component-source|local-release|publication|fleet-release/.test(path)) {
      return false
    }
    return true
  }
  return !(
    path.startsWith('.github/')
    || path.startsWith('docs/')
    || ['AGENTS.md', 'CHANGELOG.md', 'README.md'].includes(path)
  )
}

function requireTree(root, commit, tree, label) {
  if (!/^[0-9a-f]{40}$/.test(commit) || !/^[0-9a-f]{40}$/.test(tree)) {
    throw new Error(`${label} has an invalid commit/tree.`)
  }
  if (git(root, ['rev-parse', `${commit}^{tree}`], `${label} lookup`) !== tree) {
    throw new Error(`${label} recorded tree is not the commit tree.`)
  }
}

export function proveUnchangedPlatformInputs({
  candidateRoot, platform, receiptCommit, receiptTree,
  candidateCommit, candidateTree,
}) {
  if (!platforms.includes(platform)) {
    throw new Error(`Unsupported component-proof platform: ${platform}`)
  }
  requireTree(candidateRoot, receiptCommit, receiptTree, 'Receipt source')
  requireTree(candidateRoot, candidateCommit, candidateTree, 'Candidate source')
  if (spawnSync('git', ['merge-base', '--is-ancestor', receiptCommit, candidateCommit], {
    cwd: candidateRoot,
    stdio: 'ignore',
  }).status !== 0) {
    throw new Error('Receipt source is not an ancestor of the release candidate.')
  }
  const changedPaths = git(candidateRoot, [
    'diff', '--name-only', '--no-renames', '--diff-filter=ACDMRTUXB', '-z',
    receiptCommit, candidateCommit, '--',
  ], 'Receipt source diff').split('\0').filter(Boolean).sort()
  const relevant = changedPaths.find((path) => isProductInput(path, platform))
  if (relevant) {
    throw new Error(`${platform} receipt cannot be retained: changed product/build input ${relevant}.`)
  }
  return {
    policy: 'unchanged-platform-product-inputs-v1',
    platform,
    receipt_app_git_sha: receiptCommit,
    receipt_app_git_tree: receiptTree,
    candidate_app_git_sha: candidateCommit,
    candidate_app_git_tree: candidateTree,
    changed_paths_sha256: createHash('sha256')
      .update(`${changedPaths.join('\0')}\0`).digest('hex'),
  }
}
