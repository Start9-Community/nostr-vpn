import { exposeOverMesh } from '../actions/exposeOverMesh'
import { sdk } from '../sdk'

// Puts a "Share Over Nostr VPN" control on the URL list of every other installed
// service. Clicking it runs exposeOverMesh.
export const registerUrlPlugin = sdk.setupOnInit(async (effects) =>
  sdk.plugin.url.register(effects, { tableAction: exposeOverMesh }),
)
