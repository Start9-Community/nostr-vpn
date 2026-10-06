import { IMPOSSIBLE, VersionInfo } from '@start9labs/start-sdk'

export const current = VersionInfo.of({
  version: '4.1.17:0',
  releaseNotes: {
    en_US: `Initial StartOS package for Nostr VPN.

- Nostr VPN is updated to 4.1.17. Since 4.1.8: Cashu paid exits connect, bill and recover more reliably; device approvals reach joining devices more reliably, including after the other device's VPN restarts; the private mesh starts promptly on a server with no default internet route; a TLS security issue (RUSTSEC-2026-0285) is fixed; and local keys, payment state and device rosters are protected against unsafe filesystem links. Full list: https://github.com/mmalmi/nostr-vpn/blob/v4.1.17/CHANGELOG.md
- Set Control Panel Password asks for confirmation before it replaces an existing password.`,
    es_ES: `Paquete inicial de StartOS para Nostr VPN.

- Nostr VPN se actualiza a 4.1.17. Desde 4.1.8: las salidas de pago con Cashu se conectan, cobran y recuperan de forma más fiable; las aprobaciones de dispositivos llegan con más fiabilidad a los dispositivos que se unen, también después de que se reinicie la VPN del otro dispositivo; la malla privada arranca enseguida en un servidor sin ruta predeterminada a internet; se corrige un problema de seguridad de TLS (RUSTSEC-2026-0285); y las claves locales, el estado de pagos y las listas de dispositivos están protegidos frente a enlaces inseguros del sistema de archivos. Lista completa: https://github.com/mmalmi/nostr-vpn/blob/v4.1.17/CHANGELOG.md
- Establecer la contraseña del panel de control pide confirmación antes de reemplazar una contraseña existente.`,
    de_DE: `Erstes StartOS-Paket für Nostr VPN.

- Nostr VPN ist auf 4.1.17 aktualisiert. Seit 4.1.8: Bezahlte Cashu-Exits verbinden, rechnen ab und erholen sich zuverlässiger; Gerätefreigaben erreichen beitretende Geräte zuverlässiger, auch nachdem das VPN des anderen Geräts neu gestartet ist; das private Mesh startet zügig auf einem Server ohne Standardroute ins Internet; ein TLS-Sicherheitsproblem (RUSTSEC-2026-0285) ist behoben; und lokale Schlüssel, Zahlungsstatus und Gerätelisten sind gegen unsichere Dateisystem-Links geschützt. Vollständige Liste: https://github.com/mmalmi/nostr-vpn/blob/v4.1.17/CHANGELOG.md
- „Passwort der Steuerungskonsole festlegen“ fragt nach einer Bestätigung, bevor es ein vorhandenes Passwort ersetzt.`,
    pl_PL: `Pierwszy pakiet StartOS dla Nostr VPN.

- Nostr VPN zaktualizowano do 4.1.17. Od 4.1.8: płatne wyjścia Cashu łączą się, rozliczają i wznawiają niezawodniej; zatwierdzenia urządzeń docierają do dołączających urządzeń niezawodniej, także po ponownym uruchomieniu VPN na drugim urządzeniu; prywatna sieć mesh uruchamia się od razu na serwerze bez domyślnej trasy do internetu; naprawiono problem bezpieczeństwa TLS (RUSTSEC-2026-0285); a lokalne klucze, stan płatności i listy urządzeń są chronione przed niebezpiecznymi dowiązaniami w systemie plików. Pełna lista: https://github.com/mmalmi/nostr-vpn/blob/v4.1.17/CHANGELOG.md
- „Ustaw hasło panelu sterowania” prosi o potwierdzenie, zanim zastąpi istniejące hasło.`,
    fr_FR: `Premier paquet StartOS pour Nostr VPN.

- Nostr VPN passe en 4.1.17. Depuis la 4.1.8 : les sorties payantes Cashu se connectent, facturent et se rétablissent de façon plus fiable ; les approbations d’appareils parviennent plus fiablement aux appareils qui rejoignent le réseau, y compris après le redémarrage du VPN de l’autre appareil ; le réseau maillé privé démarre rapidement sur un serveur sans route Internet par défaut ; un problème de sécurité TLS (RUSTSEC-2026-0285) est corrigé ; et les clés locales, l’état des paiements et les listes d’appareils sont protégés contre les liens de système de fichiers dangereux. Liste complète : https://github.com/mmalmi/nostr-vpn/blob/v4.1.17/CHANGELOG.md
- Définir le mot de passe du panneau de configuration demande une confirmation avant de remplacer un mot de passe existant.`,
  },
  migrations: {
    up: async () => {},
    down: IMPOSSIBLE,
  },
})
