import { utils } from '@start9labs/start-sdk'
import { storeJson } from '../fileModels/store.json'
import { i18n } from '../i18n'
import { sdk } from '../sdk'
import { controlPanelUsername } from '../utils'

export const setControlPanelPassword = sdk.Action.withoutInput(
  'set-control-panel-password',

  async () => ({
    name: i18n('Set Control Panel Password'),
    description: i18n(
      'Generate a new random password for the Nostr VPN control panel. This replaces any existing password.',
    ),
    warning: null,
    allowedStatuses: 'any',
    group: null,
    visibility: 'enabled',
  }),

  async ({ effects }) => {
    const password = utils.getDefaultString({ charset: 'a-z,A-Z,1-9', len: 22 })

    // Writing controlPanelPassword re-runs setInterfaces, so the OS proxy
    // enforces the new credential without a restart. This is the only place that
    // generates and stores it — covering both first-set (via the critical
    // install task) and later rotation.
    await storeJson.merge(effects, { controlPanelPassword: password })

    return {
      version: '1',
      title: i18n('Nostr VPN Control Panel Credentials'),
      message: i18n(
        'Use these credentials to open the Nostr VPN control panel.',
      ),
      result: {
        type: 'group',
        value: [
          {
            type: 'single',
            name: i18n('Username'),
            description: null,
            value: controlPanelUsername,
            masked: false,
            copyable: true,
            qr: false,
          },
          {
            type: 'single',
            name: i18n('Password'),
            description: null,
            value: password,
            masked: true,
            copyable: true,
            qr: false,
          },
        ],
      },
    }
  },
)
