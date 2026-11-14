// The relay's API. Every rule that does not need to read a body is enforced here:
// who may write, what may never change, how big and how often. Rules that need the
// text (agents may only add to the Brief, secret scrubbing) live in Pitwall, which
// holds the team key; the relay never does.
import { IntegrityError } from '@ghuri/orm'
import { AllowAny, APIResponse, APIView, IsAuthenticated, NotFound, PermissionDenied, Throttled, type APIRequest, ValidationError } from '@ghuri/rest'
import { defaultStorage } from '@ghuri/storage'
import { MemberUser, mintMemberKey, OwnerAuthentication, sha256Hex } from './auth'
import { LIMITS } from './limits'
import { Brief, Entry, Member, Presence } from './models'
import { BriefIn, EntryIn, MemberIn, PresenceIn } from './serializers'

export const API_VERSION = 1
export const RELAY_VERSION = '0.1.0'

function memberOf(request: APIRequest): Member {
  return (request.user as MemberUser).member
}

function who(member: Member | undefined) {
  return member ? { id: member.pk, name: member.name } : null
}

function iso(date: unknown): string | null {
  return date instanceof Date ? date.toISOString() : date == null ? null : String(date)
}

async function validated<T extends Record<string, any>>(Ser: new (opts: any) => any, data: unknown): Promise<T> {
  const s = new Ser({ data })
  await s.isValid({ raiseException: true })
  return s.validatedData as T
}

/** Optional non-negative integer query parameter. */
function intParam(request: APIRequest, name: string, fallback: number): number {
  const raw = request.queryParams.get(name)
  if (raw == null || raw === '') return fallback
  if (!/^\d+$/.test(raw)) throw new ValidationError({ [name]: ['Must be a non-negative integer.'] })
  return Number(raw)
}

// ─── Health ──────────────────────────────────────────────────────────────────

/** `Test connection` in Pitwall: is this the relay, which version, and is my key good? */
export class HealthView extends APIView {
  permissionClasses = [AllowAny]

  async get(request: APIRequest) {
    const member = request.user.isAuthenticated ? memberOf(request) : undefined
    return { service: 'pitwall-context-relay', version: RELAY_VERSION, api: API_VERSION, member: who(member) }
  }
}

// ─── Log ─────────────────────────────────────────────────────────────────────

export class EntriesView extends APIView {
  permissionClasses = [IsAuthenticated]

  /** Append one entry. A repeated `clientId` returns the entry it already made. */
  async post(request: APIRequest, kwargs: Record<string, any>) {
    const member = memberOf(request)
    const input = await validated<{ clientId: string; kind: string; body: string }>(EntryIn, request.data)

    const existing = await Entry.objects.filter({ member: member.pk, clientId: input.clientId }).first()
    if (existing) return new APIResponse({ seq: existing.pk, duplicate: true }, 200)

    await enforceHourlyCap(member)

    try {
      const entry = await Entry.objects.create({ project: kwargs.project, member, ...input })
      return new APIResponse({ seq: entry.pk, duplicate: false }, 201)
    } catch (error) {
      // Two retries of the same post racing each other: the second loses the unique
      // index and gets the first one's answer.
      if (!(error instanceof IntegrityError)) throw error
      const winner = await Entry.objects.filter({ member: member.pk, clientId: input.clientId }).first()
      if (!winner) throw error
      return new APIResponse({ seq: winner.pk, duplicate: true }, 200)
    }
  }
}

async function enforceHourlyCap(member: Member) {
  const windowStart = new Date(Date.now() - 3_600_000)
  const recent = Entry.objects.filter({ member: member.pk, createdAt__gte: windowStart })
  if ((await recent.count()) < LIMITS.entriesPerMemberPerHour) return
  const oldest = await recent.orderBy('createdAt').first()
  const freesAt = oldest ? new Date(oldest.createdAt as Date).getTime() + 3_600_000 : Date.now() + 60_000
  throw new Throttled(Math.max(1, Math.ceil((freesAt - Date.now()) / 1000)))
}

/** Everything new since `after`: entries in commit order, who is live, the Brief's rev. */
export class FeedView extends APIView {
  permissionClasses = [IsAuthenticated]

  async get(request: APIRequest, kwargs: Record<string, any>) {
    const project: string = kwargs.project
    const after = intParam(request, 'after', 0)
    const limit = Math.min(intParam(request, 'limit', LIMITS.feedPageSize), LIMITS.feedPageSize) || LIMITS.feedPageSize

    const page = await Entry.objects.filter({ project, id__gt: after }).orderBy('id').slice(0, limit + 1)
    const more = page.length > limit
    const entries = page.slice(0, limit)

    const liveSince = new Date(Date.now() - LIMITS.presenceTtlSeconds * 1000)
    const presence = await Presence.objects.filter({ project, heartbeatAt__gte: liveSince, member__revokedAt__isnull: true })
    const brief = await Brief.objects.filter({ project }).first()

    // A team is a handful of people: one query for all of them beats a join per row.
    const members = (await Member.objects.inBulk()) as Map<unknown, Member>

    return {
      entries: entries.map((e) => ({
        seq: e.pk,
        member: who(members.get(e.memberId)),
        kind: e.kind,
        clientId: e.clientId,
        body: e.body,
        createdAt: iso(e.createdAt),
      })),
      cursor: entries.length ? entries[entries.length - 1].pk : after,
      more,
      presence: presence.map((p) => ({ member: who(members.get(p.memberId)), body: p.body, heartbeatAt: iso(p.heartbeatAt) })),
      brief: brief ? { rev: brief.rev, updatedBy: who(members.get(brief.updatedById)), updatedAt: iso(brief.updatedAt) } : null,
    }
  }
}

// ─── Brief ───────────────────────────────────────────────────────────────────

const archiveName = (project: string, rev: number) => `brief/${project}/rev-${String(rev).padStart(6, '0')}.sealed`
const ARCHIVED = /^rev-(\d{6})\.sealed$/

function stale(current: Brief | null) {
  return new APIResponse(
    { detail: 'The Brief changed since you read it.', code: 'stale_rev', rev: current?.rev ?? 0 },
    409,
  )
}

export class BriefView extends APIView {
  permissionClasses = [IsAuthenticated]

  async get(_request: APIRequest, kwargs: Record<string, any>) {
    const brief = await Brief.objects.filter({ project: kwargs.project }).first()
    if (!brief) return { rev: 0, body: null, updatedBy: null, updatedAt: null }
    const by = await Member.objects.filter({ pk: brief.updatedById }).first()
    return { rev: brief.rev, body: brief.body, updatedBy: who(by ?? undefined), updatedAt: iso(brief.updatedAt) }
  }

  /**
   * Replace the Brief, if it is still at `baseRev`. The old text goes to the archive
   * first: a rev names exactly one text, so writing it before the swap is safe even
   * when the swap then loses.
   */
  async put(request: APIRequest, kwargs: Record<string, any>) {
    const project: string = kwargs.project
    const member = memberOf(request)
    const { baseRev, body } = await validated<{ baseRev: number; body: string }>(BriefIn, request.data)
    const now = new Date()

    const current = await Brief.objects.filter({ project }).first()
    if ((current?.rev ?? 0) !== baseRev) return stale(current ?? null)

    if (!current) {
      try {
        const created = await Brief.objects.create({ project, rev: 1, body, updatedBy: member, updatedAt: now })
        return new APIResponse({ rev: created.rev }, 201)
      } catch (error) {
        if (!(error instanceof IntegrityError)) throw error
        return stale(await Brief.objects.filter({ project }).first())
      }
    }

    const name = archiveName(project, current.rev)
    if (!(await defaultStorage().exists(name))) await defaultStorage().save(name, current.body)

    const changed = await Brief.objects
      .filter({ project, rev: baseRev })
      .update({ rev: baseRev + 1, body, updatedBy: member.pk, updatedAt: now })
    if (changed === 0) return stale(await Brief.objects.filter({ project }).first())
    return { rev: baseRev + 1 }
  }
}

/** Revisions the Brief has had, newest first. The current one is not in the archive. */
export class BriefHistoryView extends APIView {
  permissionClasses = [IsAuthenticated]

  async get(_request: APIRequest, kwargs: Record<string, any>) {
    const { files } = await defaultStorage().listdir(`brief/${kwargs.project}/`)
    const revs = files
      .map((f) => ARCHIVED.exec(f))
      .filter((m): m is RegExpExecArray => m != null)
      .map((m) => Number(m[1]))
      .sort((a, b) => b - a)
    return { revs }
  }
}

export class BriefRevisionView extends APIView {
  permissionClasses = [IsAuthenticated]

  async get(_request: APIRequest, kwargs: Record<string, any>) {
    const file = await defaultStorage().open(archiveName(kwargs.project, Number(kwargs.rev)))
    if (!file) throw new NotFound('No such revision.')
    return { rev: Number(kwargs.rev), body: await file.text() }
  }
}

// ─── Presence ────────────────────────────────────────────────────────────────

/** The caller's own presence. The member comes from the key, never from the body. */
export class PresenceView extends APIView {
  permissionClasses = [IsAuthenticated]

  async put(request: APIRequest, kwargs: Record<string, any>) {
    const member = memberOf(request)
    const { body } = await validated<{ body: string }>(PresenceIn, request.data)
    await Presence.objects.updateOrCreate(
      { project: kwargs.project, member: member.pk },
      { defaults: { body, heartbeatAt: new Date() } },
    )
    return new APIResponse(null, 204)
  }

  async delete(request: APIRequest, kwargs: Record<string, any>) {
    await Presence.objects.filter({ project: kwargs.project, member: memberOf(request).pk }).delete()
    return new APIResponse(null, 204)
  }
}

// ─── Members (owner key only) ────────────────────────────────────────────────

function memberOut(m: Member) {
  return {
    id: m.pk,
    name: m.name,
    isOwner: m.isOwner,
    keyHint: m.keyHint,
    createdAt: iso(m.createdAt),
    revokedAt: iso(m.revokedAt),
  }
}

export class MembersView extends APIView {
  authenticationClasses = [OwnerAuthentication]
  permissionClasses = [IsAuthenticated]

  async get() {
    return { members: (await Member.objects.all()).map(memberOut) }
  }

  /** Mint a member. The key is in this response and nowhere else, ever. */
  async post(request: APIRequest) {
    const { name, isOwner } = await validated<{ name: string; isOwner: boolean }>(MemberIn, request.data)
    const key = mintMemberKey()
    const member = await Member.objects.create({
      name,
      isOwner: Boolean(isOwner),
      keyHash: await sha256Hex(key),
      keyHint: key.slice(-4),
    })
    return new APIResponse({ ...memberOut(member), key }, 201)
  }
}

export class MemberDetailView extends APIView {
  authenticationClasses = [OwnerAuthentication]
  permissionClasses = [IsAuthenticated]

  /** Revoke. The row stays so their entries still say who wrote them. */
  async delete(_request: APIRequest, kwargs: Record<string, any>) {
    const member = await Member.objects.filter({ pk: kwargs.id }).first()
    if (!member) throw new NotFound('No such member.')
    if (member.revokedAt) return new APIResponse(null, 204)
    if (member.isOwner) {
      const owners = await Member.objects.filter({ isOwner: true, revokedAt__isnull: true }).count()
      if (owners <= 1) throw new PermissionDenied('That is the last owner member. Add another owner first.')
    }
    member.revokedAt = new Date()
    await member.save({ updateFields: ['revokedAt'] })
    await Presence.objects.filter({ member: member.pk }).delete()
    return new APIResponse(null, 204)
  }
}
