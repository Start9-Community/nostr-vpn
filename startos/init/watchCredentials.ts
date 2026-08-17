import { setControlPanelPassword } from '../actions/setControlPanelPassword'
import { storeJson } from '../fileModels/store.json'
import { i18n } from '../i18n'
import { sdk } from '../sdk'

// Block startup until the user sets a control panel password. While
// controlPanelPassword is unset the `control-panel` interface has no auth gate,
// so a critical task forces the user to run setControlPanelPassword before the
// service can start. Idempotent on its replay key, so this is safe to re-run on
// every container rebuild.
export const watchCredentials = sdk.setupOnInit(async (effects) => {
  const store = await storeJson.read().const(effects)

  if (!store?.controlPanelPassword) {
    await sdk.action.createOwnTask(
      effects,
      setControlPanelPassword,
      'critical',
      {
        reason: i18n(
          'Set a password before opening the Nostr VPN control panel',
        ),
      },
    )
  }
})
