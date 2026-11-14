// Two credentials, never interchangeable:
//
// - A member key (`pwm_…`) is what a member's Pitwall sends on every request. Only
//   its SHA-256 is stored, so a dump of the database cannot be replayed.
// - The owner key (`pwo_…`) is a Worker secret. It can add and remove members and
//   do nothing else — it cannot post, read the log or touch the Brief.
import { getSettings, type RequestUser } from '@ghuri/core'
import { AuthenticationFailed } from '@ghuri/rest'
import type { Context } from 'hono'
import { Member } from './models'

export const MEMBER_KEY_PREFIX = 'pwm_'
export const OWNER_KEY_PREFIX = 'pwo_'

/** 32 random bytes, base64url, with the member prefix. */
export function mintMemberKey(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return MEMBER_KEY_PREFIX + base64url(bytes)
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Compares two secrets in time independent of where they differ, by comparing their digests. */
export async function secretsMatch(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([sha256Hex(a), sha256Hex(b)])
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i)
  return diff === 0
}

function base64url(bytes: Uint8Array): string {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function bearer(c: Context): string | null {
  const header = c.req.header('Authorization') ?? ''
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header)
  return match ? match[1] : null
}

/** `request.user` for a member: who they are, nothing they may do beyond this API. */
export class MemberUser implements RequestUser {
  readonly isAuthenticated = true
  readonly isAnonymous = false
  readonly isActive = true
  readonly isStaff = false
  readonly isSuperuser = false
  constructor(readonly member: Member) {}
  get pk() {
    return this.member.pk
  }
  get username() {
    return this.member.name
  }
  async hasPerm() {
    return false
  }
}

/** `request.user` for the owner key. It is nobody: it can manage members, that is all. */
export class OwnerUser implements RequestUser {
  readonly pk = 'owner'
  readonly isAuthenticated = true
  readonly isAnonymous = false
  readonly isActive = true
  async hasPerm() {
    return false
  }
}

const REALM = 'Bearer realm="pitwall-context-relay"'

/** `Authorization: Bearer pwm_…`, checked against live (unrevoked) members. */
export class MemberAuthentication {
  static securityScheme = { name: 'memberKey', scheme: { type: 'http', scheme: 'bearer' } }

  async authenticate(c: Context): Promise<[MemberUser, Member] | null> {
    const key = bearer(c)
    // No member key at all: anonymous, so IsAuthenticated answers 401. The owner key
    // lands here too, which is the point — it is not a member.
    if (!key || !key.startsWith(MEMBER_KEY_PREFIX)) return null
    const member = await Member.objects
      .filter({ keyHash: await sha256Hex(key), revokedAt__isnull: true })
      .first()
    if (!member) throw new AuthenticationFailed('Unknown or revoked member key.', 'invalid_key')
    return [new MemberUser(member), member]
  }

  authenticateHeader(): string {
    return REALM
  }
}

/** `Authorization: Bearer pwo_…`, compared with the OWNER_KEY secret. */
export class OwnerAuthentication {
  static securityScheme = { name: 'ownerKey', scheme: { type: 'http', scheme: 'bearer' } }

  async authenticate(c: Context): Promise<[OwnerUser, null] | null> {
    const key = bearer(c)
    if (!key) return null
    const owner = String(getSettings().OWNER_KEY ?? '')
    if (!owner) throw new AuthenticationFailed('This Worker has no OWNER_KEY secret yet.', 'no_owner_key')
    if (!(await secretsMatch(key, owner))) throw new AuthenticationFailed('Not the owner key.', 'invalid_key')
    return [new OwnerUser(), null]
  }

  authenticateHeader(): string {
    return REALM
  }
}
