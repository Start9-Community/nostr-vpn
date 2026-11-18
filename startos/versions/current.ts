import { IMPOSSIBLE, VersionInfo } from '@start9labs/start-sdk'

export const current = VersionInfo.of({
  version: '4.1.22:0',
  releaseNotes: {
    en_US:
      "Updated Nostr VPN to 4.1.22. Adds resumable peer file transfers, improves joining and reconnections, adapts paid Internet renewals to recent traffic and recovers unused credit. Update both buyer and seller before making new paid-Internet purchases; existing funded agreements remain usable. Improves connection security, stops trusting the compromised certificate authority, protects Internet sellers' private networks and removes network join secrets from diagnostics.",
    es_ES:
      'Nostr VPN se actualizó a 4.1.22. Añade transferencias de archivos reanudables entre pares, mejora la incorporación y las reconexiones, adapta las renovaciones de Internet de pago al tráfico reciente y recupera el crédito no utilizado. Actualice tanto el comprador como el vendedor antes de realizar nuevas compras de Internet de pago; los acuerdos ya financiados siguen siendo utilizables. Mejora la seguridad de las conexiones, deja de confiar en la autoridad de certificación comprometida, protege las redes privadas de los proveedores de Internet y elimina los secretos de incorporación a redes de los diagnósticos.',
    de_DE:
      'Nostr VPN wurde auf 4.1.22 aktualisiert. Fügt fortsetzbare Dateiübertragungen zwischen Peers hinzu, verbessert Netzwerkbeitritt und Wiederverbindungen, passt Verlängerungen kostenpflichtiger Internetverbindungen an den jüngsten Datenverkehr an und gewinnt ungenutztes Guthaben zurück. Für neue Käufe kostenpflichtigen Internetzugangs müssen Käufer und Verkäufer aktualisiert sein; bereits finanzierte Vereinbarungen bleiben nutzbar. Verbessert die Verbindungssicherheit, vertraut der kompromittierten Zertifizierungsstelle nicht mehr, schützt die privaten Netzwerke von Internetanbietern und entfernt Netzwerkbeitrittsgeheimnisse aus Diagnosen.',
    pl_PL:
      'Zaktualizowano Nostr VPN do wersji 4.1.22. Dodano wznawialne przesyłanie plików między węzłami, usprawniono dołączanie do sieci i ponowne połączenia, dostosowano odnawianie płatnego dostępu do Internetu do ostatniego ruchu i odzyskiwanie niewykorzystanych środków. Przed nowym zakupem płatnego dostępu do Internetu zaktualizuj oprogramowanie kupującego i sprzedawcy; wcześniej opłacone umowy pozostają dostępne. Poprawiono bezpieczeństwo połączeń, usunięto zaufanie do skompromitowanego urzędu certyfikacji, zabezpieczono prywatne sieci sprzedawców dostępu do Internetu i usunięto sekrety dołączania do sieci z danych diagnostycznych.',
    fr_FR:
      "Nostr VPN est mis à jour vers 4.1.22. Ajoute les transferts de fichiers reprenables entre pairs, améliore l'adhésion aux réseaux et les reconnexions, adapte les renouvellements d'accès Internet payant au trafic récent et récupère le crédit inutilisé. Mettez à jour l'acheteur et le vendeur avant tout nouvel achat d'accès Internet payant ; les accords déjà financés restent utilisables. Renforce la sécurité des connexions, retire la confiance à l'autorité de certification compromise, protège les réseaux privés des fournisseurs d'accès Internet et supprime les secrets d'adhésion aux réseaux des diagnostics.",
  },
  migrations: {
    up: async () => {},
    down: IMPOSSIBLE,
  },
})
