export const DEFAULT_LANG = 'en_US'

const dict = {
  // main.ts
  'Starting Nostr VPN': 0,
  'Mesh daemon': 1,
  'The mesh daemon is running': 2,
  'The mesh daemon is not running': 3,
  'Control Panel': 4,
  'The control panel is ready': 5,
  'The control panel is not ready': 6,

  // interfaces.ts
  'Open the Nostr VPN control panel': 7,

  // actions/setControlPanelPassword.ts
  'Set Control Panel Password': 8,
  'Generate a new random password for the Nostr VPN control panel. This replaces any existing password.': 9,
  'Nostr VPN Control Panel Credentials': 10,
  'Use these credentials to open the Nostr VPN control panel.': 11,
  Username: 12,
  Password: 13,

  // init/watchCredentials.ts
  'Set a password before opening the Nostr VPN control panel': 14,
} as const

/**
 * Plumbing. DO NOT EDIT.
 */
export type I18nKey = keyof typeof dict
export type LangDict = Record<(typeof dict)[I18nKey], string>
export default dict
