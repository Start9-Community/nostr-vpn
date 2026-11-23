import { utils, type T } from '@start9labs/start-sdk'
import { sdk } from './sdk'

export const controlPanelPort = 38080

// Loopback sockets conflict with wildcard mesh listeners even when those bind utun100.
export const findControlPanelBackendPort = (meshPorts: number[]) => {
  const unavailable = new Set([controlPanelPort, ...meshPorts])
  for (let port = 65535; port > 0; port--) {
    if (!unavailable.has(port)) return port
  }
  throw new Error('No TCP port is available for the control panel.')
}

export const controlPanelUsername = 'admin'

export const meshStatusPath = '/data/mesh-status.json'

export const configPath = '/data/config/nvpn/config.toml'

export const dataMount = sdk.Mounts.of().mountVolume({
  volumeId: 'main',
  subpath: null,
  mountpoint: '/data',
  readonly: false,
})

export const findIface = (host: utils.FilledHost | null, interfaceId: string) =>
  Object.values(host?.bindings ?? {})
    .flatMap((b) => Object.values(b.interfaces))
    .find((i) => i.id === interfaceId)

/** The IPv4 LXC-bridge `{ hostname, port }` another container reaches this binding at. */
export const bridgeHost = (
  host: utils.FilledHost | null,
  internalPort: number,
  ssl: boolean,
) => {
  const iface = Object.values(
    host?.bindings?.[internalPort]?.interfaces ?? {},
  )[0]
  return iface
    ? iface.addressInfo.filter({
        kind: 'bridge',
        predicate: (h) => h.metadata.kind === 'ipv4' && h.ssl === ssl,
      }).hostnames[0]
    : undefined
}

export const hostFor = (
  effects: T.Effects,
  target: { packageId: string; hostId: string },
) => sdk.host.get(effects, target).once()
