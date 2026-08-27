import { sdk } from './sdk'

export const controlPanelPort = 38080

export const controlPanelUsername = 'admin'

export const dataMount = sdk.Mounts.of().mountVolume({
  volumeId: 'main',
  subpath: null,
  mountpoint: '/data',
  readonly: false,
})
