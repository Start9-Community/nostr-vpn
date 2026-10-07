import { actions } from '../actions'
import { restoreInit } from '../backups'
import { dependencies } from '../dependencies'
import { setInterfaces } from '../interfaces'
import { registerUrlPlugin } from '../plugin/register'
import { syncExportedUrls } from '../plugin/sync'
import { sdk } from '../sdk'
import { versionGraph } from '../versions'
import { watchCredentials } from './watchCredentials'

export const init = sdk.setupInit(
  restoreInit,
  versionGraph,
  setInterfaces,
  actions,
  dependencies,
  watchCredentials,
  registerUrlPlugin,
  syncExportedUrls,
)

export const uninit = sdk.setupUninit(versionGraph)
