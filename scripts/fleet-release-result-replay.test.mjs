import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

const sha256 = (bytes) =>
  createHash('sha256').update(bytes).digest('hex')

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value)}\n`)
}

function bound(path) {
  const canonical = realpathSync(path)
  const bytes = readFileSync(canonical)
  return {
    path: canonical,
    sha256: sha256(bytes),
    size: statSync(canonical).size,
  }
}

test('canonical fleet replay rejects minimal hand-authored passed receipts', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-fleet-replay-test-'))
  try {
    const source = {
      appGitSha: '1'.repeat(40),
      appGitTree: '2'.repeat(40),
      appVersion: '4.1.5',
      fipsGitSha: '3'.repeat(40),
      fipsGitTree: '4'.repeat(40),
      fipsVersion: '0.4.45',
    }
    const artifactPath = join(root, 'nvpn')
    writeFileSync(artifactPath, 'exact installed executable\n')
    const artifact = bound(artifactPath)
    const receiptPath = join(root, 'artifact-receipt.json')
    writeJson(receiptPath, {
      schema: 1,
      ...source,
      platform: 'linux',
      arch: 'x86_64',
      artifactSha256: artifact.sha256,
      artifactSize: artifact.size,
      installedBinarySha256: artifact.sha256,
      installedPayloads: { executable: artifact.sha256 },
    })
    const manifestPath = join(root, 'manifest.json')
    const inventoryPath = join(root, 'inventory.json')
    const probePath = join(root, 'probe-raw.json')
    const installPath = join(root, 'install-raw.json')
    writeJson(inventoryPath, {
      schema: 2,
      targets: [
        {
          id: 'linux-main',
          platform: 'linux',
          arch: 'x86_64',
          artifact: 'linux-x86_64',
          deployment: {
            authorization: 'install',
            binaryPath: '/usr/local/bin/nvpn',
            probeBinaryPath: '/usr/local/bin/nvpn',
          },
          expected: {
            machineIdentitySha256: '5'.repeat(64),
            configSha256: '6'.repeat(64),
            signedRosterStoreSha256: '7'.repeat(64),
            rosterIdentitySha256: '8'.repeat(64),
            rosterPeerCount: 1,
            localDeviceIdentitySha256: '9'.repeat(64),
            networkIdentitySha256: 'a'.repeat(64),
          },
          checks: {
            payloadTarget: '10.44.0.2',
            dnsName: 'example.com',
            directUrl: 'https://example.com/',
          },
        },
      ],
    })
    writeJson(probePath, {
      schema: 2,
      targetId: 'linux-main',
      realChecks: true,
      mocked: false,
      remoteBuildPerformed: false,
    })
    writeJson(installPath, {
      schema: 2,
      targetId: 'linux-main',
      realChecks: true,
      mocked: false,
      remoteBuildPerformed: false,
      installAuthorized: true,
      transaction: {
        id: 'b'.repeat(32),
        state: 'committed',
      },
      ...source,
    })
    writeJson(manifestPath, {
      schema: 2,
      inventorySha256: bound(inventoryPath).sha256,
      ...source,
      artifacts: [
        {
          id: 'linux-x86_64',
          platform: 'linux',
          arch: 'x86_64',
          ...artifact,
          installPayload: {
            format: 'executable',
            executableMember: null,
            companions: [],
          },
          receipt: bound(receiptPath),
        },
      ],
    })
    const resultPath = join(root, 'result.json')
    writeJson(resultPath, {
      schema: 2,
      mode: 'execute',
      status: 'passed',
      manifestSha256: bound(manifestPath).sha256,
      inventorySha256: bound(inventoryPath).sha256,
      driverSha256: 'c'.repeat(64),
      releaseGateManifestSha256: 'd'.repeat(64),
      ...source,
      targets: [
        {
          id: 'linux-main',
          status: 'passed',
          evidence: {
            probe: bound(probePath),
            install: bound(installPath),
          },
        },
      ],
    })

    const replay = spawnSync(
      'python3',
      [
        join(process.cwd(), 'scripts/fleet_release_result_replay.py'),
        '--result',
        resultPath,
        '--manifest',
        manifestPath,
        '--inventory',
        inventoryPath,
      ],
      { encoding: 'utf8' },
    )
    assert.equal(replay.status, 1)
    assert.match(replay.stderr, /reachable must be true/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
