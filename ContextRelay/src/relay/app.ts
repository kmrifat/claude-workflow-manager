import { AppConfig } from '@ghuri/core'
import * as migrations from './migrations'
import * as models from './models'

export class RelayConfig extends AppConfig {
  name = 'relay'
  verboseName = 'Context relay'
  path = import.meta.dirname
  models = models
  migrations = migrations
}
