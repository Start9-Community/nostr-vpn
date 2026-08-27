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
  // actions/exposeOverMesh.ts
  'Share Over Nostr VPN': 15,
  'Make this interface reachable from your other Nostr VPN devices, at this server’s mesh address. Nothing is published to the internet.': 16,
  Port: 17,
  'The port your other devices will use to reach this service over the mesh.': 18,
  'That interface no longer exists.': 19,
  'That interface is not reachable from this server.': 20,
  'Port ${port} is already shared over Nostr VPN.': 21,
  'Shared Over Nostr VPN': 22,
  'Saved. The address appears in this service’s list once the mesh is up.': 23,

  // actions/stopSharingOverMesh.ts
  'Stop Sharing Over Nostr VPN': 24,
  'Stop making this interface reachable from your other Nostr VPN devices.': 25,
  'No Longer Shared': 26,
  'That service is no longer reachable over Nostr VPN.': 27,

  // main.ts — shared-service forwarders
  'A shared service is reachable': 28,
  'A shared service is not reachable': 29,
} as const

/**
 * Plumbing. DO NOT EDIT.
 */
export type I18nKey = keyof typeof dict
export type LangDict = Record<(typeof dict)[I18nKey], string>
export default dict
