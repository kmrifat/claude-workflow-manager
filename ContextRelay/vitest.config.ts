import { defineConfig } from 'vitest/config'

// `ghuri test` runs vitest. Tests run against SQLite (better-sqlite3) and an
// in-memory storage, through the real middleware and views.
export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
})
