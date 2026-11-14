// Every rule the relay enforces, through the real middleware, views and ORM, against
// SQLite and an in-memory archive. `npx ghuri test`.
import { createApp } from '@ghuri/core'
import { createTestClient, type TestClient } from '@ghuri/core/testing'
import { setupTestDatabase, type TestDatabase } from '@ghuri/orm/testing'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import settings from '../settings'
import { LIMITS } from './limits'
import { Brief, Entry, Member, Presence } from './models'

const OWNER_KEY = 'pwo_test-owner-key'
const env = { SECRET_KEY: 'test', OWNER_KEY, DEBUG: 'false' }
const app = createApp(settings)

let db: TestDatabase
let client: TestClient

beforeAll(async () => {
  await app.setup(env)
  db = await setupTestDatabase({ using: 'sqlite', models: [Member, Entry, Brief, Presence] })
  client = createTestClient(app, { env })
})
afterAll(async () => db.teardown())
beforeEach(async () => db.flush())
afterEach(() => vi.useRealTimers())

// Responses are untyped JSON; the assertions are the types.
const j = async (res: Response | Promise<Response>): Promise<any> => (await res).json()
const auth = (key: string) => ({ Authorization: `Bearer ${key}` })
const b64 = (text: string) => Buffer.from(text).toString('base64')
let clientSeq = 0
const nextClientId = () => `client-${String(++clientSeq).padStart(6, '0')}`

async function addMember(name: string, isOwner = false): Promise<{ id: number; key: string }> {
  const res = await client.post('/v1/members/', { json: { name, isOwner }, headers: auth(OWNER_KEY) })
  expect(res.status).toBe(201)
  return res.json()
}

function post(key: string, project: string, body: Record<string, unknown> = {}) {
  return client.post(`/v1/p/${project}/entries/`, {
    json: { clientId: nextClientId(), kind: 'decision', body: b64('sealed'), ...body },
    headers: auth(key),
  })
}

function feed(key: string, project: string, query: Record<string, unknown> = {}) {
  return client.get(`/v1/p/${project}/feed/`, { query, headers: auth(key) })
}

describe('health', () => {
  it('answers without a key, and names the member with one', async () => {
    const anon = await client.get('/v1/health/')
    expect(anon.status).toBe(200)
    expect(await j(anon)).toMatchObject({ service: 'pitwall-context-relay', api: 1, member: null })

    const rifat = await addMember('Rifat', true)
    const known = await client.get('/v1/health/', { headers: auth(rifat.key) })
    expect((await j(known)).member).toEqual({ id: rifat.id, name: 'Rifat' })
  })

  it('refuses a member key it does not know', async () => {
    const res = await client.get('/v1/health/', { headers: auth('pwm_not-a-real-key') })
    expect(res.status).toBe(401)
  })
})

describe('members', () => {
  it('only the owner key can add one, and the key is shown once', async () => {
    expect((await client.post('/v1/members/', { json: { name: 'X' } })).status).toBe(401)

    const shafayet = await addMember('Shafayet')
    expect(shafayet.key).toMatch(/^pwm_[A-Za-z0-9_-]{43}$/)
    expect((await client.post('/v1/members/', { json: { name: 'X' }, headers: auth(shafayet.key) })).status).toBe(401)

    const list = await j(client.get('/v1/members/', { headers: auth(OWNER_KEY) }))
    expect(list.members).toHaveLength(1)
    expect(list.members[0]).not.toHaveProperty('key')
    expect(list.members[0]).not.toHaveProperty('keyHash')
    expect(list.members[0].keyHint).toBe(shafayet.key.slice(-4))
  })

  it('stores a digest of the key, never the key', async () => {
    const m = await addMember('Rifat')
    const row = await Member.objects.get({ pk: m.id })
    expect(row.keyHash).toMatch(/^[0-9a-f]{64}$/)
    expect(row.keyHash).not.toContain(m.key)
  })

  it('a wrong owner key is refused', async () => {
    const res = await client.post('/v1/members/', { json: { name: 'X' }, headers: auth('pwo_guess') })
    expect(res.status).toBe(401)
  })

  it('the owner key is not a member: it cannot post or read', async () => {
    expect((await post(OWNER_KEY, 'ecomsass')).status).toBe(401)
    expect((await feed(OWNER_KEY, 'ecomsass')).status).toBe(401)
  })

  it('a revoked key stops working at once, and their entries keep their name', async () => {
    const rifat = await addMember('Rifat', true)
    const shafayet = await addMember('Shafayet')
    await post(shafayet.key, 'ecomsass')
    await client.put('/v1/p/ecomsass/presence/', { json: { body: b64('p') }, headers: auth(shafayet.key) })

    const del = await client.delete(`/v1/members/${shafayet.id}/`, { headers: auth(OWNER_KEY) })
    expect(del.status).toBe(204)

    expect((await post(shafayet.key, 'ecomsass')).status).toBe(401)
    const page = await j(feed(rifat.key, 'ecomsass'))
    expect(page.entries[0].member).toEqual({ id: shafayet.id, name: 'Shafayet' })
    expect(page.presence).toEqual([])
  })

  it('the last owner cannot be revoked; one of two can', async () => {
    const first = await addMember('Rifat', true)
    expect((await client.delete(`/v1/members/${first.id}/`, { headers: auth(OWNER_KEY) })).status).toBe(403)
    await addMember('Rifat (new Mac)', true)
    expect((await client.delete(`/v1/members/${first.id}/`, { headers: auth(OWNER_KEY) })).status).toBe(204)
  })
})

describe('log', () => {
  it('appends and numbers entries', async () => {
    const m = await addMember('Rifat')
    const a = await post(m.key, 'ecomsass')
    const b = await post(m.key, 'ecomsass', { kind: 'heads-up' })
    expect(a.status).toBe(201)
    const [sa, sb] = [(await j(a)).seq, (await j(b)).seq]
    expect(sb).toBeGreaterThan(sa)
  })

  it('a retried post returns the entry it already made', async () => {
    const m = await addMember('Rifat')
    const body = { clientId: 'outbox-retry-1', kind: 'handoff', body: b64('x') }
    const first = await post(m.key, 'ecomsass', body)
    const again = await post(m.key, 'ecomsass', body)
    expect(first.status).toBe(201)
    expect(again.status).toBe(200)
    expect(await j(again)).toEqual({ seq: (await j(first)).seq, duplicate: true })
    expect(await Entry.objects.count()).toBe(1)
  })

  it('cannot be edited or deleted', async () => {
    const m = await addMember('Rifat')
    await post(m.key, 'ecomsass')
    const put = await client.put('/v1/p/ecomsass/entries/', { json: {}, headers: auth(m.key) })
    const del = await client.delete('/v1/p/ecomsass/entries/', { headers: auth(m.key) })
    expect(put.status).toBe(405)
    expect(del.status).toBe(405)
  })

  it('refuses a bad kind, a body that is not base64, and an oversized body', async () => {
    const m = await addMember('Rifat')
    expect((await post(m.key, 'ecomsass', { kind: 'gossip' })).status).toBe(400)
    expect((await post(m.key, 'ecomsass', { body: 'plain text, not sealed' })).status).toBe(400)
    const big = 'A'.repeat(LIMITS.entryBodyChars + 4)
    expect((await post(m.key, 'ecomsass', { body: big })).status).toBe(400)
    expect((await post(m.key, 'ecomsass', { body: 'A'.repeat(LIMITS.entryBodyChars) })).status).toBe(201)
  })

  it(`allows ${LIMITS.entriesPerMemberPerHour} posts an hour per member, then says when to retry`, async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T10:00:00Z'))
    const m = await addMember('Rifat')
    const other = await addMember('Shafayet')
    for (let i = 0; i < LIMITS.entriesPerMemberPerHour; i++) expect((await post(m.key, 'ecomsass')).status).toBe(201)

    const over = await post(m.key, 'ecomsass')
    expect(over.status).toBe(429)
    expect(Number(over.headers.get('Retry-After'))).toBeGreaterThan(3500)
    expect((await post(other.key, 'ecomsass')).status).toBe(201) // per member, not per team

    vi.setSystemTime(new Date('2026-11-14T11:00:01Z'))
    expect((await post(m.key, 'ecomsass')).status).toBe(201)
  })
})

describe('feed', () => {
  it('returns entries after the cursor, in order, a page at a time', async () => {
    const m = await addMember('Rifat')
    for (let i = 0; i < 5; i++) await post(m.key, 'ecomsass')

    const first = await j(feed(m.key, 'ecomsass', { limit: 3 }))
    expect(first.entries).toHaveLength(3)
    expect(first.more).toBe(true)
    const rest = await j(feed(m.key, 'ecomsass', { after: first.cursor }))
    expect(rest.entries).toHaveLength(2)
    expect(rest.more).toBe(false)
    const seqs = [...first.entries, ...rest.entries].map((e: { seq: number }) => e.seq)
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b))
  })

  it('delivers an entry sent late from an offline outbox', async () => {
    const rifat = await addMember('Rifat')
    const shafayet = await addMember('Shafayet')
    await post(rifat.key, 'ecomsass')
    const seen = await j(feed(rifat.key, 'ecomsass'))

    // Written hours ago on a plane; its client id sorts before everything.
    await post(shafayet.key, 'ecomsass', { clientId: '00000000-offline', kind: 'heads-up' })

    const next = await j(feed(rifat.key, 'ecomsass', { after: seen.cursor }))
    expect(next.entries.map((e: { clientId: string }) => e.clientId)).toEqual(['00000000-offline'])
  })

  it('keeps projects apart', async () => {
    const m = await addMember('Rifat')
    await post(m.key, 'ecomsass')
    await post(m.key, 'gogarage-app')
    const page = await j(feed(m.key, 'gogarage-app'))
    expect(page.entries).toHaveLength(1)
  })

  it('refuses a cursor that is not a number', async () => {
    const m = await addMember('Rifat')
    expect((await feed(m.key, 'ecomsass', { after: 'yesterday' })).status).toBe(400)
  })

  it('needs a member key', async () => {
    expect((await client.get('/v1/p/ecomsass/feed/')).status).toBe(401)
  })
})

describe('brief', () => {
  const put = (key: string, baseRev: number, text: string) =>
    client.put('/v1/p/ecomsass/brief/', { json: { baseRev, body: b64(text) }, headers: auth(key) })

  it('starts empty at rev 0', async () => {
    const m = await addMember('Rifat')
    expect(await j(client.get('/v1/p/ecomsass/brief/', { headers: auth(m.key) }))).toMatchObject({ rev: 0, body: null })
  })

  it('only lands on the rev it was based on, and archives what it replaced', async () => {
    const rifat = await addMember('Rifat')
    const shafayet = await addMember('Shafayet')

    const created = await put(rifat.key, 0, 'v1')
    expect(created.status).toBe(201)
    expect(await j(created)).toEqual({ rev: 1 })

    // Both read rev 1. Shafayet saves first; Rifat's save is refused, not merged.
    expect(await j(put(shafayet.key, 1, 'v2 by Shafayet'))).toEqual({ rev: 2 })
    const lost = await put(rifat.key, 1, 'v2 by Rifat')
    expect(lost.status).toBe(409)
    expect(await j(lost)).toMatchObject({ code: 'stale_rev', rev: 2 })

    const now = await j(client.get('/v1/p/ecomsass/brief/', { headers: auth(rifat.key) }))
    expect(now).toMatchObject({ rev: 2, body: b64('v2 by Shafayet'), updatedBy: { id: shafayet.id, name: 'Shafayet' } })

    const history = await j(client.get('/v1/p/ecomsass/brief/history/', { headers: auth(rifat.key) }))
    expect(history.revs).toEqual([1])
    const old = await j(client.get('/v1/p/ecomsass/brief/history/1/', { headers: auth(rifat.key) }))
    expect(old).toEqual({ rev: 1, body: b64('v1') })
  })

  it('a second "first" Brief is refused', async () => {
    const m = await addMember('Rifat')
    await put(m.key, 0, 'v1')
    const again = await put(m.key, 0, 'also v1')
    expect(again.status).toBe(409)
    expect(await j(again)).toMatchObject({ rev: 1 })
  })

  it('refuses an oversized Brief', async () => {
    const m = await addMember('Rifat')
    const res = await client.put('/v1/p/ecomsass/brief/', {
      json: { baseRev: 0, body: 'A'.repeat(LIMITS.briefBodyChars + 4) },
      headers: auth(m.key),
    })
    expect(res.status).toBe(400)
  })

  it('an unknown revision is a 404', async () => {
    const m = await addMember('Rifat')
    expect((await client.get('/v1/p/ecomsass/brief/history/7/', { headers: auth(m.key) })).status).toBe(404)
  })
})

describe('presence', () => {
  it("is always the caller's own, and expires without a heartbeat", async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-11-14T10:00:00Z'))
    const rifat = await addMember('Rifat')
    const shafayet = await addMember('Shafayet')

    // A body naming someone else changes nothing: the member comes from the key.
    const res = await client.put('/v1/p/ecomsass/presence/', {
      json: { body: b64('{"member":"Rifat"}'), member: rifat.id },
      headers: auth(shafayet.key),
    })
    expect(res.status).toBe(204)
    let page = await j(feed(rifat.key, 'ecomsass'))
    expect(page.presence.map((p: { member: { name: string } }) => p.member.name)).toEqual(['Shafayet'])

    // A heartbeat replaces, it does not add.
    await client.put('/v1/p/ecomsass/presence/', { json: { body: b64('again') }, headers: auth(shafayet.key) })
    expect(await Presence.objects.count()).toBe(1)

    vi.setSystemTime(new Date(Date.now() + (LIMITS.presenceTtlSeconds + 1) * 1000))
    page = await j(feed(rifat.key, 'ecomsass'))
    expect(page.presence).toEqual([])
  })

  it('can be cleared', async () => {
    const m = await addMember('Rifat')
    await client.put('/v1/p/ecomsass/presence/', { json: { body: b64('p') }, headers: auth(m.key) })
    expect((await client.delete('/v1/p/ecomsass/presence/', { headers: auth(m.key) })).status).toBe(204)
    expect(await Presence.objects.count()).toBe(0)
  })
})

describe('errors', () => {
  it('an unknown path is a JSON 404', async () => {
    const res = await client.get('/nothing-here/')
    expect(res.status).toBe(404)
    expect(await j(res)).toEqual({ detail: 'Not found.', code: 'not_found' })
  })
})
