import { i18n } from './i18n'
import { sdk } from './sdk'
import { controlPanelPort, dataMount } from './utils'

const commonEnv = {
  HOME: '/data/home',
  XDG_CONFIG_HOME: '/data/config',
  RUST_LOG: 'info',
}

export const main = sdk.setupMain(async ({ effects }) => {
  console.info(i18n('Starting Nostr VPN'))

  const daemonSub = await sdk.SubContainer.of(
    effects,
    { imageId: 'app' },
    dataMount,
    'nostr-vpn-daemon',
  )
  const controlPanelSub = await sdk.SubContainer.of(
    effects,
    { imageId: 'app' },
    dataMount,
    'nostr-vpn-control-panel',
  )

  return sdk.Daemons.of(effects)
    .addOneshot('prepare-data', {
      subcontainer: daemonSub,
      exec: {
        command: ['mkdir', '-p', '/data/home', '/data/config/nvpn'],
        user: 'root',
      },
      requires: [],
    })
    .addDaemon('daemon', {
      subcontainer: daemonSub,
      exec: {
        command: [
          '/usr/local/bin/nvpn',
          'daemon',
          '--paused',
          '--config',
          '/data/config/nvpn/config.toml',
        ],
        env: commonEnv,
      },
      ready: {
        display: i18n('Mesh daemon'),
        fn: () =>
          // `nvpn status` exits 0 only when the daemon answers its control
          // socket — real readiness, not just process presence. It does not
          // require an active network, which is correct for the `--paused` start.
          sdk.healthCheck.runHealthScript(
            [
              '/usr/local/bin/nvpn',
              'status',
              '--config',
              '/data/config/nvpn/config.toml',
            ],
            daemonSub,
            {
              message: () => i18n('The mesh daemon is running'),
              errorMessage: i18n('The mesh daemon is not running'),
            },
          ),
      },
      requires: ['prepare-data'],
    })
    .addDaemon('control-panel', {
      subcontainer: controlPanelSub,
      exec: {
        command: [
          'sh',
          '-ec',
          [
            // Bind the container's own eth0 address rather than 0.0.0.0: the
            // daemon's `utun100` lives in this namespace too, and a wildcard
            // bind would publish the panel to every mesh peer.
            'bind_ip="$(ip -4 -o addr show dev eth0 scope global | awk \'{ split($4, a, "/"); print a[1]; exit }\')"',
            'test -n "$bind_ip"',
            // --behind-trusted-proxy: reached only through the StartOS reverse
            // proxy, so the forwarded client address is the real one.
            `exec /usr/local/bin/nvpn-web --listen "$bind_ip:${controlPanelPort}" --behind-trusted-proxy --config /data/config/nvpn/config.toml`,
          ].join('\n'),
        ],
        env: {
          ...commonEnv,
          NVPN_CLI_PATH: '/usr/local/bin/nvpn',
          NVPN_DAEMON_STATUS_MODE: 'state-file',
          NVPN_EXTERNAL_DAEMON: 'true',
        },
      },
      ready: {
        display: i18n('Control Panel'),
        fn: () =>
          sdk.healthCheck.checkPortListening(effects, controlPanelPort, {
            successMessage: i18n('The control panel is ready'),
            errorMessage: i18n('The control panel is not ready'),
          }),
      },
      requires: ['daemon'],
    })
})
