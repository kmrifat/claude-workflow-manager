// Project settings. `env` holds the Worker's bindings, vars and secrets (wrangler.jsonc,
// `wrangler secret put`, .dev.vars locally). Bindings are named here and nowhere else.
import { CommonMiddleware, defineSettings, SecurityMiddleware } from '@ghuri/core'
import { d1 } from '@ghuri/orm'
import { IsAuthenticated, JSONParser, JSONRenderer, RestFrameworkConfig } from '@ghuri/rest'
import { memoryStorage, r2 } from '@ghuri/storage'
import { RelayConfig } from './relay/app'
import { MemberAuthentication } from './relay/auth'
import { urlpatterns } from './urls'

export default defineSettings((env) => ({
  // Nothing here signs a cookie or a session; Ghuri still wants a key.
  SECRET_KEY: env.SECRET_KEY ?? '',
  DEBUG: env.DEBUG === 'true',
  ALLOWED_HOSTS: env.ALLOWED_HOSTS ? String(env.ALLOWED_HOSTS).split(',') : ['*'],

  // The one credential that can add or remove members. Compared by digest, never logged.
  OWNER_KEY: env.OWNER_KEY ?? '',

  INSTALLED_APPS: [RestFrameworkConfig, RelayConfig],

  // No sessions, no CSRF, no cookies: every request carries a bearer key, and
  // every view is an APIView (which is CSRF-exempt anyway).
  MIDDLEWARE: [SecurityMiddleware, CommonMiddleware],

  ROOT_URLCONF: urlpatterns,

  // Pitwall reads every answer as JSON, failures included. (With DEBUG on, Ghuri's
  // HTML debug pages still win, which is what you want while developing.)
  HANDLER_404: (c) => c.json({ detail: 'Not found.', code: 'not_found' }, 404),
  HANDLER_500: (c) => c.json({ detail: 'The relay hit an error.', code: 'server_error' }, 500),

  DATABASES: {
    default: d1('DB'),
  },

  STORAGES: {
    // Replaced Brief revisions. Tests run without the binding and get memory.
    default: env.ARCHIVE ? r2('ARCHIVE') : memoryStorage(),
  },

  REST_FRAMEWORK: {
    DEFAULT_AUTHENTICATION_CLASSES: [MemberAuthentication],
    DEFAULT_PERMISSION_CLASSES: [IsAuthenticated],
    // Pitwall is the only client: JSON in and out, no browsable API.
    DEFAULT_RENDERER_CLASSES: [JSONRenderer],
    DEFAULT_PARSER_CLASSES: [JSONParser],
  },

  // HTTPS only; workers.dev and custom domains both serve TLS.
  SECURE_HSTS_SECONDS: 31_536_000,
  // CSRF protects cookie sessions. There are none here: every request carries a
  // bearer key, which a browser never attaches on its own.
  SILENCED_SYSTEM_CHECKS: ['security.W003', 'security.W016'],

  TIME_ZONE: 'UTC',
  USE_TZ: true,
}))
