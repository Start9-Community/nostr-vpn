import { exposureId, exposures } from '../fileModels/exposures.json'
import { i18n } from '../i18n'
import { sdk } from '../sdk'
import { syncExportedUrls } from '../plugin/sync'
import { bridgeHost, findIface, hostFor } from '../utils'

const { InputSpec, Value } = sdk

type TableMetadata = {
  packageId: string
  interfaceId: string
  hostId: string
  internalPort: number
}

export const exposeOverMesh = sdk.Action.withInput(
  'expose-over-mesh',

  async () => ({
    name: i18n('Share Over Nostr VPN'),
    description: i18n(
      'Make this interface reachable from your other Nostr VPN devices, at this server’s mesh address. Nothing is published to the internet.',
    ),
    warning: null,
    allowedStatuses: 'any',
    group: null,
    visibility: 'hidden',
  }),

  async ({ prefill }) =>
    InputSpec.of({
      urlPluginMetadata: Value.hidden<TableMetadata>(),
      meshPort: Value.number({
        name: i18n('Port'),
        description: i18n(
          'The port your other devices will use to reach this service over the mesh.',
        ),
        required: true,
        default:
          (prefill as { urlPluginMetadata?: TableMetadata } | null)
            ?.urlPluginMetadata?.internalPort ?? null,
        min: 1,
        max: 65535,
        integer: true,
        warning: null,
        units: null,
        placeholder: null,
        immutable: false,
      }),
    }),

  async () => null,

  async ({ effects, input }) => {
    const target = input.urlPluginMetadata
    const host = await hostFor(effects, target)
    if (!findIface(host, target.interfaceId))
      throw new Error(i18n('That interface no longer exists.'))

    // Raw TCP forwarding preserves whatever the target speaks; prefer its
    // plaintext bridge port, since no certificate names a mesh address.
    const ssl = !bridgeHost(host, target.internalPort, false)
    if (!bridgeHost(host, target.internalPort, ssl))
      throw new Error(i18n('That interface is not reachable from this server.'))

    const current = (await exposures.read((e) => e.exposures).once()) ?? []
    const id = exposureId(target)
    if (
      current.some((e) => e.meshPort === input.meshPort && exposureId(e) !== id)
    )
      throw new Error(
        i18n('Port ${port} is already shared over Nostr VPN.', {
          port: String(input.meshPort),
        }),
      )

    await exposures.merge(effects, {
      exposures: [
        ...current.filter((e) => exposureId(e) !== id),
        { ...target, meshPort: input.meshPort, ssl },
      ],
    })

    await syncExportedUrls(effects)

    return {
      version: '1' as const,
      title: i18n('Shared Over Nostr VPN'),
      message: i18n(
        'Saved. The address appears in this service’s list once the mesh is up.',
      ),
      result: null,
    }
  },
)
