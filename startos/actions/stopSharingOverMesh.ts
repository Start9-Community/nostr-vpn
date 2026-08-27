import { exposureId, exposures } from '../fileModels/exposures.json'
import { i18n } from '../i18n'
import { sdk } from '../sdk'
import { syncExportedUrls } from '../plugin/sync'

const { InputSpec, Value } = sdk

// The remove control hands back the same PluginHostnameInfo we exported.
type TableMetadata = {
  interfaceId: string
  packageId: string
  hostId: string
  internalPort: number
  ssl: boolean
  public: boolean
  hostname: string
  port: number | null
  info: unknown
}

export const stopSharingOverMesh = sdk.Action.withInput(
  'stop-sharing-over-mesh',

  async () => ({
    name: i18n('Stop Sharing Over Nostr VPN'),
    description: i18n(
      'Stop making this interface reachable from your other Nostr VPN devices.',
    ),
    warning: null,
    allowedStatuses: 'any',
    group: null,
    visibility: 'hidden',
  }),

  async () =>
    InputSpec.of({ urlPluginMetadata: Value.hidden<TableMetadata>() }),

  async () => null,

  async ({ effects, input }) => {
    const id = exposureId(input.urlPluginMetadata)
    const current = (await exposures.read((e) => e.exposures).once()) ?? []

    await exposures.merge(effects, {
      exposures: current.filter((e) => exposureId(e) !== id),
    })

    await syncExportedUrls(effects)

    return {
      version: '1' as const,
      title: i18n('No Longer Shared'),
      message: i18n('That service is no longer reachable over Nostr VPN.'),
      result: null,
    }
  },
)
