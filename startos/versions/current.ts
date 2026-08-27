import { IMPOSSIBLE, VersionInfo } from '@start9labs/start-sdk'

export const current = VersionInfo.of({
  version: '4.1.8:0',
  releaseNotes: {
    en_US: 'Initial StartOS package for Nostr VPN.',
    es_ES: 'Paquete inicial de StartOS para Nostr VPN.',
    de_DE: 'Erstes StartOS-Paket für Nostr VPN.',
    pl_PL: 'Pierwszy pakiet StartOS dla Nostr VPN.',
    fr_FR: 'Premier paquet StartOS pour Nostr VPN.',
  },
  migrations: {
    up: async () => {},
    down: IMPOSSIBLE,
  },
})
