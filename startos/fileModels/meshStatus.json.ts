import { FileHelper, z } from '@start9labs/start-sdk'
import { sdk } from '../sdk'

// `nvpn status --json`, written to the volume by main's write-mesh-status oneshot.
export const meshStatus = FileHelper.json(
  { base: sdk.volumes.main, subpath: 'mesh-status.json' },
  z.object({ tunnel_ip: z.string().optional().catch(undefined) }),
)
