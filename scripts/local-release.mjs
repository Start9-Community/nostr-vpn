#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from 'node:fs'
import os from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import {
  androidReleaseAssetName,
  buildReleaseManifest,
  buildReleaseManifestFiles,
  bumpAndroidGradleVersion,
  bumpCargoPackageVersion,
  bumpPbxprojMarketingVersion,
  deterministicBuildEnv,
  linuxReleaseTargetsForDockerPlatform,
  normalizeTag,
  parseEnvFile,
  readWorkspaceVersionTag,
  semverFromTag,
  sha256FileSync,
  splitCsv,
  validateAndroidReleaseGateReceipt,
  validateCleanReleaseSource,
  validatePromotableReleaseManifest,
  validatePromotableReleaseSource,
  validateReleaseAssetSet,
  validateStagedReleaseTree,
  validateZapstoreApkMetadata,
  validateZapstoreRelayPublication,
  windowsSshTransportArgs,
  zapstorePublicationPrerequisites,
  zapstorePublicationRequired,
} from './local-release-lib.mjs'
import {
  androidRuntimePayloads,
  archiveMemberSha256 as commandOutputSha256,
  buildReleaseGateAttestation,
  collectReleaseGateReceipts,
  exactArtifactProof,
  mergeArtifactProofs,
  readRequiredJson,
  requireReceiptSource,
  startosExactPackageValidator,
  validateWindowsInstallerGateReceipt,
} from './release-artifact-provenance-lib.mjs'
import { inspectStartosReleasePackage } from './startos-release.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(__dirname, '..')
const rootCargoToml = join(repoRoot, 'Cargo.toml')
const changelogPath = join(repoRoot, 'CHANGELOG.md')
const distDir = join(repoRoot, 'dist')
const defaultEnvFiles = [join(repoRoot, '.env.release.local'), join(repoRoot, '.env.zapstore.local')]
const versionlessCliAssets = new Map([
  ['nvpn-aarch64-apple-darwin.tar.gz', 'nvpn-{tag}-aarch64-apple-darwin.tar.gz'],
  ['nvpn-x86_64-unknown-linux-musl.tar.gz', 'nvpn-{tag}-x86_64-unknown-linux-musl.tar.gz'],
  ['nvpn-aarch64-unknown-linux-musl.tar.gz', 'nvpn-{tag}-aarch64-unknown-linux-musl.tar.gz'],
])

class SkipStepError extends Error {}

function usage() {
  console.log(`Usage: node scripts/local-release.mjs [options]

Build local Rust/native release artifacts, stage a hashtree release directory,
and optionally publish it.

Options:
  --publish                 Publish the staged htree release as a draft
                            (default publish mode; repoints draft instead of
                            latest and does not publish crates/Zapstore)
  --final                   Publish the htree release as final/latest (also
                            runs scripts/publish.sh to ship the Rust crates
                            unless --skip-cargo-publish is given)
  --draft                   Alias for --publish, kept for explicitness
  --promote-draft           Promote an existing staged draft directory for
                            this tag to final/latest without rebuilding
  --cargo-publish           Force publishing Rust crates to crates.io even
                            without --publish (e.g. to retry a partial release)
  --skip-cargo-publish      With --publish, stage and publish the htree tree
                            but don't push the crates to crates.io
  --skip-zapstore           With --publish, skip the Android APK publish to
                            Zapstore (default: publish when zsp is on PATH
                            and a Nostr signing key is configured)
  --require-zapstore        With a final publish, require a signed APK, zsp,
                            signing configuration, successful publication,
                            and post-publish Zapstore verification
  --dry-run                 Print the plan without running build or publish commands
  --skip-verify            Skip fmt/clippy/test verification
  --tag <tag>              Release tag (defaults to workspace version, for example v4.0.0)
  --release-tree <name>    htree release tree name (default: releases/nostr-vpn)
  --stage-dir <path>       Directory used for staged release metadata
  --env-file <path>        Extra dotenv file to load (repeatable)
  --only <csv>             Limit steps to platform-versions,verify,startos,macos,ios,linux,windows,android
  --skip <csv>             Skip steps by name
  --allow-partial          Stage/publish even if a selected platform build fails
  --help                   Show this help

The script auto-loads .env.release.local and .env.zapstore.local when present.
Shell environment variables override values from those files.
NVPN_RELEASE_REQUIRE_ZAPSTORE=true is equivalent to --require-zapstore.`)
}

function parseArgs(argv) {
  const options = {
    dryRun: false,
    publish: false,
    draft: true,
    promoteDraft: false,
    cargoPublish: false,
    skipCargoPublish: false,
    skipZapstore: false,
    requireZapstore: false,
    skipVerify: false,
    releaseTree: null,
    stageDir: null,
    tag: null,
    envFiles: [],
    only: null,
    skip: new Set(),
    allowPartial: false,
  }

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    switch (arg) {
      case '--help':
      case '-h':
        usage()
        process.exit(0)
      case '--publish':
        options.publish = true
        break
      case '--final':
      case '--publish-final':
        options.publish = true
        options.draft = false
        break
      case '--draft':
        options.publish = true
        options.draft = true
        break
      case '--promote-draft':
        options.publish = true
        options.draft = false
        options.promoteDraft = true
        break
      case '--cargo-publish':
        options.cargoPublish = true
        break
      case '--skip-cargo-publish':
        options.skipCargoPublish = true
        break
      case '--skip-zapstore':
        options.skipZapstore = true
        break
      case '--require-zapstore':
        options.requireZapstore = true
        break
      case '--dry-run':
        options.dryRun = true
        break
      case '--skip-verify':
        options.skipVerify = true
        break
      case '--tag':
        options.tag = normalizeTag(argv[++index] ?? '')
        break
      case '--release-tree':
        options.releaseTree = argv[++index] ?? ''
        break
      case '--stage-dir':
        options.stageDir = argv[++index] ?? ''
        break
      case '--env-file':
        options.envFiles.push(resolve(repoRoot, argv[++index] ?? ''))
        break
      case '--only':
        options.only = new Set(splitCsv(argv[++index] ?? ''))
        break
      case '--skip':
        for (const value of splitCsv(argv[++index] ?? '')) {
          options.skip.add(value)
        }
        break
      case '--allow-partial':
        options.allowPartial = true
        break
      default:
        throw new Error(`Unknown argument: ${arg}`)
    }
  }

  return options
}

function readOptionalEnvFiles(envFiles) {
  const loaded = {}
  const loadedPaths = []

  for (const envFile of envFiles) {
    if (!existsSync(envFile)) {
      continue
    }
    Object.assign(loaded, parseEnvFile(readFileSync(envFile, 'utf8')))
    loadedPaths.push(envFile)
  }

  return { loaded, loadedPaths }
}

function commandExists(command) {
  const result =
    process.platform === 'win32'
      ? spawnSync('where', [command], { stdio: 'ignore' })
      : spawnSync('sh', ['-lc', `command -v "${command}"`], { stdio: 'ignore' })

  return result.status === 0
}

function gitHeadEpoch() {
  const result = spawnSync('git', ['log', '-1', '--format=%ct', 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: 'pipe',
  })
  return result.status === 0 ? result.stdout.trim() : ''
}

function assertCleanReleaseSource(tag, expectedCommit = '') {
  const status = run(
    'git',
    ['status', '--porcelain=v1', '--untracked-files=all'],
    { capture: true },
  )
  const headCommit = run('git', ['rev-parse', 'HEAD'], { capture: true })
  const taggedResult = spawnSync(
    'git',
    ['rev-parse', '-q', '--verify', `${normalizeTag(tag)}^{commit}`],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: 'pipe',
    },
  )
  const taggedCommit = taggedResult.status === 0 ? taggedResult.stdout.trim() : ''
  const candidate = validateCleanReleaseSource({
    status,
    headCommit,
    taggedCommit,
    tag,
  })
  if (expectedCommit && candidate !== expectedCommit) {
    throw new Error(
      `Release source changed during the build: started at ${expectedCommit}, now ${candidate}.`,
    )
  }
  return candidate
}

function gitTree(commit = 'HEAD') {
  return run('git', ['rev-parse', `${commit}^{tree}`], { capture: true })
}

function pathSha256(path) {
  return createHash('sha256').update(realpathSync(path)).digest('hex')
}

function assertPromotableDraftSource(tag, manifest) {
  const status = run(
    'git',
    ['status', '--porcelain=v1', '--untracked-files=all'],
    { capture: true },
  )
  const headCommit = run('git', ['rev-parse', 'HEAD'], { capture: true })
  const taggedResult = spawnSync(
    'git',
    ['rev-parse', '-q', '--verify', `${normalizeTag(tag)}^{commit}`],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: 'pipe',
    },
  )
  return validatePromotableReleaseSource({
    manifest,
    requestedTag: tag,
    workspaceTag: readWorkspaceVersionTag(readFileSync(rootCargoToml, 'utf8')),
    status,
    headCommit,
    taggedCommit: taggedResult.status === 0 ? taggedResult.stdout.trim() : '',
  })
}

function quote(arg) {
  const value = String(arg)
  return /[^\w./:-]/.test(value) ? JSON.stringify(value) : value
}

function envFlagEnabled(value) {
  return /^(1|true|yes|on)$/i.test(String(value ?? '').trim())
}

function cargoTargetDir(env = process.env) {
  const configured = String(env.CARGO_TARGET_DIR ?? '').trim()
  if (configured.length === 0) {
    return join(repoRoot, 'target')
  }
  return resolve(repoRoot, configured)
}

function macosCargoTargetDir(env = process.env) {
  const configured = String(env.NVPN_MACOS_CARGO_TARGET_DIR ?? '').trim()
  if (configured.length === 0) {
    return join(repoRoot, 'macos', '.build', 'cargo-target')
  }
  return resolve(repoRoot, configured)
}

function findFirstFile(root, matcher) {
  if (!existsSync(root)) {
    return null
  }

  const entries = readdirSync(root).sort()
  const match = entries.find((entry) => matcher(entry))
  return match ? join(root, match) : null
}

function run(
  command,
  args,
  {
    cwd = repoRoot,
    env = process.env,
    capture = false,
    input,
    dryRun = false,
  } = {},
) {
  const rendered = [command, ...args].map(quote).join(' ')
  console.log(`$ ${rendered}`)
  if (dryRun) {
    return ''
  }

  const result = spawnSync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    input,
    stdio: capture ? 'pipe' : 'inherit',
  })
  if (result.status !== 0) {
    const stderr = capture ? result.stderr.trim() : ''
    throw new Error(stderr || `${command} exited with status ${result.status ?? 'unknown'}`)
  }
  return capture ? result.stdout.trim() : ''
}

function readReleaseManifest(stageDir) {
  const releaseJsonPath = join(stageDir, 'release.json')
  const manifestJsonPath = join(stageDir, 'manifest.json')
  if (!existsSync(releaseJsonPath) || !existsSync(manifestJsonPath)) {
    throw new Error(`No staged release manifest found at ${stageDir}. Run the draft release first or pass --stage-dir.`)
  }

  const releaseText = readFileSync(releaseJsonPath, 'utf8')
  const manifestText = readFileSync(manifestJsonPath, 'utf8')
  if (releaseText !== manifestText) {
    throw new Error('release.json and manifest.json differ in the staged release tree.')
  }

  const manifest = JSON.parse(releaseText)
  validateStagedReleaseTree(stageDir, manifest)
  return manifest
}

function verifyHtreeReleaseCid({ cid, manifest, dryRun }) {
  if (dryRun) {
    console.log(`Would verify ${manifest.assets.length} htree asset(s) from ${cid}`)
    return
  }

  const paths = [
    'release.json',
    'manifest.json',
    'notes.md',
    ...manifest.assets.map((asset) => asset.path),
  ]
  for (const path of paths) {
    const result = spawnSync('htree', ['cat', `${cid}/${path}`], {
      cwd: repoRoot,
      env: process.env,
      encoding: 'buffer',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 512 * 1024 * 1024,
    })
    if (result.status !== 0) {
      const stderr = result.stderr ? result.stderr.toString('utf8').trim() : ''
      throw new Error(`Published htree CID does not contain ${path}${stderr ? `: ${stderr}` : ''}`)
    }

    const asset = manifest.assets.find((candidate) => candidate.path === path)
    if (asset && result.stdout.length !== asset.size) {
      throw new Error(
        `Published htree CID size mismatch for ${path}: manifest ${asset.size} bytes, htree cat returned ${result.stdout.length} bytes.`,
      )
    }
    if (
      asset
      && createHash('sha256').update(result.stdout).digest('hex') !== asset.sha256
    ) {
      throw new Error(`Published htree CID SHA-256 mismatch for ${path}.`)
    }
  }
}

function writeUnixInstallScript(path) {
  writeFileSync(
    path,
    `#!/bin/bash
set -e

path_contains() {
  case ":\${PATH}:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

default_install_dir() {
  if [ "$(uname -s)" = "Darwin" ] && { [ -d /opt/homebrew/bin ] || path_contains /opt/homebrew/bin; }; then
    printf '%s\\n' /opt/homebrew/bin
  else
    printf '%s\\n' /usr/local/bin
  fi
}

INSTALL_DIR="\${1:-$(default_install_dir)}"
install -d "\${INSTALL_DIR}"
install -m 755 nvpn "\${INSTALL_DIR}/"
`,
  )
}

function writeUnixReadme(path) {
  writeFileSync(
    path,
    `nvpn - FIPS private mesh CLI
============================

Binary included:
  nvpn  - CLI control plane

Quick install:
  ./install.sh
  ./install.sh ~/.local/bin
`,
  )
}

function setTreeMtime(root, epochSeconds) {
  const epoch = Number(epochSeconds)
  if (!Number.isFinite(epoch)) {
    return
  }
  const when = new Date(epoch * 1000)
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) {
      setTreeMtime(path, epochSeconds)
    }
    utimesSync(path, when, when)
  }
  utimesSync(root, when, when)
}

function packageUnixCliTarball({ binaryPath, targetTriple, tag, dryRun }) {
  const bundleDir = join(distDir, 'nvpn')
  if (!dryRun) {
    rmSync(bundleDir, { recursive: true, force: true })
    mkdirSync(bundleDir, { recursive: true })
    copyFileSync(binaryPath, join(bundleDir, 'nvpn'))
    writeUnixInstallScript(join(bundleDir, 'install.sh'))
    writeUnixReadme(join(bundleDir, 'README.txt'))
    setTreeMtime(bundleDir, process.env.SOURCE_DATE_EPOCH)
  }

  run('chmod', ['+x', join(bundleDir, 'install.sh')], { dryRun })

  const unversioned = join(distDir, `nvpn-${targetTriple}.tar.gz`)
  const versioned = join(distDir, `nvpn-${tag}-${targetTriple}.tar.gz`)
  const tarPath = unversioned.replace(/\.gz$/, '')
  run('tar', ['-cf', tarPath, '-C', distDir, 'nvpn/README.txt', 'nvpn/install.sh', 'nvpn/nvpn'], { dryRun })
  run('gzip', ['-n', '-f', tarPath], { dryRun })
  if (!dryRun) {
    copyFileSync(unversioned, versioned)
  }
  return [unversioned, versioned]
}

function psQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`
}

function encodePowerShellScript(script) {
  return Buffer.from(script, 'utf16le').toString('base64')
}

/// Run a PowerShell snippet on the remote SSH host. We base64 the source so
/// quoting and newlines survive the SSH/PowerShell round-trip cleanly.
function runWindowsPowerShell(host, script, { capture = false, dryRun = false } = {}) {
  const encoded = encodePowerShellScript(script)
  return run(
    'ssh',
    [
      ...windowsSshTransportArgs(process.env),
      host,
      'powershell.exe',
      '-NoProfile',
      '-EncodedCommand',
      encoded,
    ],
    { capture, dryRun },
  )
}

function pullFileFromWindowsHost({ host, remotePath, localParent, name, dryRun }) {
  const remoteFile = `${remotePath.replace(/\\/g, '/')}/${name}`
  const dest = join(localParent, name)
  if (!dryRun) {
    mkdirSync(localParent, { recursive: true })
  }
  run('scp', [...windowsSshTransportArgs(process.env), `${host}:${remoteFile}`, dest], { dryRun })
}

function buildWindowsArtifacts({
  env,
  tag,
  dryRun,
  builtLines,
  candidateCommit,
  candidateTree,
  gateReceiptPath,
  installerReceiptPath,
  installerArtifactPath,
}) {
  const host = String(env.NVPN_WINDOWS_SSH_HOST || '').trim()
  if (!host) {
    throw new SkipStepError(
      'Skipping Windows artifacts because NVPN_WINDOWS_SSH_HOST is unset.',
    )
  }

  if (!dryRun) {
    const probe = spawnSync(
      'ssh',
      [...windowsSshTransportArgs(env), host, 'whoami'],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    )
    if (probe.status !== 0) {
      throw new SkipStepError(
        `Skipping Windows artifacts because ssh ${host} is unreachable. ` +
          'Bring up the VM (e.g. on local VM host) and ensure VPN is connected, or set NVPN_WINDOWS_SSH_HOST.',
      )
    }
  }

  const guestRepo = env.NVPN_WINDOWS_GUEST_REPO_PATH || 'C:\\src\\nostr-vpn'
  const vmArchitecture = runWindowsPowerShell(
    host,
    '[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()',
    { capture: true, dryRun },
  ).trim()
  if (!dryRun && vmArchitecture.toLowerCase() !== 'x64') {
    throw new SkipStepError(
      `Skipping Windows artifacts because ${host} is ${vmArchitecture}; Windows x64 release artifacts must be built on an x64 Windows runner.`,
    )
  }

  const targets = splitCsv(
    env.NVPN_WINDOWS_CLI_TARGETS || 'x86_64-pc-windows-msvc',
  )
  if (
    targets.length !== 1
    || targets[0] !== 'x86_64-pc-windows-msvc'
  ) {
    throw new Error(
      'Windows publication only supports the x64 CLI payload exercised by the real Windows gate.',
    )
  }
  const guiTargets = splitCsv(env.NVPN_WINDOWS_GUI_TARGETS || 'x86_64-pc-windows-msvc')
  if (
    guiTargets.length !== 1
    || guiTargets[0] !== 'x86_64-pc-windows-msvc'
  ) {
    throw new Error(
      'Windows publication only supports the x64 installer exercised by the real Windows gate.',
    )
  }

  const guestArtifactRoot =
    env.NVPN_WINDOWS_RELEASE_ARTIFACT_ROOT
    || env.GUEST_ARTIFACT_ROOT
    || `${guestRepo}\\artifacts`
  const guestPublishDir =
    env.NVPN_WINDOWS_RELEASE_PUBLISH_DIR
    || `${guestRepo}\\windows\\NostrVpn.Windows\\bin\\Release\\net8.0-windows\\win-x64\\publish`
  const installerName = `nostr-vpn-${tag}-windows-x64-setup.exe`
  const archiveName = `nvpn-${tag}-x86_64-pc-windows-msvc.zip`
  if (dryRun) {
    builtLines.push('Reused the exact Windows installer and CLI payload exercised by the Windows VM gate.')
    return {}
  }

  const receipt = readRequiredJson(
    gateReceiptPath,
    'Windows exact-artifact gate receipt',
  )
  requireReceiptSource(receipt, {
    commit: candidateCommit,
    tree: candidateTree,
    label: 'Windows exact-artifact gate receipt',
  })
  const installerReceipt = readRequiredJson(
    installerReceiptPath,
    'Windows exact installer gate receipt',
  )
  const sealedInstaller = validateWindowsInstallerGateReceipt({
    receipt: installerReceipt,
    artifactReceipt: receipt,
    commit: candidateCommit,
    tree: candidateTree,
    expectedTag: tag,
  })
  if (
    !existsSync(installerArtifactPath)
    || basename(installerArtifactPath) !== sealedInstaller.installerName
    || sha256FileSync(installerArtifactPath)
      !== sealedInstaller.installerSha256
    || statSync(installerArtifactPath).size
      !== sealedInstaller.installerSize
  ) {
    throw new Error(
      'Windows publication installer is not the exact locally retained installer exercised by the real gate.',
    )
  }
  const expected = sealedInstaller.payloads

  const guestInstallerGateDir =
    env.NVPN_WINDOWS_INSTALLER_GATE_REMOTE_DIR
    || `${guestArtifactRoot}\\windows-installer-gate`
  const guestInstaller = `${guestInstallerGateDir}\\${installerName}`
  const guestArchive = `${guestArtifactRoot}\\${archiveName}`
  runWindowsPowerShell(
    host,
    `
$ErrorActionPreference = 'Stop'
& ${psQuote(`${guestRepo}\\scripts\\windows-release-publication-proof.ps1`)} \`
  -RepoPath ${psQuote(guestRepo)} \`
  -ExpectedCommit ${psQuote(candidateCommit)} \`
  -ExpectedTree ${psQuote(candidateTree)} \`
  -PublishDir ${psQuote(guestPublishDir)} \`
  -InstallerPath ${psQuote(guestInstaller)} \`
  -ArtifactRoot ${psQuote(guestArtifactRoot)} \`
  -ArchivePath ${psQuote(guestArchive)} \`
  -ExpectedInstallerSha256 ${psQuote(sealedInstaller.installerSha256)} \`
  -ExpectedInstallerSize ${sealedInstaller.installerSize} \`
  -ExpectedAppSha256 ${psQuote(expected.app)} \`
  -ExpectedAppCoreSha256 ${psQuote(expected.appCore)} \`
  -ExpectedCliSha256 ${psQuote(expected.cli)} \`
  -ExpectedWintunSha256 ${psQuote(expected.wintun)}
`,
  )
  pullFileFromWindowsHost({
    host,
    remotePath: guestArtifactRoot,
    localParent: distDir,
    name: archiveName,
    dryRun: false,
  })
  const installerPath = join(distDir, installerName)
  const archivePath = join(distDir, archiveName)
  mkdirSync(distDir, { recursive: true })
  copyFileSync(installerArtifactPath, installerPath)
  if (
    sha256FileSync(installerPath) !== sealedInstaller.installerSha256
    || statSync(installerPath).size !== sealedInstaller.installerSize
  ) {
    throw new Error(
      'Windows exact installer changed while copying it into the publication directory.',
    )
  }
  if (
    commandOutputSha256('unzip', ['-p', archivePath, 'nvpn.exe'])
      !== expected.cli
    || commandOutputSha256(
      'unzip',
      ['-p', archivePath, 'binaries/wintun.dll'],
    ) !== expected.wintun
  ) {
    throw new Error(
      'Windows CLI archive differs from the exact Windows VM gate payload.',
    )
  }
  builtLines.push('Reused the exact Windows installer and CLI payload exercised by the Windows VM gate.')
  return {
    [installerName]: exactArtifactProof({
      artifactPath: installerPath,
      platform: 'windows',
      gateReceiptPath: installerReceiptPath,
      payloads: {
        app: expected.app,
        app_core: expected.appCore,
        cli: expected.cli,
        wintun: expected.wintun,
      },
    }),
    [archiveName]: exactArtifactProof({
      artifactPath: archivePath,
      platform: 'windows',
      gateReceiptPath,
      payloads: {
        cli: expected.cli,
        wintun: expected.wintun,
      },
    }),
  }
}

function buildLinuxArtifacts({
  env,
  tag,
  dryRun,
  builtLines,
  candidateCommit,
  candidateTree,
  testedReceiptPath,
  testedPackageInstallReceiptPath,
  gatedBundlePathReceipt,
}) {
  if (!commandExists('docker')) {
    throw new SkipStepError('Skipping Linux artifacts because docker is not on PATH.')
  }

  const platform = env.NVPN_LINUX_DOCKER_PLATFORM || 'linux/amd64'
  const { linuxArchSuffix, muslTriple } = linuxReleaseTargetsForDockerPlatform(platform)
  if (platform !== 'linux/amd64') {
    throw new Error(
      'Public Linux artifacts require the exact x86_64 host bundle exercised by the Ubuntu VM gate.',
    )
  }
  const linuxDebName = `nostr-vpn-${tag}-linux-${linuxArchSuffix}.deb`

  let gatedBundle = ''
  let gateReceiptPath = ''
  let gateReceipt = null
  let packageInstallReceipt = null
  if (!dryRun) {
    if (!existsSync(gatedBundlePathReceipt)) {
      throw new Error(
        `Linux exact host-bundle path receipt is missing: ${gatedBundlePathReceipt}`,
      )
    }
    const bundleLines = readFileSync(gatedBundlePathReceipt, 'utf8')
      .split(/\r?\n/)
      .filter((line) => line.length > 0)
    if (bundleLines.length !== 1) {
      throw new Error(
        'Linux exact host-bundle path receipt must contain one path.',
      )
    }
    gatedBundle = bundleLines[0]
    if (
      resolve(gatedBundle) !== gatedBundle
      || !existsSync(gatedBundle)
      || lstatSync(gatedBundle).isSymbolicLink()
      || !statSync(gatedBundle).isDirectory()
    ) {
      throw new Error(
        'Linux exact host-bundle path receipt points to an invalid directory.',
      )
    }
    const bundleReceiptPath = join(gatedBundle, 'receipt.json')
    if (
      sha256FileSync(bundleReceiptPath)
      !== sha256FileSync(testedReceiptPath)
    ) {
      throw new Error(
        'Linux host bundle receipt differs from the exact bundle imported by the Ubuntu VM gate.',
      )
    }
    gateReceiptPath = testedReceiptPath
    gateReceipt = readRequiredJson(
      gateReceiptPath,
      'Linux exact-artifact gate receipt',
    )
    requireReceiptSource(gateReceipt, {
      commit: candidateCommit,
      tree: candidateTree,
      label: 'Linux exact-artifact gate receipt',
    })
    packageInstallReceipt = readRequiredJson(
      testedPackageInstallReceiptPath,
      'Linux exact Debian package install receipt',
    )
    const expectedBundleReceiptSha256 = sha256FileSync(testedReceiptPath)
    if (
      packageInstallReceipt.appGitSha !== candidateCommit
      || packageInstallReceipt.appGitTree !== candidateTree
      || packageInstallReceipt.packageInstalledByDpkg !== true
      || packageInstallReceipt.installedStatus !== 'installed'
      || packageInstallReceipt.bundleReceiptSha256
        !== expectedBundleReceiptSha256
    ) {
      throw new Error(
        'Linux Debian package install receipt differs from the exact release candidate.',
      )
    }
  }

  if (dryRun) {
    builtLines.push('Reused the exact gate-tested Linux x64 Debian package and static-musl CLI archive.')
    return {}
  }

  mkdirSync(distDir, { recursive: true })
  const debPath = join(distDir, linuxDebName)
  const cliAssets = [
    join(distDir, `nvpn-${muslTriple}.tar.gz`),
    join(distDir, `nvpn-${tag}-${muslTriple}.tar.gz`),
  ]
  const expectedApp = gateReceipt.artifacts?.app?.sha256
  const expectedCli = gateReceipt.artifacts?.cli?.sha256
  const expectedDeb = gateReceipt.artifacts?.debianPackage?.sha256
  const expectedDebSize = gateReceipt.artifacts?.debianPackage?.size
  const expectedMuslCli = gateReceipt.artifacts?.muslCli?.sha256
  const expectedMuslArchive = gateReceipt.artifacts?.muslCliArchive?.sha256
  const expectedMuslArchiveSize = gateReceipt.artifacts?.muslCliArchive?.size
  for (const [name, digest] of Object.entries({
    app: expectedApp,
    cli: expectedCli,
    debian_package: expectedDeb,
    musl_cli: expectedMuslCli,
    musl_archive: expectedMuslArchive,
  })) {
    if (!/^[0-9a-f]{64}$/.test(String(digest ?? ''))) {
      throw new Error(`Linux gate receipt lacks the ${name} payload hash.`)
    }
  }
  if (
    packageInstallReceipt.debSha256 !== expectedDeb
    || packageInstallReceipt.debSize !== expectedDebSize
    || packageInstallReceipt.muslCliSha256 !== expectedMuslCli
    || packageInstallReceipt.muslArchiveSha256 !== expectedMuslArchive
  ) {
    throw new Error(
      'Linux exact package-install receipt does not match the sealed host bundle.',
    )
  }
  const gatedDebPath = join(gatedBundle, 'nostr-vpn.deb')
  const gatedMuslArchivePath = join(
    gatedBundle,
    'nvpn-x86_64-unknown-linux-musl.tar.gz',
  )
  if (
    sha256FileSync(gatedDebPath) !== expectedDeb
    || statSync(gatedDebPath).size !== expectedDebSize
    || sha256FileSync(gatedMuslArchivePath) !== expectedMuslArchive
    || statSync(gatedMuslArchivePath).size !== expectedMuslArchiveSize
  ) {
    throw new Error(
      'Linux sealed publication artifacts changed after their Ubuntu VM gate.',
    )
  }
  copyFileSync(gatedDebPath, debPath)
  for (const cliAsset of cliAssets) {
    copyFileSync(gatedMuslArchivePath, cliAsset)
  }
  if (
    sha256FileSync(debPath) !== expectedDeb
    || statSync(debPath).size !== expectedDebSize
    || cliAssets.some(
      (path) =>
        sha256FileSync(path) !== expectedMuslArchive
        || statSync(path).size !== expectedMuslArchiveSize,
    )
  ) {
    throw new Error(
      'Linux publication copy differs from the exact Ubuntu VM-gated artifacts.',
    )
  }
  const proofs = {
    [basename(debPath)]: exactArtifactProof({
      artifactPath: debPath,
      platform: 'linux',
      gateReceiptPath: testedPackageInstallReceiptPath,
      payloads: {
        debian_package: expectedDeb,
        nostr_vpn: expectedApp,
        nvpn: expectedCli,
      },
    }),
  }
  for (const cliAsset of cliAssets) {
    proofs[basename(cliAsset)] = exactArtifactProof({
      artifactPath: cliAsset,
      platform: 'linux',
      gateReceiptPath,
      payloads: {
        musl_archive: expectedMuslArchive,
        nvpn_musl: expectedMuslCli,
      },
    })
  }
  builtLines.push('Reused the exact Linux x64 Debian package and static-musl CLI archive exercised by the Ubuntu VM gate.')
  return proofs
}

function ensureAndroidSdkEnv(env) {
  const updated = { ...env }
  if (!updated.ANDROID_SDK_ROOT) {
    const candidate = join(os.homedir(), 'Library', 'Android', 'sdk')
    if (existsSync(candidate)) {
      updated.ANDROID_SDK_ROOT = candidate
    }
  }
  if (!updated.ANDROID_HOME && updated.ANDROID_SDK_ROOT) {
    updated.ANDROID_HOME = updated.ANDROID_SDK_ROOT
  }
  if (!updated.ANDROID_NDK_HOME && updated.ANDROID_HOME) {
    const ndkRoot = join(updated.ANDROID_HOME, 'ndk')
    if (existsSync(ndkRoot)) {
      const versions = readdirSync(ndkRoot).sort((left, right) =>
        left.localeCompare(right, undefined, { numeric: true }),
      )
      const latest = versions.at(-1)
      if (latest) {
        updated.ANDROID_NDK_HOME = join(ndkRoot, latest)
      }
    }
  }
  if (!updated.NDK_HOME && updated.ANDROID_NDK_HOME) {
    updated.NDK_HOME = updated.ANDROID_NDK_HOME
  }
  return updated
}

function findAndroidBuildTool(env, toolName) {
  const sdkRoot = env.ANDROID_SDK_ROOT || env.ANDROID_HOME
  if (!sdkRoot) {
    return null
  }
  const buildToolsRoot = join(sdkRoot, 'build-tools')
  if (!existsSync(buildToolsRoot)) {
    return null
  }
  const versions = readdirSync(buildToolsRoot).sort((left, right) =>
    left.localeCompare(right, undefined, { numeric: true }),
  )
  for (const version of versions.reverse()) {
    const candidate = join(buildToolsRoot, version, toolName)
    if (existsSync(candidate)) {
      return candidate
    }
  }
  return null
}

function androidSigningIsComplete(env) {
  return Boolean(
    env.ANDROID_KEYSTORE_PATH &&
      env.ANDROID_KEYSTORE_PASSWORD &&
      env.ANDROID_KEY_ALIAS &&
      env.ANDROID_KEY_PASSWORD,
  )
}

function buildAndroidArtifacts({
  env,
  tag,
  dryRun,
  builtLines,
  gateReceiptPath,
  candidateCommit,
  candidateTree,
}) {
  const androidEnv = ensureAndroidSdkEnv(env)
  const sdkRoot = androidEnv.ANDROID_SDK_ROOT || androidEnv.ANDROID_HOME
  if (!sdkRoot) {
    throw new SkipStepError('Skipping Android artifacts because ANDROID_SDK_ROOT/ANDROID_HOME is not configured.')
  }
  if (!commandExists('cargo-ndk')) {
    throw new SkipStepError('Skipping Android artifacts because cargo-ndk is not on PATH.')
  }

  const installedTargets = run('rustup', ['target', 'list', '--installed'], {
    capture: true,
    dryRun,
  })
  if (!installedTargets.includes('aarch64-linux-android')) {
    run('rustup', ['target', 'add', 'aarch64-linux-android'], { dryRun })
  }

  const tempRoot = dryRun ? null : mkdtempSync(join(os.tmpdir(), 'nvpn-android-release-'))
  let wroteTempKeystore = false
  try {
    if (!androidEnv.ANDROID_KEYSTORE_PATH && androidEnv.ANDROID_KEYSTORE_B64 && tempRoot) {
      androidEnv.ANDROID_KEYSTORE_PATH = join(tempRoot, 'upload-keystore.jks')
      writeFileSync(androidEnv.ANDROID_KEYSTORE_PATH, Buffer.from(androidEnv.ANDROID_KEYSTORE_B64, 'base64'))
      wroteTempKeystore = true
    }

    const signed = androidSigningIsComplete(androidEnv)
    if (!signed && !envFlagEnabled(androidEnv.NVPN_ALLOW_UNSIGNED_ANDROID)) {
      throw new Error(
        'Android release signing is not configured. Set ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD, or set NVPN_ALLOW_UNSIGNED_ANDROID=1 for an explicitly unsigned dev artifact.',
      )
    }

    // The release gate built the Play AAB first, derived the installable APK
    // from it with pinned bundletool, and physically exercised that APK.
    // Reuse both sealed artifacts; rebuilding either here would break the
    // relationship proven on the Pixel.
    const testedApkPath = join(
      repoRoot,
      'android',
      'app',
      'build',
      'outputs',
      'apk',
      'release',
      'app-release.apk',
    )
    const bundleReceiptPath = join(
      repoRoot,
      'android',
      'app',
      'build',
      'outputs',
      'bundle',
      'release',
      'physical-gate-artifact.json',
    )
    const aabPath = findFirstFile(
      join(repoRoot, 'android', 'app', 'build', 'outputs', 'bundle', 'release'),
      (entry) => entry.endsWith('.aab'),
    )
    if (
      !dryRun
      && (
        !existsSync(testedApkPath)
        || !aabPath
        || !existsSync(bundleReceiptPath)
      )
    ) {
      throw new Error(
        'Expected gate-tested AAB-derived Android APK and signed AAB were not produced.',
      )
    }

    const apkDest = join(distDir, androidReleaseAssetName(tag, { extension: 'apk', signed }))
    const aabDest = join(distDir, androidReleaseAssetName(tag, { extension: 'aab', signed }))
    let gate
    if (!dryRun) {
      if (!gateReceiptPath || !existsSync(gateReceiptPath)) {
        throw new Error(
          'Physical Android release-gate receipt is missing; refusing to publish an untested APK.',
        )
      }
      let receipt
      try {
        receipt = JSON.parse(readFileSync(gateReceiptPath, 'utf8'))
      } catch {
        throw new Error('Physical Android release-gate receipt is not valid JSON.')
      }
      let bundleReceipt
      try {
        bundleReceipt = JSON.parse(readFileSync(bundleReceiptPath, 'utf8'))
      } catch {
        throw new Error('Android AAB-derived APK receipt is not valid JSON.')
      }
      const aabSha256 = sha256FileSync(aabPath)
      const apkSha256 = sha256FileSync(testedApkPath)
      if (
        sha256FileSync(bundleReceiptPath) !== receipt.bundleReceiptSha256
        || bundleReceipt.schema !== 1
        || bundleReceipt.relationship
          !== 'universal-apk-derived-from-exact-aab'
        || bundleReceipt.appGitSha !== candidateCommit
        || bundleReceipt.appGitTree !== candidateTree
        || bundleReceipt.aabSha256 !== aabSha256
        || bundleReceipt.apkSha256 !== apkSha256
        || bundleReceipt.aabPathSha256 !== pathSha256(aabPath)
        || bundleReceipt.apkPathSha256 !== pathSha256(testedApkPath)
      ) {
        throw new Error(
          'Android APK/AAB bytes differ from the bundle relationship sealed by the physical gate.',
        )
      }
      gate = validateAndroidReleaseGateReceipt(receipt, {
        apkSha256,
        aabSha256,
        apkPathSha256: pathSha256(testedApkPath),
        expectedAppGitSha: candidateCommit,
        expectedAppGitTree: candidateTree,
        expectedPackage:
          String(androidEnv.NVPN_ANDROID_PACKAGE_ID || '').trim()
          || 'fi.siriusbusiness.nvpn',
      })
      mkdirSync(distDir, { recursive: true })
      copyFileSync(testedApkPath, apkDest)
      copyFileSync(aabPath, aabDest)
      if (sha256FileSync(apkDest) !== gate.apkSha256) {
        throw new Error('Copied Android release APK differs from the physical-gate artifact.')
      }
      if (sha256FileSync(aabDest) !== gate.aabSha256) {
        throw new Error('Copied Android Play AAB differs from the physical-gate artifact.')
      }
    }

    if (signed) {
      const apksigner = findAndroidBuildTool(androidEnv, 'apksigner')
      if (apksigner) {
        run(apksigner, ['verify', '--verbose', apkDest], { dryRun })
      }
    }

    builtLines.push(
      signed
        ? 'Reused the signed Play AAB and its physical-gate-sealed bundletool-derived APK.'
        : 'Reused the Play AAB and its physical-gate-sealed bundletool-derived APK.',
    )
    if (dryRun) {
      return { gate: null, proofs: {} }
    }
    const runtimePayloads = androidRuntimePayloads(apkDest, aabDest)
    return {
      gate,
      proofs: {
        [basename(apkDest)]: exactArtifactProof({
          artifactPath: apkDest,
          platform: 'android',
          gateReceiptPath,
          payloads: runtimePayloads,
        }),
        [basename(aabDest)]: exactArtifactProof({
          artifactPath: aabDest,
          platform: 'android',
          gateReceiptPath,
          payloads: runtimePayloads,
        }),
      },
    }
  } finally {
    if (wroteTempKeystore && androidEnv.ANDROID_KEYSTORE_PATH) {
      rmSync(androidEnv.ANDROID_KEYSTORE_PATH, { force: true })
    }
    if (tempRoot) {
      rmSync(tempRoot, { recursive: true, force: true })
    }
  }
}

function buildMacosArtifacts({
  tag,
  dryRun,
  builtLines,
  candidateCommit,
  candidateTree,
  gateReceiptPath,
  gatedAppPath,
}) {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    throw new SkipStepError('Skipping macOS artifacts because the host is not Apple Silicon macOS.')
  }

  const env = {
    ...process.env,
    NVPN_MACOS_CARGO_TARGET_DIR: macosCargoTargetDir(process.env),
    NVPN_MACOS_RUST_PROFILE: 'release',
    NVPN_MACOS_XCODE_CONFIGURATION: 'Release',
    NVPN_MACOS_RUST_TARGETS: 'aarch64-apple-darwin',
    NVPN_RELEASE_TAG: tag,
    NVPN_MACOS_REQUIRE_SIGNING: '1',
    NVPN_MACOS_REQUIRE_NOTARIZATION: '1',
  }
  if (!dryRun) {
    rmSync(join(distDir, `nostr-vpn-${tag}-macos-arm64.zip`), { force: true })
    readRequiredJson(gateReceiptPath, 'macOS exact-artifact gate receipt')
    if (!existsSync(gatedAppPath)) {
      throw new Error(
        `Gate-tested macOS Release app is missing: ${gatedAppPath}`,
      )
    }
    const releaseApp = join(distDir, 'macos', 'Nostr VPN.app')
    rmSync(releaseApp, { recursive: true, force: true })
    mkdirSync(dirname(releaseApp), { recursive: true })
    run('ditto', [gatedAppPath, releaseApp])
    run(
      'python3',
      [
        join(repoRoot, 'scripts', 'macos_release_join_artifact.py'),
        'validate-published-app',
        '--receipt',
        gateReceiptPath,
        '--app',
        releaseApp,
        '--expected-app-head',
        candidateCommit,
        '--expected-app-tree',
        candidateTree,
        '--require-gate-bundle-tree',
      ],
    )
  }
  run(
    'bash',
    [join(repoRoot, 'scripts', 'macos-build'), 'macos-release-artifacts'],
    {
      env: {
        ...env,
        NVPN_MACOS_FORCE_REBUILD_APP: '0',
      },
      dryRun,
    },
  )

  const gatedCli = join(
    gatedAppPath,
    'Contents',
    'Resources',
    'binaries',
    'nvpn',
  )
  const cliAssets = packageUnixCliTarball({
    binaryPath: gatedCli,
    targetTriple: 'aarch64-apple-darwin',
    tag,
    dryRun,
  })
  if (dryRun) {
    builtLines.push('Reused the gate-tested Apple Silicon CLI.')
    builtLines.push('Packaged the gate-tested signed macOS app for notarized distribution.')
    return {}
  }

  const receipt = readRequiredJson(
    gateReceiptPath,
    'macOS exact-artifact gate receipt',
  )
  const releaseApp = join(distDir, 'macos', 'Nostr VPN.app')
  const updater = join(
    distDir,
    `nostr-vpn-${tag}-macos-arm64.app.tar.gz`,
  )
  const dmg = join(distDir, `nostr-vpn-${tag}-macos-arm64.dmg`)
  run(
    'bash',
    [
      join(repoRoot, 'scripts', 'verify-macos-release-publication-artifacts.sh'),
      gateReceiptPath,
      releaseApp,
      updater,
      dmg,
      candidateCommit,
      candidateTree,
      join(repoRoot, 'scripts', 'macos_release_join_artifact.py'),
    ],
  )

  const appPayload = {
    app_executable: receipt.appExecutableSha256,
  }
  const cliPayloadSha256 = sha256FileSync(gatedCli)
  const proofs = {
    [basename(dmg)]: exactArtifactProof({
      artifactPath: dmg,
      platform: 'macos',
      gateReceiptPath,
      payloads: appPayload,
    }),
    [basename(updater)]: exactArtifactProof({
      artifactPath: updater,
      platform: 'macos',
      gateReceiptPath,
      payloads: appPayload,
    }),
  }
  for (const cliAsset of cliAssets) {
    const packagedCliSha256 = commandOutputSha256(
      'tar',
      ['-xOf', cliAsset, 'nvpn/nvpn'],
    )
    if (packagedCliSha256 !== cliPayloadSha256) {
      throw new Error(
        `macOS CLI archive ${basename(cliAsset)} differs from the gate-tested app payload.`,
      )
    }
    proofs[basename(cliAsset)] = exactArtifactProof({
      artifactPath: cliAsset,
      platform: 'macos',
      gateReceiptPath,
      payloads: { nvpn: cliPayloadSha256 },
    })
  }
  builtLines.push('Built Apple Silicon CLI locally.')
  builtLines.push('Packaged the gate-tested signed and notarized Apple Silicon app.')
  return proofs
}

function buildIosArtifacts({
  tag,
  dryRun,
  builtLines,
  releaseGateLogDir,
}) {
  if (process.platform !== 'darwin') {
    throw new SkipStepError('Skipping iOS artifacts because the host is not macOS.')
  }
  const env = {
    ...process.env,
    NVPN_RELEASE_TAG: tag,
    NVPN_IOS_INTERNAL_ONLY: 'false',
    NVPN_RELEASE_IOS_FROZEN_ARCHIVE: '1',
    NVPN_RELEASE_GATE_LOG_DIR: releaseGateLogDir,
  }
  // The release gate already created and physically tested one frozen archive.
  // This command refuses to archive: it verifies the gate seal, exports that
  // same xcarchive for App Store Connect, uploads its exact receipt-bound IPA,
  // and attaches the build to the internal TestFlight group.
  run('bash', [join(repoRoot, 'scripts', 'ios-build'), 'ios-testflight'], { env, dryRun })
  builtLines.push(`Uploaded iOS ${tag} to App Store Connect (TestFlight/App Store eligible).`)
}

/**
 * Sync platform-native version metadata (xcodeproj MARKETING_VERSION, Android
 * versionName/versionCode, linux crate's [package].version) to the Cargo
 * workspace version. The GUIs themselves read versions through the FFI's
 * CARGO_PKG_VERSION fallback, but the OS-level metadata (Finder Get Info,
 * About panel, Play Store) needs these bumped before each release.
 */
function syncPlatformVersions({ env, tag, dryRun, builtLines }) {
  const targets = [
    { path: join(repoRoot, 'macos', 'NostrVpnMac.xcodeproj', 'project.pbxproj'), bump: bumpPbxprojMarketingVersion },
    { path: join(repoRoot, 'ios', 'NostrVpnIos.xcodeproj', 'project.pbxproj'), bump: bumpPbxprojMarketingVersion },
    {
      path: join(repoRoot, 'android', 'app', 'build.gradle.kts'),
      bump: (text, version) =>
        bumpAndroidGradleVersion(text, version, {
          versionCode: env.NVPN_ANDROID_VERSION_CODE,
        }),
    },
    { path: join(repoRoot, 'linux', 'Cargo.toml'), bump: bumpCargoPackageVersion },
  ]
  const updated = []
  for (const { path, bump } of targets) {
    if (!existsSync(path)) {
      continue
    }
    const original = readFileSync(path, 'utf8')
    const next = bump(original, tag)
    if (next === original) {
      continue
    }
    if (!dryRun) {
      writeFileSync(path, next)
    }
    updated.push(path.replace(`${repoRoot}/`, ''))
  }
  if (updated.length > 0) {
    builtLines.push(`Synced platform versions to ${tag}: ${updated.join(', ')}.`)
  } else {
    builtLines.push(`Platform versions already at ${tag}.`)
  }
}

function runVerify({ dryRun, builtLines, releaseGateLogDir, tag }) {
  const env = {
    ...process.env,
    NVPN_RELEASE_GATE_LOG_DIR: releaseGateLogDir,
    NVPN_RELEASE_GATE_MOBILE_WG_EXIT_E2E: '1',
    NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E: '1',
    NVPN_RELEASE_GATE_MOBILE_JOIN_E2E: '1',
    NVPN_RELEASE_GATE_ANDROID_LEGACY_REPLACEMENT_E2E: '1',
    NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E: '1',
    NVPN_RELEASE_GATE_WINDOWS_GUI_SMOKE: '1',
    NVPN_RELEASE_GATE_WINDOWS_MANUAL_JOIN_UI_E2E: '1',
    NVPN_RELEASE_GATE_WINDOWS_DNS_UI_E2E: '1',
    NVPN_RELEASE_GATE_WINDOWS_SERVICE_TOGGLE_E2E: '1',
    NVPN_RELEASE_GATE_WINDOWS_UNDERLAY_NETWORK_CHANGE_E2E: '1',
    NVPN_RELEASE_GATE_WINDOWS_MOBILE_JOIN_E2E: '1',
    NVPN_WINDOWS_APP_SMOKE_TAG: tag,
    NVPN_RELEASE_GATE_MACOS_MANUAL_JOIN_UI_E2E: '1',
    NVPN_RELEASE_GATE_MACOS_DNS_UI_E2E: '1',
    NVPN_RELEASE_GATE_MACOS_SERVICE_TOGGLE_E2E: '1',
    NVPN_RELEASE_GATE_MACOS_GUI_SMOKE: '1',
    NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU: '1',
    NVPN_RELEASE_GATE_LINUX_MANUAL_JOIN_UI_E2E: '1',
    NVPN_RELEASE_GATE_LINUX_DNS_UI_E2E: '1',
    NVPN_RELEASE_GATE_LINUX_SERVICE_TOGGLE_E2E: '1',
    NVPN_RELEASE_GATE_LINUX_UNDERLAY_NETWORK_CHANGE_E2E: '1',
    NVPN_RELEASE_GATE_LINUX_MOBILE_JOIN_E2E: '1',
    NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E: '1',
    NVPN_RELEASE_IOS_FROZEN_ARCHIVE: '1',
  }
  run('./scripts/release-gate.sh', [], { env, dryRun })
  builtLines.push('Ran release gate: sync-versions, fmt, clippy, tests, FIPS Docker e2e, WireGuard exit Docker/platform e2e, real Android/iOS physical underlay changes, real Windows/Linux desktop underlay changes, isolated macOS VM network/service proofs, and desktop launch smokes.')
}

function buildStartosArtifacts({
  tag,
  dryRun,
  builtLines,
  releaseGateSummaryPath,
}) {
  run(
    'node',
    [
      join(repoRoot, 'scripts', 'startos-release.mjs'),
      '--tag',
      tag,
      '--output-dir',
      distDir,
    ],
    { dryRun },
  )
  builtLines.push('Built signed StartOS packages for x86_64 and aarch64.')
  if (dryRun) {
    return {}
  }
  const proofs = {}
  for (const arch of ['x86_64', 'aarch64']) {
    const path = join(
      distDir,
      `nostr-vpn-${tag}-startos-${arch}.s9pk`,
    )
    const digest = sha256FileSync(path)
    const inspection = inspectStartosReleasePackage({
      packagePath: path,
      arch,
      tag,
    })
    proofs[basename(path)] = exactArtifactProof({
      artifactPath: path,
      platform: 'startos',
      gateReceiptPath: releaseGateSummaryPath,
      verification: 'post-build-exact-package-gate',
      postBuildValidator: startosExactPackageValidator,
      payloads: {
        manifest_json: inspection.manifestSha256,
        package: digest,
      },
    })
  }
  return proofs
}

function shouldRunStep(step, options) {
  if (options.skipVerify && step === 'verify') {
    return false
  }
  if (options.only && !options.only.has(step)) {
    return false
  }
  return !options.skip.has(step)
}

function collectReleaseAssetPaths(tag) {
  if (!existsSync(distDir)) {
    return []
  }

  const versionedNames = new Set(
    readdirSync(distDir).filter((entry) => entry.includes(`-${tag}-`) || entry.includes(`${tag}-`)),
  )
  const paths = []

  for (const entry of readdirSync(distDir).sort()) {
    if (entry === `nostr-vpn-${tag}-macos-arm64.zip`) {
      continue
    }
    const fullPath = join(distDir, entry)
    if (!statSync(fullPath).isFile()) {
      continue
    }
    if (entry.includes(tag)) {
      paths.push(fullPath)
      continue
    }
    const companionPattern = versionlessCliAssets.get(entry)
    if (companionPattern && versionedNames.has(companionPattern.replace('{tag}', tag))) {
      paths.push(fullPath)
    }
  }

  return paths
}

function writeReleaseNotes({ tag, commit, stageDir, builtLines, skippedLines, dryRun }) {
  const args = [
    join(repoRoot, 'scripts', 'render-release-notes.mjs'),
    '--tag',
    tag,
    '--commit',
    commit,
    '--asset-dir',
    join(stageDir, 'assets'),
    '--changelog',
    changelogPath,
    '--out',
    join(stageDir, 'notes.md'),
  ]

  for (const line of builtLines) {
    args.push('--built-line', line)
  }
  for (const line of skippedLines) {
    args.push('--skipped-line', line)
  }

  run('node', args, { dryRun })
}

function stageRelease({
  tag,
  commit,
  tree,
  stageDir,
  builtLines,
  skippedLines,
  dryRun,
  requireCompleteAppRelease,
  draft,
  androidReleaseGate,
  releaseGateEvidence,
  artifactProofs,
}) {
  const assetPaths = collectReleaseAssetPaths(tag)
  const assetNames = assetPaths.map((assetPath) => basename(assetPath))
  validateReleaseAssetSet(assetNames, { requireCompleteAppRelease })

  if (dryRun) {
    console.log(`Would stage ${assetPaths.length} currently visible asset(s) into ${stageDir}`)
    return {
      assetPaths,
      stageDir,
      stagedAndroidApkPath: join(
        stageDir,
        'assets',
        androidReleaseAssetName(tag),
      ),
    }
  }

  if (assetPaths.length === 0) {
    throw new Error(`No dist assets found for ${tag}.`)
  }

  rmSync(stageDir, { recursive: true, force: true })
  mkdirSync(join(stageDir, 'assets'), { recursive: true })

  const stagedAssetPaths = []
  for (const assetPath of assetPaths) {
    const stagedPath = join(stageDir, 'assets', basename(assetPath))
    copyFileSync(assetPath, stagedPath)
    stagedAssetPaths.push(stagedPath)
  }

  let androidGateManifest = null
  let stagedAndroidApkPath = null
  if (androidReleaseGate) {
    const apkName = androidReleaseAssetName(tag)
    stagedAndroidApkPath = join(stageDir, 'assets', apkName)
    if (!existsSync(stagedAndroidApkPath)) {
      throw new Error(`Physical-gate Android APK is missing from the staged release: ${apkName}`)
    }
    if (
      androidReleaseGate.appGitSha !== commit
      || sha256FileSync(stagedAndroidApkPath) !== androidReleaseGate.apkSha256
    ) {
      throw new Error('Physical Android gate provenance does not match the staged source and APK.')
    }
    androidGateManifest = {
      receipt_schema: androidReleaseGate.receiptSchema,
      apk_path: `assets/${apkName}`,
      apk_sha256: androidReleaseGate.apkSha256,
      app_git_sha: androidReleaseGate.appGitSha,
      app_git_tree: androidReleaseGate.appGitTree,
      package: androidReleaseGate.package,
      signer_certificate_sha256: androidReleaseGate.signerCertificateSha256,
    }
  } else if (requireCompleteAppRelease) {
    throw new Error(
      'Complete release staging requires physical Android gate provenance.',
    )
  }

  const createdAt = Math.floor(Date.now() / 1000)
  const manifest = buildReleaseManifest({
    tag,
    commit,
    createdAt,
    assetPaths: stagedAssetPaths,
    draft,
    androidReleaseGate: androidGateManifest,
  })
  if (requireCompleteAppRelease) {
    if (!releaseGateEvidence) {
      throw new Error(
        'Complete release staging requires the real platform-gate evidence.',
      )
    }
    manifest.release_gate_attestation = buildReleaseGateAttestation({
      commit,
      tree,
      assets: manifest.assets,
      assetProofs: Object.fromEntries(
        manifest.assets.map((asset) => {
          const proof = artifactProofs?.[asset.name]
          if (!proof) {
            throw new Error(
              `Release asset ${asset.name} has no exact platform-gate proof.`,
            )
          }
          return [asset.path, proof]
        }),
      ),
      ...releaseGateEvidence,
    })
  }

  for (const [fileName, text] of buildReleaseManifestFiles(manifest)) {
    writeFileSync(join(stageDir, fileName), text)
  }
  writeReleaseNotes({ tag, commit, stageDir, builtLines, skippedLines, dryRun })
  validateStagedReleaseTree(stageDir, manifest)

  return { assetPaths, stageDir, stagedAndroidApkPath }
}

function publishRelease({ stageDir, releaseTree, tag, draft, dryRun }) {
  if (dryRun) {
    console.log(`Would publish ${tag} from ${stageDir} into ${releaseTree}`)
    return 'dry-run'
  }

  const manifest = readReleaseManifest(stageDir)
  if (!draft) {
    validatePromotableReleaseManifest(manifest)
  }
  const addOutput = run('htree', ['add', stageDir], { capture: true, dryRun })
  const match = addOutput.match(/^\s*url:\s*(\S+)/m)
  if (!match) {
    throw new Error('Could not parse htree add output for release CID.')
  }

  const cid = match[1]
  run('htree', ['push', '--force', cid], { dryRun })
  verifyHtreeReleaseCid({ cid, manifest, dryRun })
  const args = ['release', 'publish', releaseTree, tag, cid]
  if (draft) {
    args.push('--draft')
  }
  run('htree', args, { dryRun })
  return cid
}

function promoteStagedDraft({ stageDir, releaseTree, tag, dryRun }) {
  if (dryRun) {
    console.log(`Would promote staged draft ${tag} from ${stageDir} into ${releaseTree}`)
    return {
      cid: 'dry-run',
      stagedAndroidApkPath: join(
        stageDir,
        'assets',
        androidReleaseAssetName(tag),
      ),
    }
  }

  const releaseJsonPath = join(stageDir, 'release.json')
  const manifestJsonPath = join(stageDir, 'manifest.json')
  const stagedManifest = readReleaseManifest(stageDir)
  validatePromotableReleaseManifest(stagedManifest)
  assertPromotableDraftSource(tag, stagedManifest)
  const stagedAndroidApkPath = join(
    stageDir,
    stagedManifest.android_release_gate.apk_path,
  )

  const publishedAt = Math.floor(Date.now() / 1000)
  for (const path of [releaseJsonPath, manifestJsonPath]) {
    const manifest = JSON.parse(readFileSync(path, 'utf8'))
    manifest.draft = false
    manifest.published_at = publishedAt
    writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`)
  }
  readReleaseManifest(stageDir)

  return {
    cid: publishRelease({ stageDir, releaseTree, tag, draft: false, dryRun }),
    stagedAndroidApkPath,
  }
}

function publishRustCrates({ dryRun }) {
  const script = join(repoRoot, 'scripts', 'publish.sh')
  run('bash', dryRun ? [script, '--dry-run'] : [script], { dryRun })
}

function zapstorePublicationContext(env) {
  const signWith = resolveZapstoreSignWith(env)
  const zapstoreYaml = join(repoRoot, 'zapstore.yaml')
  const configExists = existsSync(zapstoreYaml)
  const zapstoreConfig = configExists ? readFileSync(zapstoreYaml, 'utf8') : ''
  const publisherNpub = (
    zapstoreConfig.match(/^\s*pubkey:\s*(\S+)\s*$/m)?.[1] || ''
  ).trim()
  const relayUrls = String(
    env.RELAY_URLS || 'wss://relay.zapstore.dev',
  )
    .split(/[,\s]+/)
    .map((value) => value.trim())
    .filter(Boolean)

  return {
    configExists,
    publisherNpub,
    relayUrls,
    signWith,
    zapstoreYaml,
  }
}

function preflightRequiredZapstorePublication({
  env,
  requireApk = false,
  apkPath = '',
}) {
  const {
    configExists,
    publisherNpub,
    relayUrls,
    signWith,
  } = zapstorePublicationContext(env)
  zapstorePublicationPrerequisites(
    {
      apk: !requireApk || Boolean(apkPath && existsSync(apkPath)),
      zsp: commandExists('zsp'),
      nak: commandExists('nak'),
      signing: Boolean(signWith),
      config: configExists,
      publisher: Boolean(publisherNpub),
      relays: relayUrls.length > 0,
    },
    { required: true },
  )
  const publisherPubkey = run('nak', ['decode', publisherNpub], {
    capture: true,
  }).trim()
  if (!/^[0-9a-f]{64}$/i.test(publisherPubkey)) {
    throw new Error('zapstore.yaml publisher pubkey could not be decoded.')
  }
}

/**
 * Publish the Android APK for this release to Zapstore.
 *
 * Zapstore signs and uploads kind-32267 app + kind-30063 release events to
 * relay.zapstore.dev so users on Android with a Zapstore client can discover
 * + auto-update. The APK is the immutable staged copy bound to the physical
 * gate receipt — Zapstore needs the actual .apk file, not the .aab.
 *
 * Optional mode soft-skips with a warning instead of aborting when:
 *   - `zsp` is not on PATH (zapstore CLI not installed yet on this host)
 *   - No Nostr signing key is configured (`SIGN_WITH` env or
 *     `NOSTR_KEY_PATH` from .env.zapstore.local)
 *   - The staged, receipt-bound APK doesn't exist
 *
 * Required mode hard-fails on every missing prerequisite and unless the
 * published release is verifiably current after zsp returns.
 */
function publishZapstore({
  env,
  tag,
  apkPath,
  dryRun,
  required = false,
}) {
  const apkName = `nostr-vpn-${tag}-android-arm64.apk`
  if (!apkPath) {
    throw new Error('Zapstore publication requires an explicit staged Android APK.')
  }
  if (dryRun) {
    console.log(
      `Would ${required ? 'require, publish, and verify' : 'publish'} ${apkName} on Zapstore`,
    )
    return
  }

  const {
    configExists,
    publisherNpub,
    relayUrls,
    signWith,
    zapstoreYaml,
  } = zapstorePublicationContext(env)

  const prerequisites = zapstorePublicationPrerequisites(
    {
      apk: existsSync(apkPath),
      zsp: commandExists('zsp'),
      nak: commandExists('nak'),
      signing: Boolean(signWith),
      config: configExists,
      publisher: Boolean(publisherNpub),
      relays: relayUrls.length > 0,
    },
    { required },
  )
  if (!prerequisites.available) {
    console.warn(
      `Skipping Zapstore publish: missing ${prerequisites.missing.join(', ')}.`,
    )
    return
  }
  const publisherPubkey = run('nak', ['decode', publisherNpub], {
    capture: true,
  }).trim()
  if (!/^[0-9a-f]{64}$/i.test(publisherPubkey)) {
    throw new Error('zapstore.yaml publisher pubkey could not be decoded.')
  }

  const inspectionDir = mkdtempSync(join(os.tmpdir(), 'nvpn-zapstore-apk-'))
  const inspectionApk = join(inspectionDir, apkName)
  let apkMetadata
  try {
    copyFileSync(apkPath, inspectionApk)
    const metadataOutput = run('zsp', ['utils', 'extract-apk', inspectionApk], {
      capture: true,
    })
    try {
      apkMetadata = JSON.parse(metadataOutput)
    } catch {
      throw new Error('zsp APK inspection did not return valid JSON.')
    }
  } finally {
    rmSync(inspectionDir, { recursive: true, force: true })
  }
  const expectedVersion = semverFromTag(tag)
  const androidGradle = readFileSync(
    join(repoRoot, 'android', 'app', 'build.gradle.kts'),
    'utf8',
  )
  const expectedVersionCode = Number(
    String(env.NVPN_ANDROID_VERSION_CODE || '').trim()
      || androidGradle.match(/\bversionCode\s*=\s*(\d+)/)?.[1]
      || '',
  )
  const expectedPackageId =
    String(env.NVPN_ANDROID_PACKAGE_ID || '').trim() || 'fi.siriusbusiness.nvpn'
  const validatedApk = validateZapstoreApkMetadata(apkMetadata, {
    expectedVersion,
    expectedVersionCode,
    expectedPackageId,
  })
  if (validatedApk.sha256 !== sha256FileSync(apkPath)) {
    throw new Error('Zapstore inspection hash differs from the staged Android APK.')
  }

  // Pass `zapstore.yaml` (not the APK path) so the kind-32267 app event
  // carries the yaml's `name`, `summary`, `description`, `icon`, `tags`,
  // `license`, `repository` (iris.to), and `url` — passing an APK file
  // directly produces a bare event with just package id + name + arch.
  //
  // zsp's `release_source` glob is set to a stable filename, so copy this
  // release's APK there. Without a stable name, the glob would pick a
  // random (often legacy 0.3.x with an old package id)
  // APK out of `dist/`.
  const stableApkPath = join(distDir, 'zapstore-current-android-arm64.apk')
  copyFileSync(apkPath, stableApkPath)
  run(
    'zsp',
    ['publish', '--quiet', '--check', zapstoreYaml],
    { capture: true },
  )

  run(
    'zsp',
    [
      'publish',
      '--quiet',
      '--skip-preview',
      '--overwrite-release',
      zapstoreYaml,
    ],
    {
      env: { ...process.env, ...env, SIGN_WITH: signWith },
    },
  )

  let lastVerificationError = new Error('Zapstore release verification did not run.')
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    try {
      const query = (kind, filters) => {
        const output = run(
          'nak',
          [
            'req',
            '-k',
            String(kind),
            '-a',
            publisherNpub,
            ...filters,
            '-l',
            '20',
            ...relayUrls,
          ],
          { capture: true },
        )
        return output
          .split(/\r?\n/)
          .map((line) => line.trim())
          .filter(Boolean)
          .map((line) => {
            try {
              return JSON.parse(line)
            } catch {
              throw new Error('Zapstore relay query returned invalid event JSON.')
            }
          })
      }
      const publication = validateZapstoreRelayPublication({
        appEvents: query(32267, ['-d', validatedApk.packageId]),
        releaseEvents: query(30063, [
          '-d',
          `${validatedApk.packageId}@${validatedApk.versionName}`,
        ]),
        assetEvents: query(3063, [
          '-t',
          `i=${validatedApk.packageId}`,
          '-t',
          `version=${validatedApk.versionName}`,
        ]),
        expected: {
          pubkey: publisherPubkey,
          packageId: validatedApk.packageId,
          versionName: validatedApk.versionName,
          versionCode: validatedApk.versionCode,
          sha256: validatedApk.sha256,
          certificateFingerprint: validatedApk.certificateFingerprint,
        },
      })
      for (const event of Object.values(publication)) {
        run('nak', ['verify'], {
          capture: true,
          input: `${JSON.stringify(event)}\n`,
        })
      }
      console.log(
        `Verified Zapstore ${validatedApk.packageId} ${validatedApk.versionName} (${validatedApk.versionCode}) is current.`,
      )
      return
    } catch (error) {
      lastVerificationError =
        error instanceof Error ? error : new Error(String(error))
      if (attempt < 8) {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2_000)
      }
    }
  }
  throw new Error(
    `Zapstore publication completed but verification failed: ${lastVerificationError.message}`,
  )
}

function resolveZapstoreSignWith(env) {
  const fromEnv = (process.env.SIGN_WITH ?? env.SIGN_WITH ?? '').trim()
  if (fromEnv) {
    return fromEnv
  }

  const keyPath = (process.env.NOSTR_KEY_PATH ?? env.NOSTR_KEY_PATH ?? '').trim()
  if (keyPath && existsSync(keyPath)) {
    return readFileSync(keyPath, 'utf8').trim()
  }
  return ''
}

function resolveReleaseCommit(tag, { dryRun = false } = {}) {
  const normalizedTag = normalizeTag(tag)
  if (dryRun) {
    return normalizedTag
  }

  const taggedResult = spawnSync('git', ['rev-parse', '-q', '--verify', `${normalizedTag}^{commit}`], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: 'pipe',
  })
  if (taggedResult.status === 0) {
    const taggedCommit = taggedResult.stdout.trim()
    if (taggedCommit) {
      return taggedCommit
    }
  }

  return run('git', ['rev-parse', 'HEAD'], { capture: true, dryRun }) || 'HEAD'
}

function main() {
  const options = parseArgs(process.argv.slice(2))
  const { loaded, loadedPaths } = readOptionalEnvFiles([...defaultEnvFiles, ...options.envFiles])
  const sourceDateEpoch = process.env.SOURCE_DATE_EPOCH || loaded.SOURCE_DATE_EPOCH || gitHeadEpoch() || '0'
  const env = deterministicBuildEnv({ ...loaded, ...process.env }, { sourceDateEpoch })
  Object.assign(process.env, env)

  const tag = options.tag || readWorkspaceVersionTag(readFileSync(rootCargoToml, 'utf8'))
  const releaseTree = options.releaseTree || env.NVPN_RELEASE_TREE || 'releases/nostr-vpn'
  const stageDir =
    options.stageDir || join(os.tmpdir(), `nostr-vpn-release-${tag.replace(/[^\w.-]/g, '_')}`)
  const releaseGateLogDir = resolve(
    env.NVPN_RELEASE_GATE_LOG_DIR
      || join(
        repoRoot,
        'artifacts',
        'release-gate-logs',
        `local-release-${tag.replace(/[^\w.-]/g, '_')}`,
      ),
  )
  const androidGateReceiptPath = join(
    releaseGateLogDir,
    'mobile-release-artifacts',
    'android.json',
  )
  const releaseGateSummaryPath = join(
    releaseGateLogDir,
    'release-gate-summary.json',
  )
  const releaseJoinResultDir = resolve(
    env.NVPN_RELEASE_JOIN_RESULT_DIR
      || join(repoRoot, 'artifacts', 'mobile-release-join'),
  )
  const platformReceiptPaths = {
    android: {
      physical: androidGateReceiptPath,
      mobile_join: join(releaseJoinResultDir, 'summary.json'),
      wireguard_dns: join(
        releaseGateLogDir,
        'mobile-network',
        'android-wireguard-dns.json',
      ),
      underlay_lifecycle: join(
        releaseGateLogDir,
        'mobile-network',
        'android-underlay-lifecycle.json',
      ),
      replacement_singleton: join(
        releaseGateLogDir,
        'mobile-network',
        'android-replacement-artifacts',
        'mobile-android-legacy-replacement.json',
      ),
    },
    ios: {
      frozen_archive: join(
        repoRoot,
        'dist',
        'ios',
        'frozen',
        'physical-gate-seal.json',
      ),
      mobile_artifact: join(
        repoRoot,
        'dist',
        'ios',
        'frozen',
        'physical-mobile-receipt.json',
      ),
      mobile_join: join(releaseJoinResultDir, 'summary.json'),
      wireguard_dns: join(
        releaseGateLogDir,
        'mobile-network',
        'ios-wireguard-dns.json',
      ),
      underlay_lifecycle: join(
        releaseGateLogDir,
        'mobile-network',
        'ios-underlay-lifecycle.json',
      ),
    },
    linux: {
      artifact: join(
        releaseJoinResultDir,
        'linux',
        'import',
        'host-bundle-receipt.json',
      ),
      public_ui_join: join(releaseJoinResultDir, 'linux', 'summary.json'),
      package_install: join(
        releaseJoinResultDir,
        'linux',
        'import',
        'debian-package-install.json',
      ),
      network: join(
        releaseGateLogDir,
        'desktop-network',
        'linux.json',
      ),
    },
    macos: {
      artifact: join(releaseJoinResultDir, 'macos', 'artifact.json'),
      public_ui_join: join(releaseJoinResultDir, 'macos', 'summary.json'),
      network: join(
        releaseGateLogDir,
        'desktop-network',
        'macos.json',
      ),
    },
    windows: {
      artifact: join(
        releaseJoinResultDir,
        'windows',
        'windows-release-artifact.json',
      ),
      installer: join(
        releaseGateLogDir,
        'windows-installer',
        'installer-receipt.json',
      ),
      public_ui_join: join(releaseJoinResultDir, 'windows', 'summary.json'),
      network: join(
        releaseGateLogDir,
        'desktop-network',
        'windows.json',
      ),
    },
  }
  const expectedStagedAndroidApkPath = join(
    stageDir,
    'assets',
    androidReleaseAssetName(tag),
  )
  const allowPartial = options.allowPartial || envFlagEnabled(env.NVPN_RELEASE_ALLOW_PARTIAL)
  const finalPublication = options.publish && !options.draft
  const requireZapstore = zapstorePublicationRequired({
    cliRequired: options.requireZapstore || finalPublication,
    envValue: env.NVPN_RELEASE_REQUIRE_ZAPSTORE,
  })
  const builtLines = []
  const skippedLines = []
  let androidReleaseGate = null
  let releaseGateCompleted = false
  let releaseGateEvidence = null
  const artifactProofs = {}

  if (requireZapstore && options.skipZapstore) {
    throw new Error('--require-zapstore conflicts with --skip-zapstore.')
  }
  if (finalPublication && !options.dryRun && allowPartial) {
    throw new Error('A final release cannot be published with partial platform artifacts.')
  }
  if (
    finalPublication
    && !options.dryRun
    && !options.promoteDraft
    && (options.only || options.skip.size > 0)
  ) {
    throw new Error(
      'A final release must run every platform step; --only and --skip are staging-only.',
    )
  }
  if (
    requireZapstore
    && !options.dryRun
    && (!options.publish || options.draft)
  ) {
    throw new Error(
      'Required Zapstore publication needs --final or --promote-draft.',
    )
  }

  console.log(`Release tag: ${tag}`)
  console.log(`Release tree: ${releaseTree}`)
  if (requireZapstore) {
    console.log('Zapstore publication and post-publish verification are required.')
  }
  if (loadedPaths.length > 0) {
    console.log(`Loaded env files: ${loadedPaths.join(', ')}`)
  }
  if (options.dryRun) {
    console.log('Dry run mode: no build, copy, or publish commands will be executed.')
  }
  if (options.promoteDraft) {
    console.log('Promote mode: reusing an existing staged draft and publishing it as final/latest.')
  } else if (options.publish && options.draft) {
    console.log('Draft mode: htree publish will repoint draft instead of latest, and crate/Zapstore publish steps are disabled.')
  }

  if (options.publish && !options.dryRun && !commandExists('htree')) {
    throw new Error('Missing htree; cannot publish release.')
  }
  if (requireZapstore && !options.dryRun) {
    preflightRequiredZapstorePublication({
      env,
      requireApk: options.promoteDraft,
      apkPath: options.promoteDraft ? expectedStagedAndroidApkPath : '',
    })
  }

  if (
    options.publish
    && !options.dryRun
    && (
      options.skipVerify
      || options.skip.has('verify')
      || (options.only && !options.only.has('verify'))
    )
  ) {
    throw new Error('Publishing a new release candidate cannot skip the required release gate.')
  }

  const candidateCommit =
    options.dryRun || options.promoteDraft
      ? ''
      : assertCleanReleaseSource(tag)
  const candidateTree =
    options.dryRun || options.promoteDraft
      ? ''
      : gitTree(candidateCommit)

  if (options.promoteDraft) {
    if (!commandExists('htree')) {
      throw new Error('Missing htree; cannot promote release.')
    }
    const promoted = promoteStagedDraft({
      stageDir,
      releaseTree,
      tag,
      dryRun: options.dryRun,
    })
    console.log(`Promoted ${tag} to ${releaseTree} via ${promoted.cid}`)
    if (options.cargoPublish || !options.skipCargoPublish) {
      publishRustCrates({ dryRun: options.dryRun })
    }
    if (!options.skipZapstore) {
      publishZapstore({
        env,
        tag,
        apkPath: promoted.stagedAndroidApkPath,
        dryRun: options.dryRun,
        required: requireZapstore,
      })
    }
    return
  }

  const steps = [
    ['platform-versions', () => syncPlatformVersions({
      env,
      tag,
      dryRun: options.dryRun,
      builtLines,
    })],
    ['verify', () => {
      runVerify({
        dryRun: options.dryRun,
        builtLines,
        releaseGateLogDir,
        tag,
      })
      releaseGateCompleted = true
      if (!options.dryRun && !allowPartial) {
        releaseGateEvidence = collectReleaseGateReceipts({
          commit: candidateCommit,
          tree: candidateTree,
          releaseGateSummaryPath,
          platformReceiptPaths,
        })
      }
    }],
    ['startos', () => mergeArtifactProofs(
      artifactProofs,
      buildStartosArtifacts({
        tag,
        dryRun: options.dryRun,
        builtLines,
        releaseGateSummaryPath,
      }),
    )],
    ['macos', () => mergeArtifactProofs(
      artifactProofs,
      buildMacosArtifacts({
        tag,
        dryRun: options.dryRun,
        builtLines,
        candidateCommit,
        candidateTree,
        gateReceiptPath: platformReceiptPaths.macos.artifact,
        gatedAppPath: join(
          releaseJoinResultDir,
          'macos',
          'publication',
          'Nostr VPN.app',
        ),
      }),
    )],
    ['android', () => {
      const android = buildAndroidArtifacts({
        env,
        tag,
        dryRun: options.dryRun,
        builtLines,
        gateReceiptPath: androidGateReceiptPath,
        candidateCommit,
        candidateTree,
      })
      androidReleaseGate = android.gate
      mergeArtifactProofs(artifactProofs, android.proofs)
    }],
    ['linux', () => mergeArtifactProofs(
      artifactProofs,
      buildLinuxArtifacts({
        env,
        tag,
        dryRun: options.dryRun,
        builtLines,
        candidateCommit,
        candidateTree,
        testedReceiptPath: platformReceiptPaths.linux.artifact,
        testedPackageInstallReceiptPath:
          platformReceiptPaths.linux.package_install,
        gatedBundlePathReceipt: join(
          releaseGateLogDir,
          'host-linux-vm-bundle-path.txt',
        ),
      }),
    )],
    ['windows', () => mergeArtifactProofs(
      artifactProofs,
      buildWindowsArtifacts({
        env,
        tag,
        dryRun: options.dryRun,
        builtLines,
        candidateCommit,
        candidateTree,
        gateReceiptPath: platformReceiptPaths.windows.artifact,
        installerReceiptPath: platformReceiptPaths.windows.installer,
        installerArtifactPath: join(
          releaseGateLogDir,
          'windows-installer',
          `nostr-vpn-${tag}-windows-x64-setup.exe`,
        ),
      }),
    )],
    // Upload the TestFlight/App Store candidate only after every downloadable
    // platform artifact has built successfully, avoiding a partial upload.
    ['ios', () => buildIosArtifacts({
      tag,
      dryRun: options.dryRun,
      builtLines,
      releaseGateLogDir,
    })],
  ]

  for (const [name, fn] of steps) {
    if (!shouldRunStep(name, options)) {
      skippedLines.push(`${name} skipped by CLI options.`)
      continue
    }

    try {
      fn()
      if (
        name === 'platform-versions'
        && !options.dryRun
        && !options.promoteDraft
      ) {
        assertCleanReleaseSource(tag, candidateCommit)
      }
    } catch (error) {
      if (error instanceof SkipStepError) {
        skippedLines.push(error.message)
        continue
      }
      if (name === 'verify') {
        throw error
      }
      const failure = `${name} build failed: ${error.message}`
      skippedLines.push(failure)
      if (!allowPartial) {
        throw new Error(`${failure}\nPass --allow-partial or set NVPN_RELEASE_ALLOW_PARTIAL=1 to stage/publish without this artifact.`)
      }
    }
  }

  if (!options.dryRun) {
    assertCleanReleaseSource(tag, candidateCommit)
  }

  const commit = resolveReleaseCommit(tag, { dryRun: options.dryRun })
  if (!options.dryRun && !allowPartial) {
    if (!releaseGateCompleted || !releaseGateEvidence) {
      throw new Error(
        'Complete release staging requires validated real-platform receipts.',
      )
    }
  }
  const stagedRelease = stageRelease({
    tag,
    commit,
    tree: candidateTree,
    stageDir,
    builtLines,
    skippedLines,
    dryRun: options.dryRun,
    requireCompleteAppRelease: !allowPartial && !options.dryRun,
    draft: options.draft,
    androidReleaseGate,
    releaseGateEvidence,
    artifactProofs,
  })

  if (options.publish) {
    if (!commandExists('htree')) {
      throw new Error('Missing htree; cannot publish release.')
    }
    const cid = publishRelease({ stageDir, releaseTree, tag, draft: options.draft, dryRun: options.dryRun })
    console.log(`Published ${options.draft ? 'draft ' : ''}${tag} to ${releaseTree} via ${cid}`)
  } else if (!options.dryRun) {
    console.log(`Staged ${tag} at ${stageDir}`)
  }

  // A "publish" is supposed to ship the whole release: the htree tree AND
  // the Rust crates on crates.io. Anything that ends up only half-shipped
  // forces us to remember to re-run the cargo half later, which we forget.
  // Default cargo publish on whenever --publish is set; --skip-cargo-publish
  // is the explicit opt-out, --cargo-publish still lets you publish crates
  // without doing the htree publish (e.g. retrying a partial release).
  const shouldPublishCrates =
    options.cargoPublish || (options.publish && !options.draft && !options.skipCargoPublish)
  if (shouldPublishCrates) {
    publishRustCrates({ dryRun: options.dryRun })
  }

  if (options.publish && !options.draft && !options.skipZapstore) {
    publishZapstore({
      env,
      tag,
      apkPath: stagedRelease.stagedAndroidApkPath,
      dryRun: options.dryRun,
      required: requireZapstore,
    })
  }
}

try {
  main()
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}
