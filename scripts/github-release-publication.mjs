import { spawnSync } from 'node:child_process'
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

import { sha256FileSync } from './local-release-lib.mjs'

function run(command, commandArgs, { cwd, allowFailure = false } = {}) {
  const result = spawnSync(command, commandArgs, {
    cwd,
    encoding: 'utf8',
    stdio: 'pipe',
  })
  if (!allowFailure && result.status !== 0) {
    throw new Error(
      result.stderr.trim()
      || result.stdout.trim()
      || `${command} ${commandArgs.join(' ')} failed.`,
    )
  }
  return result
}

function expectedAssets(stageDir, manifest) {
  return manifest.assets.map((asset) => {
    const path = join(stageDir, asset.path)
    const metadata = statSync(path)
    if (
      !metadata.isFile()
      || metadata.size !== asset.size
      || sha256FileSync(path) !== asset.sha256
    ) {
      throw new Error(`GitHub release asset ${asset.path} differs from staging.`)
    }
    return {
      name: basename(asset.path),
      path,
      sha256: asset.sha256,
      size: asset.size,
    }
  })
}

export function validateGithubReleaseMetadata({
  release,
  tag,
  commit,
  notes,
  assets,
}) {
  if (
    release.tagName !== tag
    || release.name !== tag
    || release.isDraft !== false
    || release.isPrerelease !== tag.includes('-')
    || release.targetCommitish !== commit
    || String(release.body ?? '').trimEnd() !== notes.trimEnd()
  ) {
    throw new Error('GitHub release metadata differs from the exact staged release.')
  }
  const remoteAssets = Array.isArray(release.assets) ? release.assets : []
  if (remoteAssets.length !== assets.length) {
    throw new Error('GitHub release asset set differs from the exact staging set.')
  }
  const expectedByName = new Map(assets.map((asset) => [asset.name, asset]))
  for (const remote of remoteAssets) {
    const expected = expectedByName.get(remote.name)
    if (!expected || remote.size !== expected.size) {
      throw new Error(`GitHub release asset ${remote.name} differs from staging.`)
    }
    if (
      typeof remote.digest === 'string'
      && remote.digest
      && remote.digest !== `sha256:${expected.sha256}`
    ) {
      throw new Error(`GitHub release asset ${remote.name} digest differs.`)
    }
  }
}

export function githubReleaseRepairPlan({
  release,
  tag,
  commit,
  notes,
  assets,
}) {
  if (
    release.tagName !== tag
    || release.targetCommitish !== commit
  ) {
    throw new Error(
      'Existing GitHub release tag or target commit differs from exact staging.',
    )
  }
  const expectedByName = new Map(assets.map((asset) => [asset.name, asset]))
  if (expectedByName.size !== assets.length) {
    throw new Error('Staged GitHub release contains duplicate asset names.')
  }
  const present = []
  const seen = new Set()
  for (const remote of Array.isArray(release.assets) ? release.assets : []) {
    const expected = expectedByName.get(remote.name)
    if (!expected || seen.has(remote.name)) {
      throw new Error(
        `Existing GitHub release asset ${remote.name} is unexpected or duplicated.`,
      )
    }
    seen.add(remote.name)
    if (remote.size !== expected.size) {
      throw new Error(
        `Existing GitHub release asset ${remote.name} differs from staging.`,
      )
    }
    if (
      typeof remote.digest === 'string'
      && remote.digest
      && remote.digest !== `sha256:${expected.sha256}`
    ) {
      throw new Error(
        `Existing GitHub release asset ${remote.name} digest differs.`,
      )
    }
    present.push(expected)
  }
  return {
    metadataNeedsEdit:
      release.name !== tag
      || release.isDraft !== false
      || release.isPrerelease !== tag.includes('-')
      || String(release.body ?? '').trimEnd() !== notes.trimEnd(),
    missing: assets.filter(({ name }) => !seen.has(name)),
    present,
  }
}

function viewRelease({ repoRoot, tag }) {
  const viewed = run(
    'gh',
    [
      'release',
      'view',
      tag,
      '--json',
      'tagName,name,isDraft,isPrerelease,targetCommitish,body,assets',
    ],
    { cwd: repoRoot, allowFailure: true },
  )
  if (viewed.status !== 0) {
    return { error: viewed.stderr.trim(), release: null }
  }
  try {
    return { error: '', release: JSON.parse(viewed.stdout) }
  } catch {
    throw new Error('gh release view returned invalid JSON.')
  }
}

function verifyRemoteAssets({ repoRoot, tag, assets }) {
  const downloadDir = mkdtempSync(join(tmpdir(), 'nvpn-gh-release-'))
  try {
    run(
      'gh',
      ['release', 'download', tag, '--dir', downloadDir, '--clobber'],
      { cwd: repoRoot },
    )
    const names = readdirSync(downloadDir).sort()
    const expectedNames = assets.map(({ name }) => name).sort()
    if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
      throw new Error('Downloaded GitHub release asset set differs from staging.')
    }
    for (const asset of assets) {
      const downloaded = join(downloadDir, asset.name)
      if (
        statSync(downloaded).size !== asset.size
        || sha256FileSync(downloaded) !== asset.sha256
      ) {
        throw new Error(
          `Downloaded GitHub release asset ${asset.name} differs from staging.`,
        )
      }
    }
  } finally {
    rmSync(downloadDir, { recursive: true, force: true })
  }
}

function repairExactRelease({
  repoRoot,
  tag,
  commit,
  notesPath,
  notes,
  assets,
  release,
}) {
  const plan = githubReleaseRepairPlan({
    release,
    tag,
    commit,
    notes,
    assets,
  })

  // A missing digest in GitHub's metadata is not proof of exact bytes. Download
  // and hash every already-present asset before making any repair mutation.
  if (plan.present.length > 0) {
    verifyRemoteAssets({
      repoRoot,
      tag,
      assets: plan.present,
    })
  }
  if (plan.missing.length > 0) {
    run(
      'gh',
      [
        'release',
        'upload',
        tag,
        ...plan.missing.map(({ path }) => path),
      ],
      { cwd: repoRoot },
    )
  }
  if (plan.metadataNeedsEdit) {
    run(
      'gh',
      [
        'release',
        'edit',
        tag,
        '--verify-tag',
        '--target',
        commit,
        '--title',
        tag,
        '--notes-file',
        notesPath,
        '--draft=false',
        `--prerelease=${tag.includes('-')}`,
        `--latest=${!tag.includes('-')}`,
      ],
      { cwd: repoRoot },
    )
  }
}

export function preflightGithubRelease({
  repoRoot,
  tag,
  commit,
  dryRun = false,
}) {
  if (dryRun) {
    return
  }
  run('gh', ['auth', 'status'], { cwd: repoRoot })
  run('gh', ['repo', 'view', '--json', 'nameWithOwner'], { cwd: repoRoot })
  const tagCommit = run(
    'git',
    ['rev-parse', '-q', '--verify', `${tag}^{commit}`],
    { cwd: repoRoot },
  ).stdout.trim()
  if (tagCommit !== commit) {
    throw new Error(`GitHub release tag ${tag} differs from staged commit ${commit}.`)
  }
  for (const [remote, reference, label] of [
    ['github', 'refs/heads/master', 'GitHub master'],
    ['github', `refs/tags/${tag}`, `GitHub tag ${tag}`],
    ['origin', 'refs/heads/master', 'htree master'],
  ]) {
    const remoteRef = run(
      'git',
      ['ls-remote', '--exit-code', remote, reference],
      { cwd: repoRoot },
    ).stdout.trim().split(/\s+/)[0]
    if (remoteRef !== commit) {
      throw new Error(`${label} does not resolve to staged commit ${commit}.`)
    }
  }
}

export function publishExactGithubRelease({
  repoRoot,
  stageDir,
  manifest,
  tag,
  commit,
  dryRun = false,
}) {
  const assets = expectedAssets(stageDir, manifest)
  const notesPath = join(stageDir, 'notes.md')
  const notes = readFileSync(notesPath, 'utf8')
  if (dryRun) {
    return { created: false, verified: true }
  }
  let viewed = viewRelease({ repoRoot, tag })
  let created = false
  if (viewed.release === null) {
    if (!/not found|HTTP 404/i.test(viewed.error)) {
      throw new Error(viewed.error || 'Could not inspect existing GitHub release.')
    }
    const arguments_ = [
      'release',
      'create',
      tag,
      '--verify-tag',
      '--target',
      commit,
      '--title',
      tag,
      '--notes-file',
      notesPath,
      ...(tag.includes('-') ? ['--prerelease'] : ['--latest']),
      ...assets.map(({ path }) => path),
    ]
    const creation = run('gh', arguments_, {
      cwd: repoRoot,
      allowFailure: true,
    })
    if (creation.status === 0) {
      created = true
    }
    viewed = viewRelease({ repoRoot, tag })
    if (viewed.release === null) {
      throw new Error(
        creation.stderr.trim()
        || creation.stdout.trim()
        || viewed.error
        || 'GitHub release creation failed.',
      )
    }
  }
  repairExactRelease({
    repoRoot,
    tag,
    commit,
    notesPath,
    notes,
    assets,
    release: viewed.release,
  })
  viewed = viewRelease({ repoRoot, tag })
  if (viewed.release === null) {
    throw new Error(
      viewed.error || 'GitHub release disappeared during exact verification.',
    )
  }
  validateGithubReleaseMetadata({
    release: viewed.release,
    tag,
    commit,
    notes,
    assets,
  })
  verifyRemoteAssets({ repoRoot, tag, assets })
  return { created, verified: true }
}
