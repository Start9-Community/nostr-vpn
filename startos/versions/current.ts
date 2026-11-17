import { IMPOSSIBLE, VersionInfo } from '@start9labs/start-sdk'

export const current = VersionInfo.of({
  version: '4.1.18:1',
  releaseNotes: {
    en_US:
      'Updated the embedded TLS roots and verifier to remove emSign G3 trust and reject compromised eMudhra intermediate keys. Nostr VPN remains at 4.1.18; no configuration changes are required.',
    es_ES:
      'Se actualizaron las raíces y el verificador TLS integrados para eliminar la confianza en emSign G3 y rechazar las claves intermedias comprometidas de eMudhra. Nostr VPN sigue en 4.1.18; no se requieren cambios de configuración.',
    de_DE:
      'Die integrierten TLS-Stammzertifikate und der Prüfer wurden aktualisiert, um emSign G3 nicht mehr zu vertrauen und kompromittierte eMudhra-Zwischenschlüssel abzulehnen. Nostr VPN bleibt bei 4.1.18; Konfigurationsänderungen sind nicht erforderlich.',
    pl_PL:
      'Zaktualizowano wbudowane główne certyfikaty TLS i weryfikator, usuwając zaufanie do emSign G3 i odrzucając skompromitowane klucze pośrednie eMudhra. Nostr VPN pozostaje w wersji 4.1.18; zmiany konfiguracji nie są wymagane.',
    fr_FR:
      "Les racines et le vérificateur TLS intégrés ont été mis à jour pour retirer la confiance en emSign G3 et rejeter les clés intermédiaires compromises d'eMudhra. Nostr VPN reste en version 4.1.18 ; aucune modification de configuration n'est nécessaire.",
  },
  migrations: {
    up: async () => {},
    down: IMPOSSIBLE,
  },
})
