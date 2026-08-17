import { sdk } from '../sdk'
import { setControlPanelPassword } from './setControlPanelPassword'

export const actions = sdk.Actions.of().addAction(setControlPanelPassword)
