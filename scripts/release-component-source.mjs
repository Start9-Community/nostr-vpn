import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'

const platforms = ['android', 'ios', 'linux', 'macos', 'windows']
const sharedRoots = ['.cargo', 'assets', 'crates', 'docker', 'src', 'tools']
const sharedFiles = [
  'Cargo.lock', 'Cargo.toml', 'build.rs', 'rust-toolchain',
  'rust-toolchain.toml', 'scripts/sync-versions.mjs',
]
const harnessOnlyPaths = new Set([
  'Dockerfile.mobile-wireguard-exit-e2e',
  'Dockerfile.mobile-wireguard-exit-e2e.dockerignore',
  'crates/nostr-vpn-app-core/src/mobile_tunnel/tests_core.rs',
  'crates/nostr-vpn-core/examples/desktop_manual_join_e2e_fixture.rs',
  'scripts/appstore-draft',
  'scripts/appstore_draft_metadata.py',
  'scripts/test_appstore_draft_metadata.py',
  'scripts/e2e-web-startos-manual-join-docker.sh',
  'scripts/capture-mobile-ios-underlay-output.py',
  'scripts/desktop-manual-join-ax.swift',
  'scripts/desktop_mobile_manual_join_receipt.py',
  'scripts/desktop-mobile-manual-join-atspi.py',
  'scripts/desktop-mobile-manual-join-windows-ui.ps1',
  'scripts/e2e-macos-release-network.sh',
  'scripts/e2e-macos-service-toggle.sh',
  'scripts/e2e-macos-service.sh',
  'scripts/ios_xctestrun.py',
  'scripts/lib-ubuntu-vm-imported-release.sh',
  'scripts/lib-mobile-android-release-gate.sh',
  'scripts/lib-mobile-android-underlay.sh',
  'scripts/lib-mobile-ios-release-network.sh',
  'scripts/lib-mobile-release-artifact-reuse.sh',
  'scripts/lib-mobile-release-join-artifacts.sh',
  'scripts/lib-mobile-release-join-ui.sh',
  'scripts/lib-mobile-wireguard-fixture.sh',
  'scripts/linux-release-mobile-join-remote.sh',
  'scripts/mobile-android-smoke.sh',
  'scripts/mobile_release_artifact_receipt.py',
  'scripts/mobile-underlay-local-timestamp.py',
  'scripts/mobile-release-join-ui-query.py',
  'scripts/mobile-release-join-e2e.sh',
  'scripts/mobile-wireguard-exit-e2e.sh',
  'scripts/mobile-wireguard-exit-remote-native.sh',
  'scripts/mobile-wireguard-exit-server.sh',
  'scripts/mobile-wireguard-tls-sni-count.py',
  'scripts/macos-release-mobile-join-remote.sh',
  'scripts/macos-vm-desktop-wireguard-exit-e2e.sh',
  'scripts/macos-vm-release-mobile-join-e2e.sh',
  'scripts/macos_release_join_artifact.py',
  'scripts/release-network-evidence.py',
  'scripts/ubuntu-vm-release-mobile-join-e2e.sh',
  'scripts/validate-mobile-underlay-continuity.py',
  'scripts/windows-release-mobile-join-remote.ps1',
  'scripts/windows-vm-release-mobile-join-e2e.sh',
])
const buildScripts = {
  android: [/prepare-android-release-from-bundle/],
  ios: [
    /scripts\/ios-build$/,
    /scripts\/ios_frozen_archive\.py$/,
    /scripts\/ios_frozen_gate\.py$/,
    /scripts\/ios-profiles$/,
    /scripts\/ios_profile_certificate\.py$/,
    /lib-mobile-ios-release-artifact/,
  ],
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
  if (harnessOnlyPaths.has(path)) return false
  const root = path.split('/')[0]
  if (sharedFiles.includes(path) || sharedRoots.includes(root)) return true
  if (platforms.includes(root)) {
    return root === platform && !/\/(?:UI)?Tests?\//.test(`/${path}/`)
  }
  if (path.startsWith('scripts/')) {
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
