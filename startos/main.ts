import { Daemons } from '@start9labs/start-sdk'
import { exposureId, exposures } from './fileModels/exposures.json'
import { i18n } from './i18n'
import { manifest } from './manifest'
import { sdk } from './sdk'
import {
  bridgeHost,
  configPath,
  controlPanelPort,
  dataMount,
  findControlPanelBackendPort,
  hostFor,
  meshStatusPath,
} from './utils'

const commonEnv = {
  HOME: '/data/home',
  XDG_CONFIG_HOME: '/data/config',
  RUST_LOG: 'info',
}

export const main = sdk.setupMain(async ({ effects }) => {
  console.info(i18n('Starting Nostr VPN'))

  // Reactive: sharing or unsharing a service rewrites this list, which re-runs
  // main and rebuilds the forwarder set.
  const shared = (await exposures.read((e) => e.exposures).const(effects)) ?? []
  const controlPanelBackendPort = findControlPanelBackendPort(
    shared.map((e) => e.meshPort),
  )

  const daemonSub = sdk.SubContainer.of(
    effects,
    { imageId: 'app' },
    dataMount,
    'nostr-vpn-daemon',
  )
  const controlPanelSub = sdk.SubContainer.of(
    effects,
    { imageId: 'app' },
    dataMount,
    'nostr-vpn-control-panel',
  )

  let daemons: Daemons<typeof manifest, string> = sdk.Daemons.of(effects)

  daemons = daemons.addOneshot('prepare-data' as never, {
    subcontainer: daemonSub,
    exec: {
      command: ['mkdir', '-p', '/data/home', '/data/config/nvpn'],
      user: 'root',
    },
    requires: [],
  })

  daemons = daemons.addDaemon('daemon' as never, {
    subcontainer: daemonSub,
    exec: {
      command: ['/usr/local/bin/nvpn', 'daemon', '--config', configPath],
      env: commonEnv,
    },
    ready: {
      display: i18n('Mesh daemon'),
      fn: () =>
        sdk.healthCheck.runHealthScript(
          ['/usr/local/bin/nvpn', 'status', '--config', configPath],
          daemonSub,
          {
            message: () => i18n('The mesh daemon is running'),
            errorMessage: i18n('The mesh daemon is not running'),
          },
        ),
    },
    requires: ['prepare-data'],
  })

  // The panel itself listens on loopback only. The daemon's utun100 shares this
  // network namespace, so a socket bound to eth0's address would still accept a
  // packet a mesh peer routes to that address. The listener in front is bound to
  // eth0 with SO_BINDTODEVICE, so only connections arriving on eth0 (the StartOS
  // proxy) reach it.
  daemons = daemons.addDaemon('control-panel' as never, {
    subcontainer: controlPanelSub,
    exec: {
      command: [
        '/usr/local/bin/nvpn-web',
        '--listen',
        `127.0.0.1:${controlPanelBackendPort}`,
        '--behind-trusted-proxy',
        '--config',
        configPath,
      ],
      env: {
        ...commonEnv,
        NVPN_CLI_PATH: '/usr/local/bin/nvpn',
        NVPN_DAEMON_STATUS_MODE: 'state-file',
        NVPN_EXTERNAL_DAEMON: 'true',
      },
    },
    ready: {
      display: null,
      fn: () =>
        sdk.healthCheck.checkPortListening(effects, controlPanelBackendPort, {
          successMessage: i18n('The control panel is ready'),
          errorMessage: i18n('The control panel is not ready'),
        }),
    },
    requires: ['daemon'],
  })

  daemons = daemons.addDaemon('control-panel-listener' as never, {
    subcontainer: controlPanelSub,
    exec: {
      command: [
        'socat',
        `TCP4-LISTEN:${controlPanelPort},so-bindtodevice=eth0,fork,reuseaddr`,
        `TCP4:127.0.0.1:${controlPanelBackendPort}`,
      ],
    },
    ready: {
      display: i18n('Control Panel'),
      fn: () =>
        sdk.healthCheck.checkPortListening(effects, controlPanelPort, {
          successMessage: i18n('The control panel is ready'),
          errorMessage: i18n('The control panel is not ready'),
        }),
    },
    requires: ['control-panel'],
  })

  // The url-v0 exports need this node's mesh address, which only the daemon
  // knows — and it reports a placeholder until the tunnel settles, so this polls
  // rather than snapshotting once. Written in place so the host-side FileHelper
  // watch keeps its inode.
  daemons = daemons.addDaemon('mesh-status' as never, {
    subcontainer: daemonSub,
    exec: {
      command: [
        'sh',
        '-c',
        `while :; do /usr/local/bin/nvpn status --json --config ${configPath} > ${meshStatusPath} 2>/dev/null || true; sleep 15; done`,
      ],
      env: commonEnv,
    },
    ready: {
      display: null,
      fn: async () => ({ result: 'success' as const, message: null }),
    },
    requires: ['daemon'],
  })

  // One forwarder per shared service, bound to the mesh device so the service is
  // reachable from mesh peers and from nowhere else. nvpn tears down and recreates
  // utun100 when the first peer joins, which drops a device-bound socket — so the
  // supervisor re-execs socat whenever the interface index changes.
  for (const e of shared) {
    const addr = bridgeHost(await hostFor(effects, e), e.internalPort, e.ssl)
    if (!addr) continue

    daemons = daemons.addDaemon(`share-${exposureId(e)}` as never, {
      subcontainer: daemonSub,
      exec: {
        command: [
          'sh',
          '-c',
          [
            'while :; do',
            '  until [ -e /sys/class/net/utun100 ]; do sleep 1; done',
            '  idx=$(cat /sys/class/net/utun100/ifindex)',
            `  socat TCP-LISTEN:${e.meshPort},so-bindtodevice=utun100,fork,reuseaddr TCP:${addr.hostname}:${addr.port} &`,
            '  sp=$!',
            '  while [ "$(cat /sys/class/net/utun100/ifindex 2>/dev/null)" = "$idx" ]; do sleep 5; done',
            '  kill $sp 2>/dev/null || true',
            '  wait $sp 2>/dev/null || true',
            'done',
          ].join('\n'),
        ],
      },
      ready: {
        display: null,
        fn: () =>
          sdk.healthCheck.checkPortListening(effects, e.meshPort, {
            successMessage: i18n('A shared service is reachable'),
            errorMessage: i18n('A shared service is not reachable'),
          }),
      },
      requires: ['daemon'],
    })
  }

  return daemons
})
