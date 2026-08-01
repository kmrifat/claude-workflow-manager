# Claude WM push relay

A Cloudflare Worker that holds the APNs key so the app doesn't have to.

## Why it exists

A push must be signed by something holding an APNs auth key. Without a relay
that something is each user's Mac, which means shipping the `.p8` inside the
app — and an auth key is *account-wide*, so anyone who extracts it can push to
every app on the developer account, with no way to revoke it that doesn't break
every user at once.

Moving the key here doesn't eliminate the leak, it shrinks it. The `RELAY_KEY`
that apps carry is still extractable, but a leaked one only opens this relay, to
device tokens the holder would have to already know, and rotating it is one
redeploy.

It stores nothing, logs no payloads, and sees a device token and a card title
only for as long as it takes to forward them.

## Deploy

```bash
cd PushRelay
npx wrangler login
```

```bash
npx wrangler secret put APNS_KEY_P8
```

Paste the whole `.p8`, `BEGIN`/`END` lines included. Then the other three:

```bash
npx wrangler secret put APNS_KEY_ID
```

```bash
npx wrangler secret put APNS_TEAM_ID
```

```bash
npx wrangler secret put RELAY_KEY
```

For the last one use something long and random:

```bash
openssl rand -base64 32
```

Then:

```bash
npx wrangler deploy
```

## Point the Mac app at it

Two `Info.plist` keys, so a shipped app already knows and never asks a user:

```xml
<key>ClaudeWMPushRelayURL</key>
<string>https://claude-wm-push.YOUR-SUBDOMAIN.workers.dev</string>
<key>ClaudeWMPushRelayKey</key>
<string>the RELAY_KEY value</string>
```

`UserDefaults` (`pushRelayURL`, `pushRelayKey`) overrides both — that is the
seam for self-hosting, and nobody else ever sees it.

With a relay configured the app prefers it and the local `.p8` path is unused.
Without one it falls back to `APNsClient`, which talks to Apple directly using a
key in this Mac's Keychain. That fallback is for the person who owns the key and
would rather not run anything.

## Check it before wiring the app in

```bash
curl -i -X POST https://claude-wm-push.YOUR-SUBDOMAIN.workers.dev \
  -H "authorization: Bearer YOUR_RELAY_KEY" \
  -H "content-type: application/json" \
  -d '{"token":"A_REAL_DEVICE_TOKEN","title":"Test","body":"Hello from the relay"}'
```

`{"ok":true,"environment":"sandbox"}` means it reached Apple. The reasons worth
recognising:

| Reason | Cause |
|---|---|
| `401 unauthorized` | `RELAY_KEY` mismatch — the relay, not Apple |
| `InvalidProviderToken` | `APNS_KEY_ID` or `APNS_TEAM_ID` wrong, or the `.p8` isn't that key |
| `BadDeviceToken` | Token from the other environment; the relay already retried both, so the token itself is wrong |
| `TopicDisallowed` | `APNS_TOPIC` isn't the iOS app's bundle id |
| `Unregistered` | The app was deleted from that device — the Mac drops the token when it sees this |
