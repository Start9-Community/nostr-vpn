import { IMPOSSIBLE, VersionInfo } from '@start9labs/start-sdk'

export const current = VersionInfo.of({
  version: '4.1.18:0',
  releaseNotes: {
    en_US:
      'Updated Nostr VPN to 4.1.18, which improves peer discovery, network joining and paid Internet connections.',
    es_ES:
      'Nostr VPN se actualizó a 4.1.18, que mejora el descubrimiento de pares, la incorporación a redes y las conexiones a Internet de pago.',
    de_DE:
      'Nostr VPN wurde auf 4.1.18 aktualisiert, das die Peer-Erkennung, den Netzwerkbeitritt und kostenpflichtige Internetverbindungen verbessert.',
    pl_PL:
      'Zaktualizowano Nostr VPN do wersji 4.1.18, która usprawnia wykrywanie węzłów, dołączanie do sieci i płatne połączenia z Internetem.',
    fr_FR:
      "Nostr VPN est mis à jour vers 4.1.18, qui améliore la découverte des pairs, l'adhésion aux réseaux et les connexions Internet payantes.",
  },
  migrations: {
    up: async () => {},
    down: IMPOSSIBLE,
  },
})
