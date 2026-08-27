import { exposures } from '../fileModels/exposures.json'
import { meshStatus } from '../fileModels/meshStatus.json'
import { stopSharingOverMesh } from '../actions/stopSharingOverMesh'
import { sdk } from '../sdk'

// Mirrors the shared set into the StartOS url-v0 table. Init's reactive read does
// not re-fire on these files, so both actions call this after writing. Kept free
// of any import from `./register` so they can, without an import cycle.
export const syncExportedUrls = sdk.plugin.url.setupExportedUrls(
  async ({ effects }) => {
    // Peers reach this node at its tunnel address; nvpn reports no MagicDNS name
    // for the node itself.
    const hostname = (
      await meshStatus.read((s) => s.tunnel_ip).const(effects)
    )?.split('/')[0]
    if (!hostname) return

    for (const e of (await exposures.read((x) => x.exposures).const(effects)) ??
      []) {
      await sdk.plugin.url
        .exportUrl(effects, {
          hostnameInfo: {
            packageId: e.packageId,
            hostId: e.hostId,
            internalPort: e.internalPort,
            ssl: e.ssl,
            public: false,
            hostname,
            port: e.meshPort,
            info: null,
          },
          removeAction: stopSharingOverMesh,
          overflowActions: [],
        })
        .catch((err) => console.error('Failed to export Nostr VPN url', err))
    }
  },
)
