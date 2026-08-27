import { setControlPanelPassword } from '../actions/setControlPanelPassword'
import { storeJson } from '../fileModels/store.json'
import { i18n } from '../i18n'
import { sdk } from '../sdk'

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
