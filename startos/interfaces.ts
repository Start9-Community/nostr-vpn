import { storeJson } from './fileModels/store.json'
import { i18n } from './i18n'
import { sdk } from './sdk'
import { controlPanelPort, controlPanelUsername } from './utils'

export const setInterfaces = sdk.setupInterfaces(async ({ effects }) => {
  // Read reactively: when setControlPanelPassword writes controlPanelPassword,
  // this re-runs and the proxy picks up the new credential. Until then auth is
  // null — but a critical install task (watchCredentials) blocks startup until
  // the password is set, so the control panel is never exposed ungated.
  const password = await storeJson
    .read((s) => s.controlPanelPassword)
    .const(effects)

  const controlPanelMulti = sdk.MultiHost.of(effects, 'control-panel-multi')
  const controlPanelOrigin = await controlPanelMulti.bindPort(
    controlPanelPort,
    {
      protocol: 'http',
      addSsl: {
        auth: password
          ? {
              type: 'basic',
              credentials: [{ username: controlPanelUsername, password }],
              realm: null,
            }
          : null,
      },
    },
  )
  const controlPanel = sdk.createInterface(effects, {
    name: i18n('Control Panel'),
    id: 'control-panel',
    description: i18n('Open the Nostr VPN control panel'),
    type: 'ui',
    masked: false,
    schemeOverride: null,
    username: null,
    path: '',
    query: {},
  })

  return [await controlPanelOrigin.export([controlPanel])]
})
