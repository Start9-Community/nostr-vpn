import { spawnSync } from 'node:child_process'
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import os from 'node:os'
import { join, resolve } from 'node:path'

import {
  semverFromTag,
  sha256FileSync,
  validateZapstoreApkMetadata,
  validateZapstoreRelayPublication,
  zapstorePublicationPrerequisites,
} from './local-release-lib.mjs'

function run(
  command,
  commandArgs,
  { cwd, env = process.env, capture = false, input, timeout } = {},
) {
  const result = spawnSync(command, commandArgs, {
    cwd,
    env,
    encoding: 'utf8',
    input,
    timeout,
    stdio: capture ? 'pipe' : 'inherit',
  })
  if (result.status !== 0) {
    throw new Error(
      (capture ? result.stderr.trim() || result.stdout.trim() : '')
      || `${command} ${commandArgs.join(' ')} failed.`,
    )
  }
  return capture ? result.stdout.trim() : ''
}

function commandExists(command) {
  return spawnSync(
    'sh',
    ['-lc', `command -v "${command}"`],
    { stdio: 'ignore' },
  ).status === 0
}

export function resolveSignWith(env = process.env) {
  const fromEnv = String(env.SIGN_WITH ?? '').trim()
  if (fromEnv) {
    return fromEnv
  }
  const keyPath = String(env.NOSTR_KEY_PATH ?? '').trim()
  return keyPath && existsSync(keyPath)
    ? readFileSync(keyPath, 'utf8').trim()
    : ''
}

function publicationContext({ repoRoot, env }) {
  const signWith = resolveSignWith(env)
  const zapstoreYaml = join(repoRoot, 'zapstore.yaml')
  const configExists = existsSync(zapstoreYaml)
  const config = configExists ? readFileSync(zapstoreYaml, 'utf8') : ''
  const publisherNpub = (
    config.match(/^\s*pubkey:\s*(\S+)\s*$/m)?.[1] || ''
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

export function preflightRequiredZapstorePublication({
  repoRoot,
  env,
  mutationEnv = env,
  requireApk = false,
  apkPath = '',
  expectedApk = null,
  tag = '',
}) {
  const context = publicationContext({ repoRoot, env })
  zapstorePublicationPrerequisites(
    {
      apk: !requireApk || Boolean(apkPath && existsSync(apkPath)),
      zsp: commandExists('zsp'),
      nak: commandExists('nak'),
      signing: Boolean(context.signWith),
      config: context.configExists,
      publisher: Boolean(context.publisherNpub),
      relays: context.relayUrls.length > 0,
    },
    { required: true },
  )
  const publisherPubkey = run(
    'nak',
    ['decode', context.publisherNpub],
    { cwd: repoRoot, capture: true },
  ).trim()
  if (!/^[0-9a-f]{64}$/i.test(publisherPubkey)) {
    throw new Error('zapstore.yaml publisher pubkey could not be decoded.')
  }
  for (const relay of context.relayUrls) {
    run(
      'nak',
      [
        'req',
        '-k',
        '32267',
        '-a',
        context.publisherNpub,
        '-l',
        '1',
        relay,
      ],
      {
        cwd: repoRoot,
        capture: true,
        timeout: 10_000,
      },
    )
  }
  if (requireApk) {
    const androidGradle = readFileSync(
      join(repoRoot, 'android', 'app', 'build.gradle.kts'),
      'utf8',
    )
    const frozen = freezePublication({
      repoRoot,
      runEnv: mutationEnv,
      apkName: `nostr-vpn-${tag}-android-arm64.apk`,
      apkPath,
      expected: expectedApk,
      expectedPackageId:
        String(env.NVPN_ANDROID_PACKAGE_ID || '').trim()
        || 'fi.siriusbusiness.nvpn',
      expectedVersion: semverFromTag(tag),
      expectedVersionCode: Number(
        String(env.NVPN_ANDROID_VERSION_CODE || '').trim()
          || androidGradle.match(/\bversionCode\s*=\s*(\d+)/)?.[1]
          || '',
      ),
      zapstoreYaml: context.zapstoreYaml,
    })
    try {
      run(
        'zsp',
        ['publish', '--quiet', '--check', frozen.config],
        {
          cwd: repoRoot,
          env: { ...mutationEnv, SIGN_WITH: context.signWith },
          capture: true,
        },
      )
    } finally {
      rmSync(frozen.directory, { recursive: true, force: true })
    }
  }
  return { ...context, publisherPubkey }
}

function freezePublication({
  repoRoot,
  runEnv,
  apkName,
  apkPath,
  expected,
  expectedPackageId,
  expectedVersion,
  expectedVersionCode,
  zapstoreYaml,
}) {
  if (
    !expected
    || !/^[0-9a-f]{64}$/.test(String(expected.sha256 ?? ''))
    || !/^[0-9a-f]{64}$/.test(String(expected.signerSha256 ?? ''))
  ) {
    throw new Error(
      'Zapstore publication requires frozen APK and signer SHA-256 values.',
    )
  }
  const directory = mkdtempSync(
    join(os.tmpdir(), 'nvpn-zapstore-immutable-'),
  )
  chmodSync(directory, 0o700)
  const apk = join(directory, apkName)
  const config = join(directory, 'zapstore.yaml')
  try {
    copyFileSync(apkPath, apk)
    chmodSync(apk, 0o400)
    if (sha256FileSync(apk) !== expected.sha256) {
      throw new Error('Frozen Zapstore APK differs from the staged manifest.')
    }
    const sourceConfig = readFileSync(zapstoreYaml, 'utf8')
    const iconMatch = sourceConfig.match(/^\s*icon:\s*(\S+)\s*$/m)
    const iconPath = iconMatch ? resolve(repoRoot, iconMatch[1]) : ''
    let frozenConfig = sourceConfig.replace(
      /^\s*release_source:\s*.*$/m,
      `release_source: ${JSON.stringify(apk)}`,
    )
    if (iconPath) {
      frozenConfig = frozenConfig.replace(
        /^\s*icon:\s*.*$/m,
        `icon: ${JSON.stringify(iconPath)}`,
      )
    }
    if (!frozenConfig.includes(JSON.stringify(apk))) {
      throw new Error('Zapstore config has no exact release_source entry.')
    }
    writeFileSync(config, frozenConfig, { mode: 0o400 })
    chmodSync(config, 0o400)
    const metadataOutput = run(
      'zsp',
      ['utils', 'extract-apk', apk],
      { cwd: repoRoot, env: runEnv, capture: true },
    )
    let metadata
    try {
      metadata = JSON.parse(metadataOutput)
    } catch {
      throw new Error('zsp APK inspection did not return valid JSON.')
    }
    const validated = validateZapstoreApkMetadata(metadata, {
      expectedVersion,
      expectedVersionCode,
      expectedPackageId,
      expectedCertificateFingerprint: expected.signerSha256,
    })
    if (
      validated.sha256 !== expected.sha256
      || validated.sha256 !== sha256FileSync(apk)
    ) {
      throw new Error('Zapstore inspection differs from the immutable APK.')
    }
    return { apk, config, directory, validated }
  } catch (error) {
    rmSync(directory, { recursive: true, force: true })
    throw error
  }
}

function replayMutationGate({ repoRoot, mutationEnv }) {
  run(
    'node',
    [join(repoRoot, 'scripts', 'release-mutation-gate.mjs'), '--require-tag'],
    { cwd: repoRoot, env: mutationEnv, capture: true },
  )
}

export function publishExactZapstoreRelease({
  repoRoot,
  env,
  mutationEnv,
  tag,
  apkPath,
  expectedApk,
  dryRun,
  required = false,
}) {
  const apkName = `nostr-vpn-${tag}-android-arm64.apk`
  if (!apkPath) {
    throw new Error('Zapstore publication requires an explicit staged Android APK.')
  }
  if (dryRun) {
    return { published: false, verified: true }
  }
  const context = publicationContext({ repoRoot, env })
  const prerequisites = zapstorePublicationPrerequisites(
    {
      apk: existsSync(apkPath),
      zsp: commandExists('zsp'),
      nak: commandExists('nak'),
      signing: Boolean(context.signWith),
      config: context.configExists,
      publisher: Boolean(context.publisherNpub),
      relays: context.relayUrls.length > 0,
    },
    { required },
  )
  if (!prerequisites.available) {
    return { published: false, verified: false }
  }
  const publisherPubkey = run(
    'nak',
    ['decode', context.publisherNpub],
    { cwd: repoRoot, capture: true },
  ).trim()
  if (!/^[0-9a-f]{64}$/i.test(publisherPubkey)) {
    throw new Error('zapstore.yaml publisher pubkey could not be decoded.')
  }

  const androidGradle = readFileSync(
    join(repoRoot, 'android', 'app', 'build.gradle.kts'),
    'utf8',
  )
  const expectedVersionCode = Number(
    String(env.NVPN_ANDROID_VERSION_CODE || '').trim()
      || androidGradle.match(/\bversionCode\s*=\s*(\d+)/)?.[1]
      || '',
  )
  const frozen = freezePublication({
    repoRoot,
    runEnv: mutationEnv,
    apkName,
    apkPath,
    expected: expectedApk,
    expectedPackageId:
      String(env.NVPN_ANDROID_PACKAGE_ID || '').trim()
      || 'fi.siriusbusiness.nvpn',
    expectedVersion: semverFromTag(tag),
    expectedVersionCode,
    zapstoreYaml: context.zapstoreYaml,
  })
  const validated = frozen.validated
  try {
    if (sha256FileSync(frozen.apk) !== expectedApk.sha256) {
      throw new Error('Immutable Zapstore APK changed before zsp check.')
    }
    run(
      'zsp',
      ['publish', '--quiet', '--check', frozen.config],
      {
        cwd: repoRoot,
        env: { ...mutationEnv, SIGN_WITH: context.signWith },
        capture: true,
      },
    )
    replayMutationGate({ repoRoot, mutationEnv })
    if (sha256FileSync(frozen.apk) !== expectedApk.sha256) {
      throw new Error('Immutable Zapstore APK changed before publication.')
    }
    run(
      'zsp',
      [
        'publish',
        '--quiet',
        '--skip-preview',
        '--overwrite-release',
        frozen.config,
      ],
      {
        cwd: repoRoot,
        env: { ...mutationEnv, SIGN_WITH: context.signWith },
      },
    )

    let lastError = new Error('Zapstore release verification did not run.')
    for (let attempt = 1; attempt <= 8; attempt += 1) {
      try {
        const query = (kind, filters) =>
          run(
            'nak',
            [
              'req',
              '-k',
              String(kind),
              '-a',
              context.publisherNpub,
              ...filters,
              '-l',
              '20',
              ...context.relayUrls,
            ],
            { cwd: repoRoot, capture: true },
          )
            .split(/\r?\n/)
            .map((line) => line.trim())
            .filter(Boolean)
            .map((line) => JSON.parse(line))
        const publication = validateZapstoreRelayPublication({
          appEvents: query(32267, ['-d', validated.packageId]),
          releaseEvents: query(30063, [
            '-d',
            `${validated.packageId}@${validated.versionName}`,
          ]),
          assetEvents: query(3063, [
            '-t',
            `i=${validated.packageId}`,
            '-t',
            `version=${validated.versionName}`,
          ]),
          expected: {
            pubkey: publisherPubkey,
            packageId: validated.packageId,
            versionName: validated.versionName,
            versionCode: validated.versionCode,
            sha256: validated.sha256,
            certificateFingerprint: validated.certificateFingerprint,
          },
        })
        for (const event of Object.values(publication)) {
          run('nak', ['verify'], {
            cwd: repoRoot,
            capture: true,
            input: `${JSON.stringify(event)}\n`,
          })
        }
        return { published: true, verified: true }
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error))
        if (attempt < 8) {
          Atomics.wait(
            new Int32Array(new SharedArrayBuffer(4)),
            0,
            0,
            2_000,
          )
        }
      }
    }
    throw new Error(
      `Zapstore publication completed but verification failed: ${lastError.message}`,
    )
  } finally {
    rmSync(frozen.directory, { recursive: true, force: true })
  }
}
