// The relay's data. Bodies are ciphertext sealed by Pitwall with the team key and sent
// as base64; the relay stores them and never opens them. What it can see is who wrote
// what kind of thing, to which project, and when.
//
// After changing a model:  npx ghuri makemigrations relay
import {
  BooleanField,
  CharField,
  DateTimeField,
  ForeignKey,
  IntegerField,
  type Manager,
  Model,
  PROTECT,
  SlugField,
  TextField,
} from '@ghuri/orm'

/**
 * Someone on the team. Revoked, never deleted: their entries keep pointing at them.
 * The key itself is never stored, only its SHA-256.
 */
export class Member extends Model({
  name: new CharField({ maxLength: 60 }),
  keyHash: new CharField({ maxLength: 64, unique: true }),
  /** The key's last four characters, so Settings can tell two keys apart. */
  keyHint: new CharField({ maxLength: 4 }),
  isOwner: new BooleanField({ default: false }),
  createdAt: new DateTimeField({ autoNowAdd: true }),
  revokedAt: new DateTimeField({ null: true, blank: true }),
}) {
  declare static objects: Manager<Member>
  static Meta = { ordering: ['id'] }
  toString() {
    return this.name
  }
}

export const ENTRY_KINDS = ['decision', 'heads-up', 'question', 'handoff'] as const
export type EntryKind = (typeof ENTRY_KINDS)[number]

/**
 * One log entry. Append-only: nothing updates or deletes a row.
 *
 * `id` is the feed cursor. D1 serialises writes, so ids are handed out in commit
 * order: a client that has read up to N can never later find a committed entry
 * below N. That is the property a client-minted, time-sorted key cannot give —
 * an entry flushed late from an offline outbox would sort before the cursor and
 * be skipped by everyone.
 */
export class Entry extends Model({
  project: new SlugField({ maxLength: 64, dbIndex: true }),
  member: new ForeignKey(() => Member, { onDelete: PROTECT, relatedName: 'entries' }),
  /** Minted by the client, so a retried post is recognised instead of stored twice. */
  clientId: new CharField({ maxLength: 40 }),
  kind: new CharField({ maxLength: 16, choices: ENTRY_KINDS.map((k) => [k, k] as [string, string]) }),
  body: new TextField(),
  createdAt: new DateTimeField({ autoNowAdd: true }),
}) {
  declare static objects: Manager<Entry>
  static Meta = {
    ordering: ['id'],
    uniqueTogether: [['member', 'clientId']],
  }
}

/**
 * The project's living document. `rev` is the whole concurrency story: a save names
 * the rev it was based on and only lands if that is still current.
 */
export class Brief extends Model({
  project: new SlugField({ maxLength: 64, unique: true }),
  rev: new IntegerField({ default: 1 }),
  body: new TextField(),
  updatedBy: new ForeignKey(() => Member, { onDelete: PROTECT, relatedName: 'briefEdits' }),
  updatedAt: new DateTimeField(),
}) {
  declare static objects: Manager<Brief>
}

/** Who is working on what. Each member writes only their own row. */
export class Presence extends Model({
  project: new SlugField({ maxLength: 64, dbIndex: true }),
  member: new ForeignKey(() => Member, { onDelete: PROTECT, relatedName: 'presence' }),
  body: new TextField(),
  heartbeatAt: new DateTimeField(),
}) {
  declare static objects: Manager<Presence>
  static Meta = { uniqueTogether: [['project', 'member']] }
}
