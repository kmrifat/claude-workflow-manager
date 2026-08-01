/**
 * Claude WM push relay.
 *
 * One job: take a notice from someone's Mac, sign it with the APNs key that
 * lives only here, and hand it to Apple.
 *
 * ## Why this exists
 *
 * A push has to be signed by something holding an APNs auth key. Without this,
 * that something is the user's Mac — which means shipping the key inside the
 * app, where any buyer can extract it. An auth key is account-wide, so a leaked
 * one can push to every app on the developer account and cannot be revoked
 * without breaking every user at once.
 *
 * Moving the key here changes the failure mode rather than eliminating it. The
 * relay key that apps carry is still extractable, but a leaked one only lets
 * someone push through this relay, to device tokens they would have to already
 * know, and it can be rotated in a minute.
 *
 * ## What it deliberately does not do
 *
 * No database, no accounts, no logging of payloads. It sees a device token and
 * a card title for as long as it takes to forward them. The product it serves
 * keeps everything else on the local network, and this should not be the thing
 * that quietly starts collecting.
 */

export interface Env {
  /** Contents of the .p8, as a secret. Never in source. */
  APNS_KEY_P8: string;
  /** The 10-character key id from the filename. */
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  /** Shared secret the apps present. Rotate by changing it here and shipping. */
  RELAY_KEY: string;
  /** Bundle id of the iOS app: the APNs topic. */
  APNS_TOPIC: string;
}

interface PushRequest {
  token: string;
  title: string;
  subtitle?: string;
  body: string;
  collapseID?: string;
  threadID?: string;
  /** "sandbox" for a development build. Absent means try both. */
  environment?: "sandbox" | "production";
}

const HOSTS = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
} as const;

/**
 * Cached provider token. Module scope, so it survives between requests handled
 * by the same isolate — Apple rate-limits token generation and rejects a JWT
 * older than an hour, so re-signing per push is a way to get throttled.
 */
let cached: { jwt: string; issued: number } | null = null;
const TOKEN_LIFETIME_MS = 45 * 60 * 1000;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") {
      return json({ error: "POST only" }, 405);
    }
    // Constant-time-ish: compare after both are known-length strings. A relay
    // that is open is a relay that sends spam under your certificate.
    const offered = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "");
    if (!env.RELAY_KEY || !timingSafeEqual(offered, env.RELAY_KEY)) {
      return json({ error: "unauthorized" }, 401);
    }

    let push: PushRequest;
    try {
      push = await request.json();
    } catch {
      return json({ error: "malformed JSON" }, 400);
    }
    if (!push.token || !push.body) {
      return json({ error: "token and body are required" }, 400);
    }

    const jwt = await providerToken(env);
    const order: (keyof typeof HOSTS)[] = push.environment
      ? [push.environment]
      : ["sandbox", "production"];

    let last = { status: 0, reason: "no attempt" };
    for (const host of order) {
      const result = await send(HOSTS[host], jwt, env, push);
      if (result.status === 200) {
        return json({ ok: true, environment: host });
      }
      last = result;
      // Only a token from the other environment is worth a second attempt.
      // Anything else is a real error and retrying just doubles it.
      if (result.reason !== "BadDeviceToken") break;
    }
    return json({ ok: false, status: last.status, reason: last.reason }, 502);
  },
};

async function send(host: string, jwt: string, env: Env, push: PushRequest) {
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": env.APNS_TOPIC,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  };
  if (push.collapseID) headers["apns-collapse-id"] = push.collapseID.slice(0, 64);

  const response = await fetch(`${host}/3/device/${push.token}`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      aps: {
        alert: { title: push.title, subtitle: push.subtitle, body: push.body },
        "thread-id": push.threadID,
        "interruption-level": "active",
      },
    }),
  });

  if (response.status === 200) return { status: 200, reason: "ok" };
  // Apple's reason string is the only actionable part; the status alone never
  // says which of a dozen things went wrong.
  let reason = "unknown";
  try {
    reason = ((await response.json()) as { reason?: string }).reason ?? "unknown";
  } catch { /* empty body on some errors */ }
  return { status: response.status, reason };
}

async function providerToken(env: Env): Promise<string> {
  if (cached && Date.now() - cached.issued < TOKEN_LIFETIME_MS) return cached.jwt;

  const key = await importKey(env.APNS_KEY_P8);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const payload = base64url(
    JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })
  );
  const signingInput = `${header}.${payload}`;

  // WebCrypto returns raw r‖s for ECDSA, which is exactly what JWS wants. A DER
  // signature here is the classic cause of a 403 InvalidProviderToken that
  // looks like a wrong key.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );

  const jwt = `${signingInput}.${base64urlBytes(new Uint8Array(signature))}`;
  cached = { jwt, issued: Date.now() };
  return jwt;
}

async function importKey(pem: string): Promise<CryptoKey> {
  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0)
  );
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

function base64url(text: string): string {
  return base64urlBytes(new TextEncoder().encode(text));
}

function base64urlBytes(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}
