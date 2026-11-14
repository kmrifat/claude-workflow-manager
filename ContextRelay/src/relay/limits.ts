// Every limit the relay enforces, in one place. Bodies are base64 of ciphertext, so
// the character caps sit a little above the plaintext limits Pitwall applies first
// (4 KB per entry, 32 KB for the Brief): sealing adds a nonce and a tag, and base64
// adds a third.
export const LIMITS = {
  /** ~6 KB sealed: a 4 KB entry plus overhead. */
  entryBodyChars: 8_192,
  /** ~44 KB sealed: a 32 KB Brief plus overhead. */
  briefBodyChars: 60_000,
  presenceBodyChars: 4_096,
  /** A looping agent cannot bury the log. Counted exactly, from the rows. */
  entriesPerMemberPerHour: 30,
  feedPageSize: 100,
  /** Presence without a heartbeat for this long is not shown. */
  presenceTtlSeconds: 300,
} as const

export const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/
