import { FileHelper, z } from '@start9labs/start-sdk'
import { sdk } from '../sdk'

// StartOS-managed state for the package — distinct from nvpn's own
// `config.toml`. Currently just the password for the proxy auth gate on the
// `control-panel` interface, set by the setControlPanelPassword action
// (surfaced as a critical install task by watchCredentials, and re-runnable for
// rotation).
const shape = z.object({
  controlPanelPassword: z.string().optional().catch(undefined),
})

export const storeJson = FileHelper.json(
  { base: sdk.volumes.main, subpath: 'store.json' },
  shape,
)
