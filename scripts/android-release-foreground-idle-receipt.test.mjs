import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  createAndroidForegroundIdleReceipt,
} from './android-release-foreground-idle-receipt.mjs'

const sha256 = (value) => createHash('sha256').update(value).digest('hex')

function fixture(root) {
  const artifact = {
    receiptSchema: 2,
    artifactType: 'Android Release APK',
    appGitSha: 'a'.repeat(40),
    appGitTree: 'b'.repeat(40),
    fipsGitSha: 'c'.repeat(40),
    fipsGitTree: 'd'.repeat(40),
    apkSha256: '1'.repeat(64),
    installedApkSha256: '1'.repeat(64),
    package: 'fi.siriusbusiness.nvpn',
    signerCertificateSha256: '2'.repeat(64),
    companySigningVerified: true,
    debuggable: false,
  }
  const raw = {
    ok: true,
    mode: 'android-package',
    label: 'Android Release foreground VPN-off',
    maxPercent: 2,
    sampleSeconds: 60,
    settleSeconds: 10,
    elapsedSeconds: 60.2,
    cpuPercent: 1.4,
    package: artifact.package,
    pids: [1234],
    clockTicks: 100,
    generatedAt: '2026-08-09T17:30:55Z',
  }
  const artifactPath = join(root, 'artifact.json')
  const rawPath = join(root, 'idle-cpu.json')
  const outputPath = join(root, 'receipt.json')
  writeFileSync(artifactPath, `${JSON.stringify(artifact)}\n`)
  writeFileSync(rawPath, `${JSON.stringify(raw)}\n`)
  return { artifact, raw, artifactPath, rawPath, outputPath }
}

test('live Android foreground-idle receipt binds the raw sample to the exact artifact', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-android-idle-receipt-'))
  try {
    const value = fixture(root)
    createAndroidForegroundIdleReceipt({
      artifactReceiptPath: value.artifactPath,
      rawReceiptPath: value.rawPath,
      outputPath: value.outputPath,
      verifiedLiveContext: true,
    })
    const receipt = JSON.parse(readFileSync(value.outputPath, 'utf8'))
    assert.equal(receipt.appGitSha, value.artifact.appGitSha)
    assert.equal(
      receipt.artifactReceiptSha256,
      sha256(readFileSync(value.artifactPath)),
    )
    assert.equal(
      receipt.rawIdleCpuReceiptSha256,
      sha256(readFileSync(value.rawPath)),
    )
    assert.deepEqual(receipt.sample, value.raw)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('legacy Android foreground-idle evidence requires exact provenance and cleanup', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-android-idle-legacy-'))
  try {
    const value = fixture(root)
    const provenancePath = join(root, 'provenance.json')
    const summaryPath = join(root, 'summary.json')
    const cleanupPath = join(root, 'cleanup.json')
    const provenance = {
      appGitSha: value.artifact.appGitSha,
      appGitTree: value.artifact.appGitTree,
      fipsGitSha: value.artifact.fipsGitSha,
      fipsGitTree: value.artifact.fipsGitTree,
      apkSha256: value.artifact.apkSha256,
      package: value.artifact.package,
      signerCertificateSha256: value.artifact.signerCertificateSha256,
      companySigningVerified: true,
      installedApkByteIdentical: true,
      debuggable: false,
    }
    writeFileSync(provenancePath, `${JSON.stringify(provenance)}\n`)
    writeFileSync(summaryPath, `${JSON.stringify({
      ok: true,
      vpnMode: 'off',
      underlay: 'direct-validated-wifi',
      foregroundGateExitStatus: 0,
      foreground: value.raw,
    })}\n`)
    writeFileSync(cleanupPath, `${JSON.stringify({
      ok: true,
      appForceStopped: true,
      vpnInactive: true,
      directValidatedWifiRestored: true,
    })}\n`)

    const args = {
      artifactReceiptPath: value.artifactPath,
      rawReceiptPath: value.rawPath,
      outputPath: value.outputPath,
      legacyProvenancePath: provenancePath,
      legacySummaryPath: summaryPath,
      legacyCleanupPath: cleanupPath,
    }
    assert.doesNotThrow(() => createAndroidForegroundIdleReceipt(args))
    provenance.apkSha256 = '3'.repeat(64)
    writeFileSync(provenancePath, `${JSON.stringify(provenance)}\n`)
    assert.throws(
      () => createAndroidForegroundIdleReceipt(args),
      /legacy foreground-idle provenance differs from the exact artifact/i,
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
