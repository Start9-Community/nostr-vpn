import { sdk } from '../sdk'
import { exposeOverMesh } from './exposeOverMesh'
import { setControlPanelPassword } from './setControlPanelPassword'
import { stopSharingOverMesh } from './stopSharingOverMesh'

export const actions = sdk.Actions.of()
  .addAction(setControlPanelPassword)
  .addAction(exposeOverMesh)
  .addAction(stopSharingOverMesh)
