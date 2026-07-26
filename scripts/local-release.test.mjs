import test from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

import {
  androidReleaseAssetName,
  androidVersionCode,
  autoDetectWindowsVmName,
  buildReleaseManifestFiles,
  buildReleaseManifest,
  bumpAndroidGradleVersion,
  bumpCargoPackageVersion,
  bumpPbxprojMarketingVersion,
  bumpStartosSourceVersion,
  deterministicBuildEnv,
  describeAsset,
  extractChangelogSection,
  linuxReleaseTargetsForDockerPlatform,
  parseEnvFile,
  readWorkspaceVersionTag,
  renderReleaseNotes,
  semverFromTag,
  shouldBlockLocalLinuxAmd64Qemu,
  splitCsv,
  validatePromotableReleaseManifest,
  validateCleanReleaseSource,
  validateReleaseAssetSet,
  validateStagedReleaseTree,
  validateZapstoreApkMetadata,
  validateZapstoreRelayPublication,
  windowsSshTransportArgs,
  zapstorePublicationPrerequisites,
  zapstorePublicationRequired,
} from './local-release-lib.mjs'

test('parseEnvFile reads basic dotenv syntax', () => {
  const parsed = parseEnvFile(`
# comment
NVPN_RELEASE_TREE=releases/nostr-vpn
NVPN_WINDOWS_VM_NAME="Windows 11"
NVPN_NOTE='line one'
INVALID KEY=nope
`)

  assert.deepEqual(parsed, {
    NVPN_RELEASE_TREE: 'releases/nostr-vpn',
    NVPN_WINDOWS_VM_NAME: 'Windows 11',
    NVPN_NOTE: 'line one',
  })
})

test('splitCsv trims and drops empties', () => {
  assert.deepEqual(splitCsv('verify, windows,android ,, macos'), [
    'verify',
    'windows',
    'android',
    'macos',
  ])
})

test('release source provenance rejects dirty or mismatched tagged candidates', () => {
  const commit = 'a'.repeat(40)
  assert.equal(
    validateCleanReleaseSource({
      status: '',
      headCommit: commit,
      taggedCommit: commit,
      tag: 'v4.1.4+4001006',
    }),
    commit,
  )
  assert.throws(
    () => validateCleanReleaseSource({
      status: ' M ios/Sources/AppModel.swift',
      headCommit: commit,
    }),
    /source is dirty/i,
  )
  assert.throws(
    () => validateCleanReleaseSource({
      status: '',
      headCommit: commit,
      taggedCommit: 'b'.repeat(40),
      tag: 'v4.1.4+4001006',
    }),
    /points to .* not candidate HEAD/i,
  )
})

test('Zapstore publication can be made mandatory by CLI or release environment', () => {
  assert.equal(zapstorePublicationRequired({ cliRequired: true }), true)
  assert.equal(
    zapstorePublicationRequired({ envValue: 'true' }),
    true,
  )
  assert.equal(
    zapstorePublicationRequired({ envValue: '0' }),
    false,
  )
})

test('required Zapstore mode rejects every missing publication prerequisite', () => {
  const complete = {
    apk: true,
    zsp: true,
    nak: true,
    signing: true,
    config: true,
    publisher: true,
    relays: true,
  }
  assert.deepEqual(
    zapstorePublicationPrerequisites(complete, { required: true }),
    { available: true, missing: [] },
  )

  for (const prerequisite of Object.keys(complete)) {
    assert.throws(
      () =>
        zapstorePublicationPrerequisites(
          { ...complete, [prerequisite]: false },
          { required: true },
        ),
      new RegExp(`Required Zapstore publication unavailable:.*${prerequisite}`, 'i'),
    )
  }

  const optional = zapstorePublicationPrerequisites(
    { ...complete, signing: false },
  )
  assert.equal(optional.available, false)
  assert.match(optional.missing[0], /signing/i)
})

test('required Zapstore APK metadata proves version, package, ABI, and Android signing', () => {
  assert.deepEqual(
    validateZapstoreApkMetadata(
      {
        package_id: 'fi.siriusbusiness.nvpn',
        version_name: '4.1.4',
        version_code: 4_010_401,
        sha256: 'c'.repeat(64),
        architectures: ['arm64-v8a'],
        cert_fingerprint: 'abcdef',
      },
      {
        expectedVersion: '4.1.4',
        expectedVersionCode: 4_010_401,
        expectedPackageId: 'fi.siriusbusiness.nvpn',
      },
    ),
    {
      packageId: 'fi.siriusbusiness.nvpn',
      versionName: '4.1.4',
      versionCode: 4_010_401,
      certificateFingerprint: 'abcdef',
      sha256: 'c'.repeat(64),
    },
  )

  for (const [field, value, message] of [
    ['version_name', '4.1.3', /version/],
    ['version_code', 4_010_400, /version code/],
    ['package_id', 'com.example.wrong', /package/],
    ['architectures', ['x86_64'], /arm64-v8a/],
    ['cert_fingerprint', '', /signed/],
    ['sha256', 'not-a-hash', /SHA-256/],
  ]) {
    const metadata = {
      package_id: 'fi.siriusbusiness.nvpn',
      version_name: '4.1.4',
      version_code: 4_010_401,
      sha256: 'c'.repeat(64),
      architectures: ['arm64-v8a'],
      cert_fingerprint: 'abcdef',
      [field]: value,
    }
    assert.throws(
      () =>
        validateZapstoreApkMetadata(metadata, {
          expectedVersion: '4.1.4',
          expectedVersionCode: 4_010_401,
          expectedPackageId: 'fi.siriusbusiness.nvpn',
        }),
      message,
    )
  }
})

test('required Zapstore verification accepts only exact signed relay events', () => {
  const pubkey = 'a'.repeat(64)
  const asset = {
    kind: 3063,
    id: 'b'.repeat(64),
    pubkey,
    tags: [
      ['i', 'fi.siriusbusiness.nvpn'],
      ['version', '4.1.4'],
      ['version_code', '4010401'],
      ['x', 'c'.repeat(64)],
      ['apk_certificate_hash', 'abcdef'],
      ['f', 'android-arm64-v8a'],
      ['url', 'https://cdn.example/app.apk'],
    ],
  }
  const release = {
    kind: 30063,
    id: 'd'.repeat(64),
    pubkey,
    tags: [
      ['i', 'fi.siriusbusiness.nvpn'],
      ['version', '4.1.4'],
      ['d', 'fi.siriusbusiness.nvpn@4.1.4'],
      ['c', 'main'],
      ['f', 'android-arm64-v8a'],
      ['e', asset.id],
    ],
  }
  const app = {
    kind: 32267,
    id: 'e'.repeat(64),
    pubkey,
    tags: [
      ['d', 'fi.siriusbusiness.nvpn'],
      ['f', 'android-arm64-v8a'],
    ],
  }

  assert.deepEqual(
    validateZapstoreRelayPublication({
      appEvents: [app],
      releaseEvents: [release],
      assetEvents: [asset],
      expected: {
        pubkey,
        packageId: 'fi.siriusbusiness.nvpn',
        versionName: '4.1.4',
        versionCode: 4_010_401,
        sha256: 'c'.repeat(64),
        certificateFingerprint: 'abcdef',
      },
    }),
    { app, release, asset },
  )

  const wrongAsset = structuredClone(asset)
  wrongAsset.tags = wrongAsset.tags.map((tag) =>
    tag[0] === 'x' ? ['x', 'f'.repeat(64)] : tag
  )
  assert.throws(
    () =>
      validateZapstoreRelayPublication({
        appEvents: [app],
        releaseEvents: [release],
        assetEvents: [wrongAsset],
        expected: {
          pubkey,
          packageId: 'fi.siriusbusiness.nvpn',
          versionName: '4.1.4',
          versionCode: 4_010_401,
          sha256: 'c'.repeat(64),
          certificateFingerprint: 'abcdef',
        },
      }),
    /software asset/,
  )
})

test('local release CLI and environment enforce required Zapstore mode', () => {
  const script = join(process.cwd(), 'scripts/local-release.mjs')
  const cliConflict = spawnSync(
    process.execPath,
    [script, '--dry-run', '--require-zapstore', '--skip-zapstore'],
    { encoding: 'utf8' },
  )
  assert.equal(cliConflict.status, 1)
  assert.match(cliConflict.stderr, /require-zapstore conflicts with --skip-zapstore/)

  const envConflict = spawnSync(
    process.execPath,
    [script, '--dry-run', '--skip-zapstore'],
    {
      encoding: 'utf8',
      env: { ...process.env, NVPN_RELEASE_REQUIRE_ZAPSTORE: 'true' },
    },
  )
  assert.equal(envConflict.status, 1)
  assert.match(envConflict.stderr, /require-zapstore conflicts with --skip-zapstore/)

  const nonFinal = spawnSync(
    process.execPath,
    [script, '--require-zapstore'],
    { encoding: 'utf8' },
  )
  assert.equal(nonFinal.status, 1)
  assert.match(nonFinal.stderr, /needs --final or --promote-draft/)
})

test('final publication cannot bypass complete platform artifacts', () => {
  const localRelease = readFileSync(join(process.cwd(), 'scripts/local-release.mjs'), 'utf8')

  assert.match(
    localRelease,
    /cliRequired:\s*options\.requireZapstore\s*\|\|\s*finalPublication/,
  )
  assert.match(
    localRelease,
    /final release cannot be published with partial platform artifacts/,
  )
  assert.match(
    localRelease,
    /final release must run every platform step; --only and --skip are staging-only/,
  )
})

test('final publication preflights tools and Zapstore identity before the release gate', () => {
  const localRelease = readFileSync(join(process.cwd(), 'scripts/local-release.mjs'), 'utf8')
  const mainStart = localRelease.indexOf('function main()')
  const preflightCall = localRelease.indexOf(
    'preflightRequiredZapstorePublication({',
    mainStart,
  )
  const buildSteps = localRelease.indexOf('const steps = [', mainStart)

  assert.ok(preflightCall > mainStart)
  assert.ok(preflightCall < buildSteps)
  assert.match(
    localRelease,
    /options\.publish\s*&&\s*!options\.dryRun\s*&&\s*!commandExists\('htree'\)/,
  )
  assert.match(
    localRelease,
    /zapstorePublicationPrerequisites\([\s\S]*?apk:\s*!requireApk\s*\|\|\s*existsSync\(apkPath\)/,
  )
  assert.match(localRelease, /run\('nak', \['decode', publisherNpub\]/)
})

test('release builds always include paid exit support', () => {
  for (const manifest of [
    'crates/nostr-vpn-core/Cargo.toml',
    'crates/nostr-vpn-cli/Cargo.toml',
    'crates/nostr-vpn-app-core/Cargo.toml',
  ]) {
    const contents = readFileSync(manifest, 'utf8')
    assert.match(contents, /default\s*=\s*\[[^\]]*"paid-exit"[^\]]*\]/)
  }

  const linuxBuilder = readFileSync('scripts/build-nvpn-linux-musl', 'utf8')
  assert.doesNotMatch(linuxBuilder, /NO_DEFAULT_FEATURES|--no-default-features/)
})

test('Linux musl builds extract only rustables instead of vendoring every dependency', () => {
  const linuxBuilder = readFileSync('scripts/build-nvpn-linux-musl', 'utf8')

  assert.doesNotMatch(linuxBuilder, /\bcargo\b[^\n]*\bvendor\b/)
  assert.match(linuxBuilder, /rustables-\$\{rustables_version\}\.crate/)
  assert.match(linuxBuilder, /tar -xzf "\$rustables_crate" -C vendor/)
})

test('deterministicBuildEnv fills stable defaults without clobbering explicit env', () => {
  assert.deepEqual(
    deterministicBuildEnv(
      { CARGO_INCREMENTAL: '1', TZ: 'Europe/Helsinki' },
      { sourceDateEpoch: 123 },
    ),
    {
      SOURCE_DATE_EPOCH: '123',
      CARGO_INCREMENTAL: '1',
      ZERO_AR_DATE: '1',
      LC_ALL: 'C',
      TZ: 'Europe/Helsinki',
    },
  )
})

test('deterministicBuildEnv rejects non-numeric source dates', () => {
  assert.throws(
    () => deterministicBuildEnv({}, { sourceDateEpoch: 'today' }),
    /SOURCE_DATE_EPOCH/,
  )
})

test('Windows release transport supports jump hosts and proxy commands', () => {
  assert.deepEqual(windowsSshTransportArgs({ NVPN_WINDOWS_SSH_JUMP: 'jump-host' }), [
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=10',
    '-J',
    'jump-host',
  ])
  assert.deepEqual(
    windowsSshTransportArgs({
      NVPN_WINDOWS_SSH_JUMP: 'ignored',
      NVPN_WINDOWS_SSH_PROXY_COMMAND: 'ssh gateway -W %h:%p',
    }),
    [
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=10',
      '-o',
      'ProxyCommand=ssh gateway -W %h:%p',
    ],
  )
})

test('readWorkspaceVersionTag reads the workspace package version', () => {
  const tag = readWorkspaceVersionTag(`
[workspace]
members = []

[workspace.package]
version = "0.2.27"
`)

  assert.equal(tag, 'v0.2.27')
})

test('buildReleaseManifest can mark htree draft releases', () => {
  const root = mkdtempSync(join(tmpdir(), 'nostr-vpn-manifest-draft-test-'))
  const asset = join(root, 'asset.tar.gz')
  writeFileSync(asset, 'asset')

  const manifest = buildReleaseManifest({
    tag: 'v1.2.3',
    commit: 'abc123',
    createdAt: 123,
    assetPaths: [asset],
    draft: true,
  })

  assert.equal(manifest.draft, true)
  assert.equal(manifest.prerelease, false)
})

test('linuxReleaseTargetsForDockerPlatform maps Docker platforms to release targets', () => {
  assert.deepEqual(linuxReleaseTargetsForDockerPlatform('linux/arm64'), {
    linuxArchSuffix: 'arm64',
    muslTriple: 'aarch64-unknown-linux-musl',
  })
  assert.deepEqual(linuxReleaseTargetsForDockerPlatform('linux/arm64/v8'), {
    linuxArchSuffix: 'arm64',
    muslTriple: 'aarch64-unknown-linux-musl',
  })
  assert.deepEqual(linuxReleaseTargetsForDockerPlatform('linux/amd64'), {
    linuxArchSuffix: 'x64',
    muslTriple: 'x86_64-unknown-linux-musl',
  })
  assert.throws(
    () => linuxReleaseTargetsForDockerPlatform('linux/arm/v7'),
    /Unsupported Linux Docker architecture/,
  )
})

test('shouldBlockLocalLinuxAmd64Qemu protects Apple Silicon Docker Desktop releases', () => {
  assert.equal(
    shouldBlockLocalLinuxAmd64Qemu({
      platform: 'linux/amd64',
      hostPlatform: 'darwin',
      hostArch: 'arm64',
    }),
    true,
  )
  assert.equal(
    shouldBlockLocalLinuxAmd64Qemu({
      platform: 'linux/amd64',
      hostPlatform: 'linux',
      hostArch: 'x64',
    }),
    false,
  )
  assert.equal(
    shouldBlockLocalLinuxAmd64Qemu({
      platform: 'linux/arm64',
      hostPlatform: 'darwin',
      hostArch: 'arm64',
    }),
    false,
  )
})

test('validateReleaseAssetSet rejects ARM64-only Linux desktop releases', () => {
  assert.throws(
    () =>
      validateReleaseAssetSet([
        'nostr-vpn-v0.3.23-linux-arm64.AppImage',
        'nostr-vpn-v0.3.23-linux-arm64.deb',
      ]),
    /no Linux x64 desktop artifacts/,
  )
  assert.doesNotThrow(() =>
    validateReleaseAssetSet([
      'nostr-vpn-v0.3.23-linux-x64.AppImage',
      'nostr-vpn-v0.3.23-linux-arm64.AppImage',
    ]),
  )
  assert.doesNotThrow(() =>
    validateReleaseAssetSet(['nostr-vpn-v0.3.23-linux-arm64.AppImage'], {
      allowLinuxArm64DesktopOnly: true,
    }),
  )
})

test('validateReleaseAssetSet rejects macOS app zip releases', () => {
  assert.throws(
    () => validateReleaseAssetSet(['nostr-vpn-v4.0.1-macos-arm64.zip']),
    /macOS \.zip app archive/,
  )
  assert.throws(
    () => validateReleaseAssetSet(['nostr-vpn-v4.0.1-macos-arm64.dmg']),
    /no macOS \.app\.tar\.gz updater archive/,
  )
  assert.doesNotThrow(() =>
    validateReleaseAssetSet([
      'nostr-vpn-v4.0.1-macos-arm64.app.tar.gz',
      'nostr-vpn-v4.0.1-macos-arm64.dmg',
    ]),
  )
})

test('validateReleaseAssetSet rejects unsigned Android artifacts', () => {
  assert.throws(
    () => validateReleaseAssetSet(['nostr-vpn-v4.0.1-android-arm64-unsigned.apk']),
    /unsigned Android artifacts/,
  )
})

test('validateReleaseAssetSet can require complete app release artifacts', () => {
  assert.throws(
    () =>
      validateReleaseAssetSet([
        'nostr-vpn-v4.0.1-macos-arm64.app.tar.gz',
        'nostr-vpn-v4.0.1-macos-arm64.dmg',
      ], { requireCompleteAppRelease: true }),
    /Linux x64 desktop package, Windows x64 installer, signed Android APK, StartOS x86_64 package, StartOS aarch64 package/,
  )

  assert.doesNotThrow(() =>
    validateReleaseAssetSet([
      'nostr-vpn-v4.0.1-android-arm64.aab',
      'nostr-vpn-v4.0.1-android-arm64.apk',
      'nostr-vpn-v4.0.1-linux-x64.deb',
      'nostr-vpn-v4.0.1-macos-arm64.app.tar.gz',
      'nostr-vpn-v4.0.1-macos-arm64.dmg',
      'nostr-vpn-v4.0.1-startos-aarch64.s9pk',
      'nostr-vpn-v4.0.1-startos-x86_64.s9pk',
      'nostr-vpn-v4.0.1-windows-x64-setup.exe',
    ], { requireCompleteAppRelease: true }),
  )
})

test('draft promotion rejects an incomplete cross-platform artifact set', () => {
  assert.throws(
    () =>
      validatePromotableReleaseManifest({
        assets: [
          { path: 'assets/nostr-vpn-v4.1.4-macos-arm64.app.tar.gz' },
          { path: 'assets/nostr-vpn-v4.1.4-macos-arm64.dmg' },
        ],
      }),
    /Linux x64 desktop package, Windows x64 installer, signed Android APK, StartOS x86_64 package, StartOS aarch64 package/,
  )

  assert.doesNotThrow(() =>
    validatePromotableReleaseManifest({
      assets: [
        { path: 'assets/nostr-vpn-v4.1.4-android-arm64.apk' },
        { path: 'assets/nostr-vpn-v4.1.4-linux-x64.deb' },
        { path: 'assets/nostr-vpn-v4.1.4-macos-arm64.app.tar.gz' },
        { path: 'assets/nostr-vpn-v4.1.4-macos-arm64.dmg' },
        { path: 'assets/nostr-vpn-v4.1.4-startos-aarch64.s9pk' },
        { path: 'assets/nostr-vpn-v4.1.4-startos-x86_64.s9pk' },
        { path: 'assets/nostr-vpn-v4.1.4-windows-x64-setup.exe' },
      ],
    }),
  )
})

test('draft candidates are complete before the final TestFlight upload', () => {
  const localRelease = readFileSync(
    join(process.cwd(), 'scripts/local-release.mjs'),
    'utf8',
  )
  assert.match(
    localRelease,
    /requireCompleteAppRelease:\s*!allowPartial\s*&&\s*!options\.dryRun/,
  )
  const stepsStart = localRelease.indexOf('const steps = [')
  const stageStart = localRelease.indexOf('stageRelease({', stepsStart)
  const steps = localRelease.slice(stepsStart, stageStart)
  assert.ok(steps.indexOf("['windows'") < steps.indexOf("['ios'"))
  assert.match(
    localRelease,
    /function buildIosArtifacts[\s\S]*NVPN_IOS_INTERNAL_ONLY:\s*'false'/,
  )
})

test('Linux desktop package bundles nvpn CLI helper', () => {
  const linuxCargo = readFileSync(join(process.cwd(), 'linux/Cargo.toml'), 'utf8')
  const localRelease = readFileSync(join(process.cwd(), 'scripts/local-release.mjs'), 'utf8')
  const githubRelease = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')

  assert.match(linuxCargo, /\["\.\.\/target\/release\/nvpn", "usr\/bin\/nvpn", "755"\]/)
  assert.match(localRelease, /cargo build --release --locked -p nvpn/)
  assert.match(githubRelease, /cargo build --release --locked -p nvpn/)
})

test('Linux release reclaims Docker smoke storage before host packaging', () => {
  const workflow = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')
  const verifyJobStart = workflow.indexOf('  verify:')
  const linuxJobStart = workflow.indexOf('  build-linux-app:')
  const linuxJobEnd = workflow.indexOf('  build-windows-app:', linuxJobStart)
  const verifyJob = workflow.slice(verifyJobStart, workflow.indexOf('  build-cli:', verifyJobStart))
  const linuxJob = workflow.slice(linuxJobStart, linuxJobEnd)
  const buildx = linuxJob.indexOf('uses: docker/setup-buildx-action@v3')
  const smoke = linuxJob.indexOf('- name: Smoke launch Linux GUI')
  const cleanup = linuxJob.indexOf('- name: Reclaim Linux GUI smoke storage')
  const desktopPackage = linuxJob.indexOf('- name: Build Linux desktop package')

  assert.ok(verifyJobStart >= 0 && linuxJobStart >= 0 && linuxJobEnd > linuxJobStart)
  assert.match(verifyJob, /uses: docker\/setup-buildx-action@v3/)
  assert.ok(buildx >= 0 && smoke > buildx && cleanup > smoke && desktopPackage > cleanup)
  assert.match(linuxJob, /docker compose down --volumes --remove-orphans/)
  assert.match(linuxJob, /docker system prune --all --force --volumes/)
})

test('dispatched release notes record the checked-out tag source commit', () => {
  const workflow = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')

  assert.match(workflow, /--commit "\$\(git rev-parse HEAD\)"/)
  assert.doesNotMatch(workflow, /--commit "\$\{GITHUB_SHA\}"/)
})

test('GitHub release requires an exact locally gated commit', () => {
  const workflow = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')
  const trigger = workflow.slice(0, workflow.indexOf('\nenv:'))

  assert.match(trigger, /workflow_dispatch:/)
  assert.doesNotMatch(trigger, /^\s+push:/m)
  assert.match(trigger, /locally_attested_commit:\n\s+description:[^\n]+\n\s+required: true/)
  assert.match(workflow, /ref: \$\{\{ github\.event\.inputs\.tag \}\}/)
  assert.match(
    workflow,
    /LOCALLY_ATTESTED_COMMIT: \$\{\{ github\.event\.inputs\.locally_attested_commit \}\}/,
  )
  assert.match(workflow, /LOCALLY_ATTESTED_COMMIT.*does not match tag commit/s)
})

test('GitHub platform builds run beside verification and join before release', () => {
  const workflow = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')
  const releaseJobStart = workflow.indexOf('  release:')
  const releaseJob = workflow.slice(releaseJobStart)

  assert.ok(releaseJobStart >= 0)
  assert.doesNotMatch(workflow, /^    needs: verify$/m)
  assert.match(releaseJob, /needs:\n      - verify/)
  for (const job of [
    'build-cli',
    'build-macos-app',
    'build-linux-app',
    'build-windows-app',
    'build-android-app',
    'build-startos',
  ]) {
    assert.match(releaseJob, new RegExp(`needs\\.${job}\\.result == 'success'`))
    assert.match(releaseJob, new RegExp(`- ${job}`))
  }
})

test('GitHub release requires and publishes both StartOS package architectures', () => {
  const workflow = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')
  const startosJobStart = workflow.indexOf('  build-startos:')
  const releaseJobStart = workflow.indexOf('  release:')
  const startosJob = workflow.slice(startosJobStart, releaseJobStart)
  const releaseJob = workflow.slice(releaseJobStart)

  assert.ok(startosJobStart >= 0 && releaseJobStart > startosJobStart)
  assert.match(startosJob, /STARTOS_DEV_KEY/)
  assert.match(startosJob, /STARTOS_CLI_VERSION: '0\.4\.0-beta\.9'/)
  assert.match(startosJob, /startos_cli_sha256: 212686c28056b48810b383d7aa2cfc733db7332d406f4376a0bfd6ca94c6d88f/)
  assert.match(startosJob, /startos_cli_sha256: eb09a55aeb8241a6ed0a7659ed8bd5f86f950fb3b5315bc2798a05d8edd07d29/)
  assert.match(startosJob, /releases\/download\/v\$\{STARTOS_CLI_VERSION\}/)
  assert.match(startosJob, /sha256sum --check/)
  assert.match(startosJob, /start-cli \$\{STARTOS_CLI_VERSION\}/)
  assert.match(startosJob, /target: x86/)
  assert.match(startosJob, /target: arm/)
  assert.match(startosJob, /scripts\/startos-release\.mjs/)
  assert.match(releaseJob, /needs\.build-startos\.result == 'success'/)
  assert.match(releaseJob, /- build-startos/)
  assert.match(releaseJob, /Built signed StartOS packages for x86_64 and aarch64\./)
})

test('corrected GitHub release is explicitly promoted as latest', () => {
  const workflow = readFileSync(join(process.cwd(), '.github/workflows/release.yml'), 'utf8')
  const releaseJob = workflow.split('  release:', 2)[1]

  assert.match(releaseJob, /make_latest:\s*true/)
})

test('Windows corrected-release tags keep installer version at the marketing version', () => {
  const windowsBuild = readFileSync(join(process.cwd(), 'scripts/windows-build.ps1'), 'utf8')

  assert.match(
    windowsBuild,
    /\$Version = \(\$VersionTag\.TrimStart\("v"\) -split '\\\+', 2\)\[0\]/,
  )
  assert.match(
    windowsBuild,
    /NVPN_WINDOWS_INSTALLER_BASENAME = "nostr-vpn-\$VersionTag-windows-x64-setup"/,
  )
})

test('autoDetectWindowsVmName returns the only running Windows VM', () => {
  const name = autoDetectWindowsVmName(`
UUID                                    STATUS       IP_ADDR         NAME
{1e553d3b-024e-4799-adb0-92127659f5dd}  running      -               Windows 11
`)

  assert.equal(name, 'Windows 11')
})

test('autoDetectWindowsVmName returns null when multiple Windows VMs match', () => {
  const name = autoDetectWindowsVmName(`
UUID                                    STATUS       IP_ADDR         NAME
{1}  running      -               Windows 11
{2}  running      -               Windows ARM
`)

  assert.equal(name, null)
})

test('describeAsset maps release filenames to readable labels', () => {
  assert.equal(
    describeAsset('nostr-vpn-v0.2.27-windows-x64-setup.exe'),
    'Windows x64 installer',
  )
  assert.equal(
    describeAsset('nvpn-v0.2.27-aarch64-pc-windows-msvc.zip'),
    'Windows ARM64 CLI',
  )
  assert.equal(
    describeAsset('nostr-vpn-v4.0.97-startos-x86_64.s9pk'),
    'StartOS x86_64 package',
  )
  assert.equal(
    describeAsset('nostr-vpn-v0.3.23-linux-arm64.AppImage'),
    'Linux ARM64 AppImage',
  )
  assert.equal(
    describeAsset('nostr-vpn-v0.3.23-linux-arm64.deb'),
    'Linux ARM64 Debian package',
  )
  assert.equal(
    describeAsset('nvpn-v0.3.23-aarch64-unknown-linux-musl.tar.gz'),
    'Linux ARM64 CLI (versioned)',
  )
})

test('androidReleaseAssetName formats signed and unsigned Android asset names', () => {
  assert.equal(androidReleaseAssetName('0.3.9'), 'nostr-vpn-v0.3.9-android-arm64.apk')
  assert.equal(
    androidReleaseAssetName('v0.3.9', { extension: 'aab', signed: false }),
    'nostr-vpn-v0.3.9-android-arm64-unsigned.aab',
  )
})

test('buildReleaseManifest records staged assets with sizes', () => {
  const root = mkdtempSync(join(tmpdir(), 'nostr-vpn-release-test-'))
  const assetsDir = join(root, 'assets')
  mkdirSync(assetsDir)
  const installer = join(assetsDir, 'nostr-vpn-v0.2.27-windows-x64-setup.exe')
  const cliZip = join(assetsDir, 'nvpn-v0.2.27-x86_64-pc-windows-msvc.zip')
  writeFileSync(installer, 'installer')
  writeFileSync(cliZip, 'zip')

  const manifest = buildReleaseManifest({
    tag: 'v0.2.27',
    commit: 'abc123',
    createdAt: 1774523304,
    assetPaths: [installer, cliZip],
  })

  assert.equal(manifest.assets.length, 2)
  assert.equal(manifest.assets[0].name, 'nostr-vpn-v0.2.27-windows-x64-setup.exe')
  assert.equal(manifest.assets[1].name, 'nvpn-v0.2.27-x86_64-pc-windows-msvc.zip')
  assert.equal(manifest.assets[0].path, 'assets/nostr-vpn-v0.2.27-windows-x64-setup.exe')
})

test('buildReleaseManifestFiles writes legacy manifest alias', () => {
  const manifest = {
    id: 'v0.3.23',
    assets: [{ name: 'nostr-vpn-v0.3.23-macos-arm64.app.tar.gz' }],
  }

  const files = buildReleaseManifestFiles(manifest)
  assert.deepEqual(files.map(([name]) => name), ['release.json', 'manifest.json'])
  assert.equal(files[0][1], files[1][1])
  assert.deepEqual(JSON.parse(files[0][1]), manifest)
})

test('validateStagedReleaseTree rejects missing manifest assets', () => {
  const root = mkdtempSync(join(tmpdir(), 'nostr-vpn-release-missing-asset-test-'))
  const manifest = {
    assets: [
      {
        name: 'nostr-vpn-v4.0.77-macos-arm64.dmg',
        path: 'assets/nostr-vpn-v4.0.77-macos-arm64.dmg',
        size: 31_537_430,
      },
    ],
  }

  assert.throws(
    () => validateStagedReleaseTree(root, manifest),
    /lists missing asset: assets\/nostr-vpn-v4\.0\.77-macos-arm64\.dmg/,
  )
})

test('validateStagedReleaseTree rejects unsafe asset paths', () => {
  const root = mkdtempSync(join(tmpdir(), 'nostr-vpn-release-unsafe-asset-test-'))
  const manifest = {
    assets: [
      {
        name: 'nostr-vpn-v4.0.77-macos-arm64.dmg',
        path: '../nostr-vpn-v4.0.77-macos-arm64.dmg',
        size: 1,
      },
    ],
  }

  assert.throws(
    () => validateStagedReleaseTree(root, manifest),
    /unsafe asset path/,
  )
})

test('validateStagedReleaseTree rejects staged asset size mismatches', () => {
  const root = mkdtempSync(join(tmpdir(), 'nostr-vpn-release-size-asset-test-'))
  const assetsDir = join(root, 'assets')
  mkdirSync(assetsDir)
  writeFileSync(join(assetsDir, 'nostr-vpn-v4.0.77-macos-arm64.dmg'), 'tiny')

  const manifest = {
    assets: [
      {
        name: 'nostr-vpn-v4.0.77-macos-arm64.dmg',
        path: 'assets/nostr-vpn-v4.0.77-macos-arm64.dmg',
        size: 31_537_430,
      },
    ],
  }

  assert.throws(
    () => validateStagedReleaseTree(root, manifest),
    /size mismatch/,
  )
})

test('extractChangelogSection returns the matching version body', () => {
  const section = extractChangelogSection(`
# Changelog

## Unreleased

## 0.3.0 - 2026-03-31

Changes since v0.2.28.

### Added

- Admin-managed rosters.

## 0.2.28 - 2026-03-26

- Previous release.
`, 'v0.3.0')

  assert.equal(
    section,
    'Changes since v0.2.28.\n\n### Added\n\n- Admin-managed rosters.',
  )
})

test('extractChangelogSection uses the marketing version for corrected build tags', () => {
  const section = extractChangelogSection(`
# Changelog

## 4.1.4 - 2026-07-23

- Corrected the iOS App Store build.

## 4.1.3 - 2026-07-20

- Earlier release.
`, 'v4.1.4+4001006')

  assert.equal(section, '- Corrected the iOS App Store build.')
})

test('extractChangelogSection prefers corrected build notes when present', () => {
  const section = extractChangelogSection(`
# Changelog

## 4.1.4+4001006 - 2026-07-23

- Corrected build-specific notes.

## 4.1.4 - 2026-07-22

- Original marketing release.
`, 'v4.1.4+4001006')

  assert.equal(section, '- Corrected build-specific notes.')
})

test('renderReleaseNotes includes changelog, built, and skipped sections', () => {
  const notes = renderReleaseNotes({
    tag: 'v0.2.27',
    commit: 'abc123',
    assetNames: [
      'nostr-vpn-v0.2.27-macos-arm64.app.tar.gz',
      'nostr-vpn-v0.2.27-macos-arm64.dmg',
      'nvpn-v0.2.27-x86_64-pc-windows-msvc.zip',
    ],
    changelogText: `
# Changelog

## 0.2.27 - 2026-03-25

Changes since v0.2.26.

### Fixed

- Release note formatting.
`,
    builtLines: ['Built Windows x64 CLI on windows-builder.'],
    skippedLines: ['Linux musl CLI skipped because cross was unavailable.'],
  })

  assert.match(notes, /## Changes/)
  assert.match(notes, /Changes since v0\.2\.26\./)
  assert.match(notes, /### Fixed/)
  assert.match(notes, /### Most People Will Want/)
  assert.match(notes, /### Command Line/)
  assert.match(notes, /Windows x64 CLI/)
  assert.match(notes, /Built Windows x64 CLI on windows-builder\./)
  assert.match(notes, /Linux musl CLI skipped because cross was unavailable\./)
})

test('renderReleaseNotes omits CLI skip boilerplate and can link assets', () => {
  const notes = renderReleaseNotes({
    tag: 'v0.3.0',
    commit: 'abc123',
    assetNames: [
      'nostr-vpn-v0.3.0-macos-arm64.app.tar.gz',
      'nostr-vpn-v0.3.0-macos-arm64.dmg',
    ],
    assetBaseUrl: 'https://github.com/mmalmi/nostr-vpn/releases/download/v0.3.0',
    skippedLines: [
      'verify skipped by CLI options.',
      'windows skipped by CLI options.',
    ],
  })

  assert.match(
    notes,
    /\[nostr-vpn-v0\.3\.0-macos-arm64\.dmg\]\(https:\/\/github\.com\/mmalmi\/nostr-vpn\/releases\/download\/v0\.3\.0\/nostr-vpn-v0\.3\.0-macos-arm64\.dmg\)/,
  )
  assert.doesNotMatch(notes, /verify skipped by CLI options/)
  assert.doesNotMatch(notes, /windows skipped by CLI options/)
})

test('renderReleaseNotes groups common app downloads before advanced files', () => {
  const notes = renderReleaseNotes({
    tag: 'v0.3.23',
    commit: 'abc123',
    assetNames: [
      'nostr-vpn-v0.3.23-android-arm64.aab',
      'nostr-vpn-v0.3.23-android-arm64.apk',
      'nostr-vpn-v0.3.23-linux-x64.AppImage',
      'nostr-vpn-v0.3.23-linux-x64.deb',
      'nostr-vpn-v0.3.23-macos-arm64.app.tar.gz',
      'nostr-vpn-v0.3.23-macos-arm64.dmg',
      'nostr-vpn-v0.3.23-startos-aarch64.s9pk',
      'nostr-vpn-v0.3.23-startos-x86_64.s9pk',
      'nostr-vpn-v0.3.23-windows-x64-setup.exe',
      'nvpn-aarch64-apple-darwin.tar.gz',
      'nvpn-v0.3.23-aarch64-apple-darwin.tar.gz',
      'nvpn-v0.3.23-x86_64-pc-windows-msvc.zip',
      'nvpn-v0.3.23-x86_64-unknown-linux-musl.tar.gz',
      'nvpn-x86_64-unknown-linux-musl.tar.gz',
    ],
  })

  assert.match(notes, /### Most People Will Want[\s\S]*Nostr VPN for macOS \(Apple Silicon\)/)
  assert.match(notes, /### Most People Will Want[\s\S]*Nostr VPN for Linux \(AppImage\)/)
  assert.match(notes, /### Most People Will Want[\s\S]*Nostr VPN for Windows/)
  assert.doesNotMatch(
    notes.match(/### Most People Will Want[\s\S]*?(?=\n### )/)?.[0] ?? '',
    /StartOS/,
  )
  assert.match(notes, /### StartOS Servers[\s\S]*Nostr VPN for StartOS \(x86_64\)/)
  assert.match(notes, /### StartOS Servers[\s\S]*Nostr VPN for StartOS \(aarch64\)/)
  assert.match(notes, /Server One and Server Pure use x86_64/)
  assert.match(notes, /### Command Line[\s\S]*macOS Apple Silicon CLI: \[nvpn-aarch64-apple-darwin\.tar\.gz\]\(assets\/nvpn-aarch64-apple-darwin\.tar\.gz\)/)
  assert.match(notes, /### Command Line[\s\S]*Linux x64 CLI: \[nvpn-x86_64-unknown-linux-musl\.tar\.gz\]\(assets\/nvpn-x86_64-unknown-linux-musl\.tar\.gz\)/)
  assert.match(notes, /### Other Files[\s\S]*Android arm64 AAB/)
  assert.match(notes, /### Other Files[\s\S]*macOS Apple Silicon updater archive/)
  assert.doesNotMatch(notes, /nvpn-v0\.3\.23-aarch64-apple-darwin\.tar\.gz/)
  assert.doesNotMatch(notes, /nvpn-v0\.3\.23-x86_64-unknown-linux-musl\.tar\.gz/)
})

test('semverFromTag strips an optional v prefix', () => {
  assert.equal(semverFromTag('v4.0.6'), '4.0.6')
  assert.equal(semverFromTag('4.0.6'), '4.0.6')
  assert.equal(semverFromTag('v4.1.4+4001006'), '4.1.4')
  assert.throws(() => semverFromTag('4.0'), /semver-shaped/)
  assert.throws(() => semverFromTag('4.0.6-alpha'), /semver-shaped/)
})

test('corrected release tags keep build metadata separate from marketing versions', () => {
  const correctedTag = 'v4.1.4+4001006'
  assert.equal(
    bumpPbxprojMarketingVersion('MARKETING_VERSION = 4.1.3;', correctedTag),
    'MARKETING_VERSION = 4.1.4;',
  )
  assert.equal(
    bumpCargoPackageVersion('[package]\nname = "example"\nversion = "4.1.3"\n\n[dependencies]\n', correctedTag),
    '[package]\nname = "example"\nversion = "4.1.4"\n\n[dependencies]\n',
  )
  const manifest = buildReleaseManifest({
    tag: correctedTag,
    commit: 'abc123',
    createdAt: 123,
    assetPaths: [],
  })
  assert.equal(manifest.tag, correctedTag)
  assert.equal(manifest.prerelease, false)
  assert.equal(
    bumpAndroidGradleVersion(
      `
android {
    defaultConfig {
        versionCode = 4010400
        versionName = "4.1.4"
    }
}
`,
      correctedTag,
      { versionCode: 4_010_401 },
    ).match(/versionCode = (\d+)/)?.[1],
    '4010401',
  )
})

test('androidVersionCode reserves two digits for corrected-release revisions', () => {
  assert.equal(androidVersionCode('4.0.6'), 4_000_600)
  assert.equal(androidVersionCode('4.0.10'), 4_001_000)
  assert.equal(androidVersionCode('4.10.0'), 4_100_000)
  assert.equal(androidVersionCode('5.0.0'), 5_000_000)
  assert.equal(androidVersionCode('4.1.4', 1), 4_010_401)
  assert.equal(androidVersionCode('4.1.5'), 4_010_500)
  assert.throws(() => androidVersionCode('4.100.0'), /minor\/patch < 100/)
  assert.throws(() => androidVersionCode('4.1.4', 100), /revision/)
})

test('bumpPbxprojMarketingVersion replaces every MARKETING_VERSION setting', () => {
  const input = `
\t\t\t\tDEVELOPMENT_TEAM = ABC123;
\t\t\t\tMARKETING_VERSION = 4.0.2;
\t\t\t\tPRODUCT_NAME = Nostr VPN;
\t\t\t\tMARKETING_VERSION = 4.0.2;
`
  const next = bumpPbxprojMarketingVersion(input, 'v4.0.6')
  assert.equal(
    next,
    input.replaceAll('MARKETING_VERSION = 4.0.2;', 'MARKETING_VERSION = 4.0.6;'),
  )
})

test('bumpAndroidGradleVersion bumps both versionCode and versionName', () => {
  const input = `
android {
    defaultConfig {
        versionCode = 40002
        versionName = "4.0.2"
    }
}
`
  const next = bumpAndroidGradleVersion(input, '4.0.6')
  assert.match(next, /versionCode = 4000600/)
  assert.match(next, /versionName = "4\.0\.6"/)
  assert.doesNotMatch(next, /4\.0\.2/)
})

test('bumpAndroidGradleVersion preserves a correction only for the same marketing version', () => {
  const corrected = `
android {
    defaultConfig {
        versionCode = 4010401
        versionName = "4.1.4"
    }
}
`
  assert.match(
    bumpAndroidGradleVersion(corrected, 'v4.1.4+4001006'),
    /versionCode = 4010401[\s\S]*versionName = "4\.1\.4"/,
  )
  assert.match(
    bumpAndroidGradleVersion(corrected, 'v4.1.5'),
    /versionCode = 4010500[\s\S]*versionName = "4\.1\.5"/,
  )
  assert.throws(
    () => bumpAndroidGradleVersion(corrected, 'v4.1.4', { versionCode: 4_010_500 }),
    /does not encode marketing version 4\.1\.4/,
  )
})

test('bumpStartosSourceVersion preserves a correction and resets it on the next version', () => {
  const corrected = "export const currentVersion = VersionInfo.of({\n  version: '4.1.4:1',\n})\n"
  assert.equal(
    bumpStartosSourceVersion(corrected, 'v4.1.4+4001006'),
    corrected,
  )
  assert.equal(
    bumpStartosSourceVersion(corrected, 'v4.1.5'),
    "export const currentVersion = VersionInfo.of({\n  version: '4.1.5:0',\n})\n",
  )
})

test('bumpCargoPackageVersion only touches [package] version', () => {
  const input = `
[package]
name = "nostr-vpn-linux"
version = "4.0.2"
edition = "2021"

[dependencies]
adw = { package = "libadwaita", version = "0.7" }
`
  const next = bumpCargoPackageVersion(input, '4.0.6')
  assert.match(next, /\[package\][\s\S]*version = "4\.0\.6"/)
  assert.match(next, /adw = \{ package = "libadwaita", version = "0\.7" \}/)
})
