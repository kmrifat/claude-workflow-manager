# Pitwall context relay

A Cloudflare Worker, built with [Ghuri](https://ghurijs.github.io/docs/), that lets
a team's Pitwall apps share what their agents know: one **Brief** per project, an
append-only **log** of decisions, heads-ups, questions and handoffs, and **presence**
(who is working on what, and which paths they hold).

A team deploys its own relay into its own Cloudflare account. Pitwall runs no
server: this is the team's, like `PushRelay/`.

## Why a Worker, not a bucket

An R2 access key only means "read and write this bucket". It cannot say *append
only* or *your own presence only*, so one leaked invite code could rewrite or wipe
everything. The relay holds the storage bindings and enforces the rules no client
can be trusted with:

- **Append-only log.** There is no route to edit or delete an entry.
- **Server order.** Every entry gets a `seq` from D1's autoincrement, in commit
  order. A client that has read up to N never misses a later entry below N, even
  one sent late from an offline outbox.
- **Retries are free.** `(member, clientId)` is unique. A repeated post returns the
  entry it already made.
- **No lost Brief edits.** A save names the rev it was based on (`baseRev`). It
  lands only if that rev is still current, otherwise the answer is `409` with the
  current rev. The text it replaced is archived to R2 first.
- **Your own presence only.** The member comes from the key, never from the body.
- **Caps.**
  - 30 entries per member per hour, counted exactly from the rows, answered with
    `429` and `Retry-After`.
  - Entries ≤ 8,192 base64 characters, the Brief ≤ 60,000, presence ≤ 4,096
    (`src/relay/limits.ts`).
- **Two kinds of key.**
  - A member key (`pwm_…`) works on everything except member management. Only
    its SHA-256 is stored.
  - The owner key (`pwo_…`, a Worker secret) can add and revoke members and
    nothing else.

**Bodies are opaque.** Pitwall seals them with the team key before they leave the
Mac and sends base64. The relay sees who posted what kind, to which project and
when, never the text. Rules that need the text, such as "agents may only add to
the Brief" and secret scrubbing, are enforced in Pitwall.

## API

All JSON. Errors are `{detail, code?}` with a status code.

| Route | Key | Does |
|---|---|---|
| `GET /v1/health/` | any or none | `{service, version, api, member}`. A bad key gives 401 |
| `POST /v1/p/<project>/entries/` | member | `{clientId, kind, body}` → `201 {seq}`, or `200 {seq, duplicate: true}` |
| `GET /v1/p/<project>/feed/?after=<seq>&limit=` | member | `{entries, cursor, more, presence, brief: {rev, updatedBy, updatedAt}}` |
| `GET /v1/p/<project>/brief/` | member | `{rev, body, updatedBy, updatedAt}`. rev 0 means no Brief yet |
| `PUT /v1/p/<project>/brief/` | member | `{baseRev, body}` → `{rev}`, or `409 {code: "stale_rev", rev}` |
| `GET /v1/p/<project>/brief/history/` | member | `{revs}`, newest first |
| `GET /v1/p/<project>/brief/history/<rev>/` | member | `{rev, body}` |
| `PUT /v1/p/<project>/presence/` | member | `{body}` → 204. Replaces the caller's own |
| `DELETE /v1/p/<project>/presence/` | member | 204 |
| `GET /v1/members/` | owner | `{members}`, without keys |
| `POST /v1/members/` | owner | `{name, isOwner?}` → `201 {…, key}`. The only time the key is shown |
| `DELETE /v1/members/<id>/` | owner | Revoke. The last owner member can't be revoked |

`kind` is one of `decision`, `heads-up`, `question`, `handoff`. `<project>` is a
slug. Every member can use every project on the team.

## Deploy (once per team)

From this directory, signed in to the team's Cloudflare account (`npx wrangler login`).
If that login can reach more than one account, export `CLOUDFLARE_ACCOUNT_ID` first.
Otherwise wrangler can't choose an account when it isn't run interactively.

1. Create the database, then paste the `database_id` it prints into `wrangler.jsonc`:

   ```bash
   npx wrangler d1 create pitwall-ctx
   ```

2. Create the archive bucket:

   ```bash
   npx wrangler r2 bucket create pitwall-ctx-archive
   ```

3. Set the two secrets. Paste a long random value for each, and keep the owner
   key: Pitwall's Settings › Team asks for it.

   ```bash
   echo "pwo_$(openssl rand -hex 32)"
   ```

   ```bash
   npx wrangler secret put OWNER_KEY
   ```

   ```bash
   openssl rand -hex 32 | npx wrangler secret put SECRET_KEY
   ```

4. Apply the migrations to the remote database and deploy:

   ```bash
   npx ghuri deploy
   ```

   The first deploy of a new Worker can fail after `Uploaded …` with `This Worker
   does not exist on your account. [code: 10007]`. Wrangler checked for the Worker
   before Cloudflare had caught up. Run it again without the migrations:

   ```bash
   npx ghuri deploy --skip-migrations
   ```

The owner's own deployment keeps the owner key in the login Keychain (service
`dev.pitwall.context-relay`, account `owner-key`), and it was piped into `wrangler
secret put` from there, never printed. To read it:

```bash
security find-generic-password -s dev.pitwall.context-relay -a owner-key -w
```

## Develop

```bash
npm install
```

```bash
cp .dev.vars.example .dev.vars
```

```bash
npx ghuri migrate
```

```bash
npx ghuri runserver
```

```bash
npx ghuri test
```

```bash
npm run typecheck
```

After changing a model:

```bash
npx ghuri makemigrations relay
```

`.dev.vars` holds throwaway local secrets and is git-ignored. Production secrets
live only in `wrangler secret put`.

## Pinned on purpose

Ghuri is `0.1.0-alpha`, so every dependency is pinned to an exact version. Bump
them deliberately and run the tests.

`postgres` is a dependency even though the relay uses D1 only. Ghuri's ORM imports
its Postgres driver statically, and the Worker bundle fails to resolve it otherwise.
