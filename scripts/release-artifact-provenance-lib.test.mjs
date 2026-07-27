import test from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'

import {
  androidRuntimePayloads,
  buildReleaseGateAttestation,
  collectReleaseGateReceipts,
  startosExactPackageValidator,
} from './release-artifact-provenance-lib.mjs'

function sha256(value) {
  return createHash('sha256').update(value).digest('hex')
}

function write(path, value) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, value)
}

const desktopDnsCounterNames = [
  'cloudflare',
  'quad9',
  'google',
  'fixture_dns',
]

function desktopDnsCase(expectedCounter) {
  return Object.fromEntries(
    desktopDnsCounterNames.flatMap((counter) => [
      [`before_${counter}`, 1],
      [`after_${counter}`, counter === expectedCounter ? 2 : 1],
    ]),
  )
}

function desktopDnsUiCases(appExecutableSha256, cliExecutableSha256) {
  const settings = {
    automatic: ['automatic', 'cloudflare'],
    cloudflare: ['encrypted', 'cloudflare'],
    quad9: ['encrypted', 'quad9'],
    custom: ['encrypted', 'custom'],
    'through-exit': ['through_exit', 'cloudflare'],
  }
  return Object.fromEntries(
    Object.entries(settings).map(([dnsCase, [mode, provider]]) => [
      dnsCase,
      {
        mode,
        provider,
        appExecutableSha256,
        cliExecutableSha256,
      },
    ]),
  )
}

const desktopDnsUiEvidenceFiles = Object.fromEntries(
  ['automatic', 'cloudflare', 'quad9', 'custom', 'through-exit'].map(
    (dnsCase, index) => [
      `${dnsCase}.json`,
      String(index + 10).padStart(64, '0'),
    ],
  ),
)

function zipTree(source, destination) {
  rmSync(destination, { force: true })
  const result = spawnSync('zip', ['-q', '-r', destination, '.'], {
    cwd: source,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  assert.equal(result.status, 0, result.stderr)
}

test('Android bundle proof compares real APK and AAB production payload bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-android-proof-test-'))
  try {
    const apkRoot = join(root, 'apk')
    const aabRoot = join(root, 'aab')
    const native = Buffer.from('production-native-payload')
    const dex = Buffer.from('production-dex-payload')
    write(
      join(apkRoot, 'lib', 'arm64-v8a', 'libnostr_vpn_app_core.so'),
      native,
    )
    write(join(apkRoot, 'classes.dex'), dex)
    write(
      join(aabRoot, 'base', 'lib', 'arm64-v8a', 'libnostr_vpn_app_core.so'),
      native,
    )
    write(join(aabRoot, 'base', 'dex', 'classes.dex'), dex)

    const apk = join(root, 'app.apk')
    const aab = join(root, 'app.aab')
    zipTree(apkRoot, apk)
    zipTree(aabRoot, aab)
    assert.deepEqual(androidRuntimePayloads(apk, aab), {
      app_core_arm64: sha256(native),
      classes_dex: sha256(dex),
    })

    write(
      join(aabRoot, 'base', 'dex', 'classes.dex'),
      Buffer.from('different-dex'),
    )
    zipTree(aabRoot, aab)
    assert.throws(
      () => androidRuntimePayloads(apk, aab),
      /differs from the physically gated APK/,
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('release receipt collection requires exact source and strict public UI gates', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-gate-receipts-test-'))
  try {
    const commit = 'a'.repeat(40)
    const tree = 'b'.repeat(40)
    const source = {
      appGitSha: commit,
      appGitTree: tree,
      fipsGitSha: 'c'.repeat(40),
      fipsGitTree: 'd'.repeat(40),
    }
    const mobileJoinPath = join(root, 'mobile-join.json')
    const paths = {
      android: {
        physical: join(root, 'android.json'),
        mobile_join: mobileJoinPath,
        wireguard_dns: join(root, 'android-wg.json'),
        underlay_lifecycle: join(root, 'android-underlay.json'),
        replacement_singleton: join(root, 'android-replacement.json'),
      },
      ios: {
        frozen_archive: join(root, 'ios.json'),
        mobile_artifact: join(root, 'ios-artifact.json'),
        mobile_join: mobileJoinPath,
        wireguard_dns: join(root, 'ios-wg.json'),
        underlay_lifecycle: join(root, 'ios-underlay.json'),
      },
      linux: {
        artifact: join(root, 'linux-artifact.json'),
        package_install: join(root, 'linux-package-install.json'),
        public_ui_join: join(root, 'linux-join.json'),
        network: join(root, 'linux-network.json'),
      },
      macos: {
        artifact: join(root, 'macos-artifact.json'),
        public_ui_join: join(root, 'macos-join.json'),
        network: join(root, 'macos-network.json'),
      },
      windows: {
        artifact: join(root, 'windows-artifact.json'),
        installer: join(root, 'windows-installer.json'),
        public_ui_join: join(root, 'windows-join.json'),
        network: join(root, 'windows-network.json'),
      },
    }
    const summary = join(root, 'summary.json')
    writeFileSync(summary, JSON.stringify({
      elapsedSeconds: 42,
      targetSeconds: 300,
      targetStatus: 'met',
    }))
    const androidArtifact = {
      ...source,
      receiptSchema: 2,
      artifactType: 'Android Release APK',
      apkSha256: '1'.repeat(64),
      installedApkSha256: '1'.repeat(64),
      aabSha256: '0'.repeat(64),
      apkDerivedFromAab: true,
      bundleReceiptSha256: 'f'.repeat(64),
      bundletoolVersion: '1.18.3',
      bundletoolSha256:
        'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29',
      package: 'fi.siriusbusiness.nvpn',
      signerCertificateSha256: '2'.repeat(64),
      companySigningVerified: true,
    }
    const iosArtifact = {
      ...source,
      receiptSchema: 2,
      artifactType: 'iOS company Ad Hoc Release app',
      appBundleTreeSha256: '3'.repeat(64),
      appCodeDirectoryHash: '4'.repeat(40),
      packetTunnelCodeDirectoryHash: '5'.repeat(40),
      appExecutableSha256: '6'.repeat(64),
      packetTunnelExecutableSha256: '7'.repeat(64),
      signerCertificateSha256: '8'.repeat(64),
      installedBundleIdentifier: 'fi.siriusbusiness.nvpn',
    }
    const androidText = JSON.stringify(androidArtifact)
    const iosText = JSON.stringify(iosArtifact)
    writeFileSync(paths.android.physical, androidText)
    writeFileSync(paths.ios.mobile_artifact, iosText)
    const networkReceipt = (platform, mode, artifact, artifactText) => ({
      ...source,
      receiptSchema: 1,
      artifactType: `physical ${platform} Release ${mode} gate`,
      platform,
      mode,
      artifactReceiptSha256: sha256(artifactText),
      artifactIdentity: platform === 'android'
        ? {
            apkSha256: artifact.apkSha256,
            installedApkSha256: artifact.installedApkSha256,
            package: artifact.package,
            signerCertificateSha256: artifact.signerCertificateSha256,
          }
        : {
            appBundleTreeSha256: artifact.appBundleTreeSha256,
            appCodeDirectoryHash: artifact.appCodeDirectoryHash,
            packetTunnelCodeDirectoryHash:
              artifact.packetTunnelCodeDirectoryHash,
            appExecutableSha256: artifact.appExecutableSha256,
            packetTunnelExecutableSha256:
              artifact.packetTunnelExecutableSha256,
            signerCertificateSha256: artifact.signerCertificateSha256,
            installedBundleIdentifier: artifact.installedBundleIdentifier,
          },
      dnsCases: Object.fromEntries(
        (mode === 'wireguard-dns'
          ? [
              'automatic-profile',
              'cloudflare-doh',
              'quad9-doh',
              'custom-doh',
              'through-exit',
            ]
          : ['automatic-profile'])
          .map((label) => {
            const policy = {
              'automatic-profile': ['dns-profile', ['query', 'profile']],
              'cloudflare-doh': ['doh-cloudflare', ['cloudflare']],
              'quad9-doh': ['doh-quad9', ['quad9']],
              'custom-doh': ['doh-google', ['google']],
              'through-exit': ['dns-through', ['query', 'through']],
            }[label]
            const counters = [
              'query',
              'profile',
              'cloudflare',
              'quad9',
              'google',
              'through',
              'forward',
            ]
            const before = Object.fromEntries(
              counters.map((counter) => [counter, 1]),
            )
            const after = { ...before }
            for (const counter of policy[1]) {
              after[counter] += 1
            }
            return [label, {
              dnsEvidence: policy[0],
              wireGuardRxBytesBefore: 1,
              wireGuardRxBytesAfter: 2,
              wireGuardTxBytesBefore: 1,
              wireGuardTxBytesAfter: 2,
              forwardedPacketsBefore: 1,
              forwardedPacketsAfter: 2,
              dnsPathCountersBefore: before,
              dnsPathCountersAfter: after,
            }]
          }),
      ),
      support: mode === 'wireguard-dns'
        ? {
            rapidStartStopCycles: 8,
            ...(platform === 'android'
              ? { directBeforeConnectedAfter: true }
              : {}),
          }
        : {
            lifecycleCycles: 3,
            underlayCycles: [{}, {}],
            ...(platform === 'android'
              ? { postForegroundDnsHttpsAndTunnelCycles: 3 }
              : {}),
          },
      evidenceFiles: { 'receipt.json': 'e'.repeat(64) },
    })
    writeFileSync(
      paths.android.wireguard_dns,
      JSON.stringify(networkReceipt(
        'android',
        'wireguard-dns',
        androidArtifact,
        androidText,
      )),
    )
    writeFileSync(
      paths.android.underlay_lifecycle,
      JSON.stringify(networkReceipt(
        'android',
        'underlay-lifecycle',
        androidArtifact,
        androidText,
      )),
    )
    writeFileSync(paths.android.replacement_singleton, JSON.stringify({
      ...source,
      receiptSchema: 1,
      artifactType: 'Android Release replacement/singleton gate',
      artifactReceiptSha256: sha256(androidText),
      apkSha256: androidArtifact.apkSha256,
      installedApkSha256: androidArtifact.installedApkSha256,
      package: androidArtifact.package,
      signerCertificateSha256: androidArtifact.signerCertificateSha256,
      canonicalPackageCount: 1,
      retiredPackageCount: 0,
      canonicalMainProcessCount: 1,
      canonicalUpdatePreservedData: true,
      shippedRemovalPrompt: true,
      vpnStartBlockedBeforeCleanup: true,
      systemUninstallConfirmed: true,
    }))
    writeFileSync(
      paths.ios.wireguard_dns,
      JSON.stringify(networkReceipt(
        'ios',
        'wireguard-dns',
        iosArtifact,
        iosText,
      )),
    )
    writeFileSync(
      paths.ios.underlay_lifecycle,
      JSON.stringify(networkReceipt(
        'ios',
        'underlay-lifecycle',
        iosArtifact,
        iosText,
      )),
    )
    writeFileSync(mobileJoinPath, JSON.stringify({
      schema: 1,
      platform: 'mobile',
      artifact: {
        ...source,
        android: {
          artifactReceiptSha256: sha256(androidText),
          apkSha256: androidArtifact.apkSha256,
          installedApkSha256: androidArtifact.installedApkSha256,
          package: androidArtifact.package,
          signerCertificateSha256:
            androidArtifact.signerCertificateSha256,
        },
        ios: {
          artifactReceiptSha256: sha256(iosText),
          appBundleTreeSha256: iosArtifact.appBundleTreeSha256,
          appCodeDirectoryHash: iosArtifact.appCodeDirectoryHash,
          packetTunnelCodeDirectoryHash:
            iosArtifact.packetTunnelCodeDirectoryHash,
          appExecutableSha256: iosArtifact.appExecutableSha256,
          packetTunnelExecutableSha256:
            iosArtifact.packetTunnelExecutableSha256,
          signerCertificateSha256: iosArtifact.signerCertificateSha256,
          installedBundleIdentifier: iosArtifact.installedBundleIdentifier,
        },
      },
      publicUiOnly: true,
      opticalCameraQr: true,
      privateAppStateRead: false,
      appLaunchArgumentsOrEnvironment: false,
      desktopMobileManual: true,
      deliveryDeadlineMilliseconds: 15_000,
      deliveryMilliseconds: {
        'iPhone-admin-to-Pixel-QR': 100,
        'Pixel-admin-to-iPhone-QR': 100,
        'iPhone-admin-to-Pixel-manual': 100,
        'Pixel-admin-to-iPhone-manual': 100,
      },
      qr: {
        iphoneAdminPixelJoiner: true,
        pixelAdminIphoneJoiner: true,
        pendingQrBackgroundForeground: true,
        exactRosterOnBothSides: true,
        joinerRelaunchDurable: true,
      },
      manual: {
        iphoneAdminPixelJoiner: true,
        pixelAdminIphoneJoiner: true,
        exactRosterOnBothSides: true,
        acceptedRosterOnly: true,
        joinerRelaunchDurable: true,
      },
    }))
    const macosArtifact = {
      ...source,
      receiptSchema: 1,
      companySigningVerified: true,
      builtOnHost: true,
      builtOnTestVm: false,
      appExecutableSha256: '9'.repeat(64),
      cliExecutableSha256: 'a'.repeat(64),
    }
    const macosText = JSON.stringify(macosArtifact)
    writeFileSync(paths.macos.artifact, macosText)
    writeFileSync(paths.macos.public_ui_join, JSON.stringify({
      ...source,
      schema: 1,
      platform: 'macos',
      artifact: {
        ...source,
        artifactReceiptSha256: sha256(macosText),
        appExecutableSha256: macosArtifact.appExecutableSha256,
      },
      publicUiOnly: true,
      privateAppStateRead: false,
      privateStateRead: false,
      fixtureInvoked: false,
      acceptedSelectorSemantics: 'participant-state-not-pending',
      appLaunchArgumentsOrEnvironment: false,
      desktopAdminAndroidJoiner: true,
      androidAdminDesktopJoiner: true,
      exactRosterOnBothSides: true,
      acceptedRosterRetainedAcrossRelaunch: true,
      desktopRelaunchDurability: true,
      pixelRelaunchDurability: true,
      deliveryDeadlineMilliseconds: 15_000,
      deliveryMilliseconds: {
        'macOS-admin-to-Android-manual': 100,
        'Android-admin-to-macOS-manual': 100,
      },
    }))
    writeFileSync(paths.macos.network, JSON.stringify({
      ...source,
      receiptSchema: 1,
      artifactType: 'macos Release desktop network gate',
      platform: 'macos',
      summary: {
        artifactReceiptSha256: sha256(macosText),
        dnsPolicyCount: 5,
        dnsUiPolicyCount: 5,
        dnsUiCases: desktopDnsUiCases(
          macosArtifact.appExecutableSha256,
          macosArtifact.cliExecutableSha256,
        ),
        handoffRecoveryMilliseconds: [100, 200],
        crashRestartPayloadMilliseconds: 300,
        directRestored: true,
        singletonAfterCrashRecovery: true,
      },
      evidenceFiles: { 'direct.txt': 'f'.repeat(64) },
      desktopDnsUiEvidenceFiles,
    }))
    const mobileJoinSha = sha256(readFileSync(mobileJoinPath))
    const macosJoinSha = sha256(readFileSync(paths.macos.public_ui_join))
    const iosWgSha = sha256(readFileSync(paths.ios.wireguard_dns))
    const iosUnderlaySha = sha256(
      readFileSync(paths.ios.underlay_lifecycle),
    )
    writeFileSync(paths.ios.frozen_archive, JSON.stringify({
      ...source,
      receiptSchema: 1,
      artifactType: 'iOS frozen archive physical-gate seal',
      mobileArtifactReceiptSha256: sha256(iosText),
      requiredRealDeviceGates: [
        'background-foreground-and-rapid-start-stop',
        'bidirectional-mobile-qr-and-manual-join',
        'desktop-mobile-manual-join',
        'wifi-hotspot-underlay-roaming',
        'wireguard-exit-and-five-dns-policies',
      ],
      realDeviceGateReceiptSha256: {
        'background-foreground-and-rapid-start-stop': [
          iosWgSha,
          iosUnderlaySha,
        ],
        'bidirectional-mobile-qr-and-manual-join': [mobileJoinSha],
        'desktop-mobile-manual-join': [macosJoinSha],
        'wifi-hotspot-underlay-roaming': [iosUnderlaySha],
        'wireguard-exit-and-five-dns-policies': [iosWgSha],
      },
    }))
    for (const platform of ['linux', 'windows']) {
      const desktopArtifact = {
        ...source,
        schema: 1,
        fipsVersion: '0.4.45',
        appVersion: '4.1.5',
        artifacts: {
          app: { sha256: 'a'.repeat(64), size: 100 },
          cli: { sha256: 'b'.repeat(64), size: 200 },
          ...(platform === 'linux'
            ? {
                debianPackage: { sha256: 'c'.repeat(64), size: 300 },
                muslCli: { sha256: 'd'.repeat(64), size: 400 },
                muslCliArchive: {
                  sha256: 'e'.repeat(64),
                  size: 500,
                },
              }
            : {}),
          ...(platform === 'windows'
            ? {
                appCore: { sha256: 'c'.repeat(64), size: 300 },
                wintun: { sha256: 'd'.repeat(64), size: 400 },
              }
            : {}),
        },
      }
      const desktopArtifactText = JSON.stringify(desktopArtifact)
      writeFileSync(paths[platform].artifact, desktopArtifactText)
      if (platform === 'windows') {
        writeFileSync(paths.windows.installer, JSON.stringify({
          ...source,
          receiptSchema: 1,
          platform: 'windows',
          artifactType: 'exact installed Windows Release setup',
          tag: `v${desktopArtifact.appVersion}`,
          installerName:
            `nostr-vpn-v${desktopArtifact.appVersion}-windows-x64-setup.exe`,
          installerSha256: 'e'.repeat(64),
          installerSize: 500,
          installerInstalledAndLaunched: true,
          installedAppStayedAlive: true,
          smokeReceiptSha256: 'f'.repeat(64),
          payloads: Object.fromEntries(
            ['app', 'appCore', 'cli', 'wintun'].map((name) => [
              name,
              desktopArtifact.artifacts[name],
            ]),
          ),
          builtOnWindowsVm: true,
          builtOnHostMac: false,
        }))
      }
      if (platform === 'linux') {
        writeFileSync(paths.linux.package_install, JSON.stringify({
          ...source,
          schema: 1,
          artifactType:
            'host-built exact Debian package installed on Ubuntu VM',
          appVersion: desktopArtifact.appVersion,
          builtOnHostMac: true,
          builtOnRemoteVm: false,
          package: 'nostr-vpn',
          packageArchitecture: 'amd64',
          packageInstalledByDpkg: true,
          installedStatus: 'installed',
          installedAppPath: '/usr/bin/nostr-vpn',
          installedCliPath: '/usr/bin/nvpn',
          debSha256: desktopArtifact.artifacts.debianPackage.sha256,
          debSize: desktopArtifact.artifacts.debianPackage.size,
          installedAppSha256: desktopArtifact.artifacts.app.sha256,
          installedCliSha256: desktopArtifact.artifacts.cli.sha256,
          muslCliSha256: desktopArtifact.artifacts.muslCli.sha256,
          muslArchiveSha256:
            desktopArtifact.artifacts.muslCliArchive.sha256,
          bundleReceiptSha256: sha256(desktopArtifactText),
          packagePayloadVerifiedBeforeInstall: true,
          desktopEntryPresent: true,
          iconThemeAssetPresent: true,
          muslArchiveExtractedAndExecuted: true,
        }))
      }
      writeFileSync(paths[platform].public_ui_join, JSON.stringify({
        ...source,
        schema: 1,
        platform,
        artifact: {
          ...source,
          fipsVersion: desktopArtifact.fipsVersion,
          desktop: {
            appSha256: desktopArtifact.artifacts.app.sha256,
            appSize: desktopArtifact.artifacts.app.size,
            cliSha256: desktopArtifact.artifacts.cli.sha256,
            cliSize: desktopArtifact.artifacts.cli.size,
            appVersion: desktopArtifact.appVersion,
            ...(platform === 'windows'
              ? {
                  appCoreSha256:
                    desktopArtifact.artifacts.appCore.sha256,
                  appCoreSize: desktopArtifact.artifacts.appCore.size,
                }
              : {}),
          },
          android: {
            apkSha256: androidArtifact.apkSha256,
            apkSize: 400,
            signerCertificateSha256:
              androidArtifact.signerCertificateSha256,
            package: androidArtifact.package,
          },
        },
        publicUiOnly: true,
        privateStateRead: false,
        fixtureInvoked: false,
        appLaunchArgumentsOrEnvironment: false,
        acceptedSelectorSemantics: 'participant-state-not-pending',
        desktopRelaunchDurability: true,
        pixelRelaunchDurability: true,
        completionDeadlineSeconds: 15,
        desktopAdminPixelJoiner: {
          desktopAccepted: true,
          pixelAccepted: true,
          desktopRelaunchAccepted: true,
          pixelRelaunchAccepted: true,
          deliveryMilliseconds: 100,
        },
        pixelAdminDesktopJoiner: {
          desktopAccepted: true,
          pixelAccepted: true,
          desktopRelaunchAccepted: true,
          pixelRelaunchAccepted: true,
          deliveryMilliseconds: 100,
        },
      }))
      writeFileSync(paths[platform].network, JSON.stringify({
        ...source,
        receiptSchema: 1,
        artifactType: `${platform} Release desktop network gate`,
        platform,
        summary: {
          dnsPolicyCount: 5,
          dnsUiPolicyCount: 5,
          dnsUiCases: desktopDnsUiCases(
            desktopArtifact.artifacts.app.sha256,
            desktopArtifact.artifacts.cli.sha256,
          ),
          dnsCases: {
            automatic: desktopDnsCase('cloudflare'),
            cloudflare: desktopDnsCase('cloudflare'),
            custom: desktopDnsCase('google'),
            quad9: desktopDnsCase('quad9'),
            'through-exit': desktopDnsCase('fixture_dns'),
          },
          handoffs: {
            primaryToSecondary: {
              recoveryMilliseconds: 100,
              payloadDelta: 1,
              wireGuardPayloadDelta: 1,
              rebindDelta: 1,
            },
            secondaryToPrimary: {
              recoveryMilliseconds: 100,
              payloadDelta: 1,
              wireGuardPayloadDelta: 1,
              rebindDelta: 1,
            },
          },
          directRestored: true,
          singletonAfterCrashRecovery: true,
          testedCliSha256: desktopArtifact.artifacts.cli.sha256,
          testedCliSize: desktopArtifact.artifacts.cli.size,
          ...(platform === 'linux'
            ? {
                crashRepairMilliseconds: 100,
                artifactReceiptSha256: sha256(desktopArtifactText),
              }
            : { nativeWireGuardOwnerFilesRepaired: true }),
        },
        evidenceFiles: { 'direct-receipt.json': 'f'.repeat(64) },
        desktopDnsUiEvidenceFiles,
      }))
    }

    const evidence = collectReleaseGateReceipts({
      commit,
      tree,
      releaseGateSummaryPath: summary,
      platformReceiptPaths: paths,
    })
    assert.deepEqual(
      Object.keys(evidence.platformGateReceipts).sort(),
      ['android', 'ios', 'linux', 'macos', 'windows'],
    )

    const windowsInstaller = readFileSync(
      paths.windows.installer,
      'utf8',
    )
    const replacedWindowsInstaller = JSON.parse(windowsInstaller)
    replacedWindowsInstaller.installerInstalledAndLaunched = false
    writeFileSync(
      paths.windows.installer,
      JSON.stringify(replacedWindowsInstaller),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /Windows exact installer gate receipt is incomplete/,
    )
    writeFileSync(paths.windows.installer, windowsInstaller)

    const mismatchedWindowsPayload = JSON.parse(windowsInstaller)
    mismatchedWindowsPayload.payloads.cli.sha256 = '0'.repeat(64)
    writeFileSync(
      paths.windows.installer,
      JSON.stringify(mismatchedWindowsPayload),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /cli payload differs from the real platform gate/,
    )
    writeFileSync(paths.windows.installer, windowsInstaller)

    const androidNetwork = readFileSync(paths.android.wireguard_dns, 'utf8')
    const wrongAndroidDnsPath = JSON.parse(androidNetwork)
    const cloudflare =
      wrongAndroidDnsPath.dnsCases['cloudflare-doh']
    cloudflare.dnsPathCountersAfter.cloudflare =
      cloudflare.dnsPathCountersBefore.cloudflare
    cloudflare.dnsPathCountersAfter.query =
      cloudflare.dnsPathCountersBefore.query + 1
    writeFileSync(
      paths.android.wireguard_dns,
      JSON.stringify(wrongAndroidDnsPath),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /used the wrong (query|cloudflare) DNS path/,
    )
    writeFileSync(paths.android.wireguard_dns, androidNetwork)

    const linuxPackageInstall = readFileSync(
      paths.linux.package_install,
      'utf8',
    )
    const wrongDebPackage = JSON.parse(linuxPackageInstall)
    wrongDebPackage.debSha256 = '0'.repeat(64)
    writeFileSync(
      paths.linux.package_install,
      JSON.stringify(wrongDebPackage),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /Debian package was not installed and verified/,
    )
    writeFileSync(paths.linux.package_install, linuxPackageInstall)

    const windowsNetwork = readFileSync(paths.windows.network, 'utf8')
    const tamperedWindowsNetwork = JSON.parse(windowsNetwork)
    tamperedWindowsNetwork.summary.directRestored = false
    writeFileSync(
      paths.windows.network,
      JSON.stringify(tamperedWindowsNetwork),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /desktop network summary is incomplete/,
    )
    writeFileSync(paths.windows.network, windowsNetwork)

    const wrongDesktopDnsPath = JSON.parse(windowsNetwork)
    wrongDesktopDnsPath.summary.dnsCases.cloudflare.after_quad9 = 2
    writeFileSync(
      paths.windows.network,
      JSON.stringify(wrongDesktopDnsPath),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /cloudflare used the wrong DNS resolver path/,
    )
    writeFileSync(paths.windows.network, windowsNetwork)

    const wrongWindowsDnsUiArtifact = JSON.parse(windowsNetwork)
    wrongWindowsDnsUiArtifact.summary.dnsUiCases.quad9.appExecutableSha256 =
      '0'.repeat(64)
    writeFileSync(
      paths.windows.network,
      JSON.stringify(wrongWindowsDnsUiArtifact),
    )
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /quad9 DNS UI readback is not bound to the exact gated app and CLI/,
    )
    writeFileSync(paths.windows.network, windowsNetwork)

    writeFileSync(paths.windows.public_ui_join, JSON.stringify({
      ...source,
      schema: 1,
      platform: 'windows',
      publicUiOnly: true,
      privateStateRead: true,
      fixtureInvoked: false,
      acceptedSelectorSemantics: 'participant-state-not-pending',
      desktopRelaunchDurability: true,
      pixelRelaunchDurability: true,
    }))
    assert.throws(
      () => collectReleaseGateReceipts({
        commit,
        tree,
        releaseGateSummaryPath: summary,
        platformReceiptPaths: paths,
      }),
      /strict real public-UI join receipt/,
    )
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('desktop evidence builder accepts the real repeated five-case DNS ledger', () => {
  const root = mkdtempSync(join(tmpdir(), 'nvpn-desktop-evidence-test-'))
  try {
    const commit = 'a'.repeat(40)
    const tree = 'b'.repeat(40)
    write(
      join(root, 'source-provenance.txt'),
      `nvpn_base_commit=${commit}\nnvpn_tree=${tree}\n`,
    )
    const testedCliSha256 = 'c'.repeat(64)
    const testedCliSize = 123
    const testedArtifactReceipt = JSON.stringify({
      schema: 1,
      appGitSha: commit,
      appGitTree: tree,
      artifacts: {
        cli: {
          sha256: testedCliSha256,
          size: testedCliSize,
        },
      },
    })
    write(
      join(root, 'tested-artifact-receipt.json'),
      testedArtifactReceipt,
    )
    write(
      join(root, 'tested-artifact.json'),
      JSON.stringify({
        cliSha256: testedCliSha256,
        cliSize: testedCliSize,
        artifactReceiptSha256: sha256(testedArtifactReceipt),
      }),
    )
    const handoff = JSON.stringify({
      recovery_milliseconds: 100,
      payload_successes_before: 1,
      payload_successes_after: 2,
      wireguard_payload_successes_before: 1,
      wireguard_payload_successes_after: 2,
      rebind_receipts_before: 1,
      rebind_receipts_after: 2,
    })
    write(join(root, 'secondary-receipt.json'), handoff)
    write(join(root, 'primary-receipt.json'), handoff)
    write(
      join(root, 'dns-matrix.txt'),
      [
        ['automatic', 'cloudflare'],
        ['cloudflare', 'cloudflare'],
        ['quad9', 'quad9'],
        ['custom', 'google'],
        ['through-exit', 'fixture_dns'],
      ].flatMap(([name, expectedCounter]) => [
        `case=${name}`,
        ...desktopDnsCounterNames.flatMap((counter) => [
          `before_${counter}=1`,
          `after_${counter}=${counter === expectedCounter ? 2 : 1}`,
        ]),
      ]).join('\n') + '\n',
    )
    write(join(root, 'direct-receipt.json'), JSON.stringify({
      wireguard_interface_removed: true,
      wireguard_endpoint_route_removed: true,
      wireguard_policy_rule_removed: true,
      wireguard_policy_table_empty: true,
      verified_https: true,
    }))
    write(join(root, 'crash-repair-receipt.json'), JSON.stringify({
      sigkill_exit_code: 137,
      fresh_wireguard_handshake: true,
      through_exit_dns_before_crash: true,
      verified_https_before_crash: true,
      cleanup_journal_survived_sigkill: true,
      startup_repair_without_explicit_command: true,
      cleanup_journal_removed: true,
      physical_default_restored: true,
      public_dns_restored: true,
      verified_https_after_restart: true,
      restart_daemon_count: 1,
      restart_repair_milliseconds: 100,
    }))
    const dnsUiDir = join(root, 'dns-ui')
    const dnsUiSettings = {
      automatic: ['automatic', 'cloudflare', '', '', ''],
      cloudflare: ['encrypted', 'cloudflare', '', '', ''],
      quad9: ['encrypted', 'quad9', '', '', ''],
      custom: [
        'encrypted',
        'custom',
        'https://dns.google/dns-query',
        '8.8.8.8,8.8.4.4',
        '',
      ],
      'through-exit': [
        'through_exit',
        'cloudflare',
        '',
        '',
        '10.99.79.53',
      ],
    }
    for (const [dnsCase, values] of Object.entries(dnsUiSettings)) {
      const [
        exitDnsMode,
        exitDnsDohProvider,
        exitDnsCustomDohUrl,
        exitDnsCustomDohBootstrapIps,
        exitDnsThroughExitServers,
      ] = values
      write(join(dnsUiDir, `${dnsCase}.json`), JSON.stringify({
        receiptSchema: 1,
        platform: 'linux',
        case: dnsCase,
        evidenceSource: 'shipped-ui-restart-readback',
        savedViaShippedUi: true,
        uiRestartReadback: true,
        releaseBlackbox: true,
        publicUiOnly: true,
        privateStateRead: false,
        appGitSha: commit,
        appGitTree: tree,
        appExecutableSha256: 'd'.repeat(64),
        cliExecutableSha256: testedCliSha256,
        exitDnsMode,
        exitDnsDohProvider,
        exitDnsCustomDohUrl,
        exitDnsCustomDohBootstrapIps,
        exitDnsThroughExitServers,
      }))
    }
    const output = join(root, 'receipt.json')
    const result = spawnSync(
      'python3',
      [
        join(process.cwd(), 'scripts/release-network-evidence.py'),
        'desktop',
        '--platform',
        'linux',
        '--artifact-dir',
        root,
        '--dns-ui-dir',
        dnsUiDir,
        '--app-git-sha',
        commit,
        '--app-git-tree',
        tree,
        '--output',
        output,
      ],
      { encoding: 'utf8' },
    )
    assert.equal(result.status, 0, result.stderr)
    const receipt = JSON.parse(readFileSync(output, 'utf8'))
    assert.equal(receipt.summary.dnsPolicyCount, 5)
    assert.equal(receipt.summary.directRestored, true)
    assert.equal(receipt.summary.singletonAfterCrashRecovery, true)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('StartOS post-build proof requires the real exact-package inspector result', () => {
  const asset = {
    path: 'assets/nostr-vpn-v4.1.5-startos-x86_64.s9pk',
    sha256: 'a'.repeat(64),
    size: 42,
  }
  const receipts = Object.fromEntries(
    ['android', 'ios', 'linux', 'macos', 'windows'].map(
      (platform, index) => [
        platform,
        { gate: String(index + 1).padStart(64, '0') },
      ],
    ),
  )
  const baseProof = {
    platform: 'startos',
    verification: 'post-build-exact-package-gate',
    artifact_sha256: asset.sha256,
    gate_receipt_sha256: 'f'.repeat(64),
    payloads: {
      manifest_json: 'b'.repeat(64),
      package: asset.sha256,
    },
  }
  const build = (proof) => buildReleaseGateAttestation({
    commit: 'c'.repeat(40),
    tree: 'd'.repeat(40),
    assets: [asset],
    releaseGateSummarySha256: 'f'.repeat(64),
    platformGateReceipts: receipts,
    assetProofs: { [asset.path]: proof },
  })

  assert.throws(
    () => build(baseProof),
    /lacks a real exact-package StartOS validation/,
  )
  assert.doesNotThrow(() => build({
    ...baseProof,
    post_build_validator: startosExactPackageValidator,
  }))
  assert.throws(
    () => build({
      ...baseProof,
      post_build_validator: startosExactPackageValidator,
      payloads: {
        ...baseProof.payloads,
        package: 'e'.repeat(64),
      },
    }),
    /lacks a real exact-package StartOS validation/,
  )
})
