import { IMPOSSIBLE, VersionInfo } from '@start9labs/start-sdk'

export const current = VersionInfo.of({
  version: '4.1.18:1',
  releaseNotes: {
    en_US:
      'The control panel is now reachable only through the addresses StartOS gives it, never directly from devices on the mesh.',
    es_ES:
      'El panel de control ahora solo es accesible a través de las direcciones que le asigna StartOS, nunca directamente desde los dispositivos de la malla.',
    de_DE:
      'Die Steuerungskonsole ist jetzt nur noch über die Adressen erreichbar, die StartOS ihr zuweist, nie direkt von Geräten im Mesh.',
    pl_PL:
      'Panel sterowania jest teraz dostępny wyłącznie pod adresami nadanymi mu przez StartOS, nigdy bezpośrednio z urządzeń w sieci mesh.',
    fr_FR:
      "Le panneau de configuration n'est désormais accessible que par les adresses que StartOS lui attribue, jamais directement depuis les appareils du maillage.",
  },
  migrations: {
    up: async () => {},
    down: IMPOSSIBLE,
  },
})
