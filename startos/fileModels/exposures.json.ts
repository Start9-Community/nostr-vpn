import { FileHelper, z } from '@start9labs/start-sdk'
import { sdk } from '../sdk'

const shape = z.object({
  exposures: z
    .array(
      z.object({
        packageId: z.string(),
        hostId: z.string(),
        interfaceId: z.string(),
        internalPort: z.number(),
        meshPort: z.number(),
        ssl: z.boolean(),
      }),
    )
    .catch([]),
})

export type Exposure = z.infer<typeof shape>['exposures'][number]

export const exposureId = (e: {
  packageId: string
  hostId: string
  internalPort: number
}) => `${e.packageId}-${e.hostId}-${e.internalPort}`

export const exposures = FileHelper.json(
  { base: sdk.volumes.main, subpath: 'exposures.json' },
  shape,
)
