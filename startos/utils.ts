import { sdk } from './sdk'

export const controlPanelPort = 38080

// Fixed username for the proxy-enforced basic-auth gate on the `control-panel`
// interface. Only the password varies (set via the setControlPanelPassword
// action / critical task); the credential pair is validated by the OS reverse
// proxy, not by nvpn.
export const controlPanelUsername = 'admin'

export const dataMount = sdk.Mounts.of().mountVolume({
  volumeId: 'main',
  subpath: null,
  mountpoint: '/data',
  readonly: false,
})
