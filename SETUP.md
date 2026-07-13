# Brief — Setup

Brief is a private, one-person iPhone app. It has no backend: the phone talks
directly to OpenRouter, Google Calendar, and Open-Meteo. Setup takes about
fifteen minutes and is done once.

Requirements: **Xcode 16 or later**, **iOS 17 or later** on the phone.

---

## 1. Open and configure the Xcode project

1. Open `Brief.xcodeproj` in Xcode.
2. Select the **Brief** target → **Signing & Capabilities**:
   - Set your **Team** (a free personal team works).
   - Change the **Bundle Identifier** if you like (default `com.jerry.brief`).
     If you change it, use the new value when creating the Google OAuth client
     in step 3.
3. Xcode resolves the single Swift Package dependency automatically on first
   open: **GoogleSignIn-iOS** (via Swift Package Manager,
   `https://github.com/google/GoogleSignIn-iOS`, from 8.0.0).

### Capabilities and Info.plist (already configured — verify only)

Everything below is already present in `Brief/Info.plist`; nothing to add
unless you rename the bundle ID or want to re-check:

| Key | Value | Purpose |
| --- | --- | --- |
| `NSLocationWhenInUseUsageDescription` | "Brief uses your location to show the correct morning weather." | Core Location prompt |
| `UIBackgroundModes` | `fetch` | Background app refresh |
| `BGTaskSchedulerPermittedIdentifiers` | `com.jerry.brief.refresh`, `com.jerry.brief.breakingcheck` | The two BGAppRefreshTask identifiers |
| `GIDClientID` | placeholder — replace in step 3 | Google Sign-In |
| `CFBundleURLTypes` → URL scheme | placeholder — replace in step 3 | Google Sign-In redirect |

The **Background Modes → Background fetch** capability is provided by the
`UIBackgroundModes` entry; you do not need to toggle anything in Signing &
Capabilities. Notification permission is requested at runtime — no capability
needed for local notifications.

If you change the bundle identifier, changing the background task
identifiers is **not** required — they are app-chosen strings and stay
`com.jerry.brief.refresh` / `com.jerry.brief.breakingcheck`.

### API usage is capped to two things

The brief itself only ever regenerates under two conditions: at the
configured morning time, or a manual tap on refresh — never automatically
just because it's gotten old, and never as a side effect of another
setting change (e.g. connecting Google Calendar). Separately, a much
cheaper hourly check (`com.jerry.brief.breakingcheck`, toggled in
**Settings → Breaking Alerts**) makes one small, capped-length completion
call roughly once an hour, looking only for news urgent enough to
interrupt the day. Almost every hour it finds nothing and costs nothing;
when it does find something, it's saved on-device and a notification is
sent — tapping that notification never triggers a brief generation.

---

## 2. AI Provider

Brief supports two built-in providers at once — **OpenRouter**
(`https://openrouter.ai/api/v1`) and **Bazaarlink**
(`https://bazaarlink.ai/api/v1`) — each with its own Keychain-stored key.
Generation tries **Settings → AI Provider → Preferred provider** (default
OpenRouter) first, and automatically retries with the other one if it has
a saved key and the first attempt fails — "use whichever one works."

1. Create an API key with each provider you want configured (a single one
   is enough to generate; a second is just automatic backup) and make sure
   it has credit or is using a free tier.
2. Build and run the app (Cmd-R) on your iPhone.
3. In the app: **Settings → AI Provider**. Each provider has its own
   section:
   - **API Key** — paste the key → **Save Key**. Stored in the iOS
     Keychain, never in source or logs, and only ever sent to that
     provider's base URL.
   - **Test Connection** — sends one minimal completion request to confirm
     that provider's key works.
   - **Preferred provider**, at the top of the screen, picks which one is
     tried first.
4. **Structured JSON output** and **Web search plugin** toggles, further
   down the same screen, control OpenRouter-style extensions to the
   request that Bazaarlink also appears to use, and apply to whichever
   provider ends up handling a given request:
   - *Structured JSON output* sends a strict `response_format: json_schema`
     field so responses are guaranteed to match Brief's data model. Turn
     this off only if a provider rejects that field outright — Brief
     falls back to asking for JSON in plain language, which is less
     reliable but still generally decodable.
   - *Web search plugin* attaches OpenRouter's `plugins: [{id: "web"}]`
     block so research requests are grounded in live search results. If
     a provider doesn't support this specific plugin syntax, turn it off
     — research will then rely on the model's own knowledge instead of
     live web search, which will be noticeably less current.
   - If you're not sure whether a provider supports either extension,
     leave both on and watch **Settings → Data → Export diagnostic JSON**
     after a generation attempt: HTTP errors there usually name the
     rejected field.
5. **Settings → Models** — research and editor models both default to
   `openai/gpt-4o-mini`, a paid model, on purpose: every free/open-weight
   option tried here turned out unreliable in a different way, confirmed
   on-device across several rebuilds —
   - `auto:free` (OpenRouter's own "any free model" routing) landed on
     `deepseek/deepseek-v4-flash`, an unrelated provider.
   - `openai/gpt-oss-120b:free` pinned alone got upstream-rate-limited
     under real demand.
   - `openai:free` (a Brief-specific sentinel that fell back between
     `gpt-oss-120b:free` and `gpt-oss-20b:free` via OpenRouter's `models`
     list field) repeatedly returned structured output that failed to
     decode even after the one repair attempt.

   `gpt-4o-mini` costs a small fraction of a cent per generation and has
   solid, consistent JSON schema support — worth it for a brief that only
   gets one shot a day. The free-tier suggestions are still available in
   that screen (`openai:free`, `auto:free`, DeepSeek's `:free` models) if
   you'd rather trade reliability back for zero cost.

---

## 3. Google Calendar (one-time Google Cloud setup)

**Already done for this build** — `Brief/Info.plist` already has a real
`GIDClientID` and matching `CFBundleURLSchemes` entry wired in, so
**Settings → Connect Google Calendar** should work as-is. The walkthrough
below is only needed if you ever change the bundle identifier (which
invalidates the existing iOS OAuth client) or want a client ID of your own.

Because this is a private app, the Google Cloud project stays in *testing*
mode forever — no verification, no publishing. There is no in-app field for
the client ID: iOS OAuth clients have no client secret, but the redirect URL
scheme they rely on has to be declared in Info.plist at build time, so the ID
belongs there rather than in a runtime settings screen.

1. Go to <https://console.cloud.google.com/> and create (or select) a project,
   e.g. "Brief".
2. **APIs & Services → Library** → search **Google Calendar API** → **Enable**.
3. **APIs & Services → OAuth consent screen**:
   - User type: **External**, then fill in only the required fields.
   - **Keep the app in Testing** (do not publish).
   - Under **Test users**, add your own Google account
     (`jerryhuang.hjr@gmail.com`).
   - Scopes: you may add `https://www.googleapis.com/auth/calendar.readonly`,
     though for testing mode this is optional — the app requests it at sign-in.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **iOS**.
   - Bundle ID: exactly the app's bundle identifier (default
     `com.jerry.brief`).
5. Copy the generated **client ID** (looks like
   `1234567890-abc123.apps.googleusercontent.com`) and edit
   `Brief/Info.plist`:
   - `GIDClientID` → the full client ID.
   - `CFBundleURLSchemes` → the **reversed** client ID:
     `com.googleusercontent.apps.1234567890-abc123`
     (i.e. the client ID with the two halves swapped, no
     `.apps.googleusercontent.com` suffix).
6. Rebuild and run. In the app: **Settings → Connect Google Calendar** →
   sign in and allow *read-only* calendar access.
7. Optional: **Settings → Select Calendars** to include calendars beyond the
   primary one. Access is read-only; the app never creates, edits, or deletes
   events.

---

## 4. Permissions on first run

- **Location** — requested the first time weather is fetched. If denied, set
  a city under Settings (manual city), or the app falls back to Berkeley, CA.
- **Notifications** — requested when the morning notification toggle is on
  (default). The reminder fires at the configured morning time (default
  6:00 AM) and prompts you to tap it to generate today's brief — the brief
  is never pre-generated in the background, so tapping is what starts it.
- **Background App Refresh** — used only for the hourly breaking-news check.
  iOS decides if/when it runs; the app never depends on it and always
  checks on launch too.

---

## 5. How the briefing pipeline works

1. **Local context** — date/timezone, location, Open-Meteo weather, and
   today's + this week's Google Calendar events are fetched concurrently.
2. **Research** — up to six focused, web-grounded OpenRouter requests run
   concurrently (world/US/Canada/China, business & markets, technology & AI,
   Formula 1, sports, UC Berkeley). Each returns structured candidate stories;
   every source URL is validated against OpenRouter's citation annotations.
   A failed request never cancels the others.
3. **Editing** — an editor model receives the candidates, calendar, weather,
   your preferences, and the last seven days of story fingerprints, and
   returns the strict-JSON briefing (overview, sections, practical weather
   note). It may only reference supplied candidate IDs as sources.
4. **Validation** — the app decodes against Swift models, drops empty
   headlines, duplicate URLs/headlines, implausible dates, and sourceless
   stories, and enforces section limits. Calendar times and weather numbers
   are always rendered from the real API data — the model cannot rewrite them.
5. **Persistence** — the brief is saved with SwiftData (30-day retention) and
   appears in History.

Costs are bounded: one briefing = up to six research calls + one editor call
(plus at most one repair call). Refreshing within five minutes of a
generation asks for confirmation first.

## 6. Troubleshooting

- **"Add your OpenRouter API key in Settings"** — step 2 above.
- **Google shows "access blocked"** — your account isn't in the OAuth test
  users list, or the bundle ID doesn't match the iOS client.
- **Sign-in succeeds but calendar is missing** — Settings shows "Permission
  missing"; disconnect and reconnect, granting calendar read-only access.
- **Diagnostics** — Settings → Data → *Export diagnostic JSON* describes the
  last generation (models, tokens, per-step results). It never contains keys
  or tokens.
- **Preview without spending credits** — debug builds have Settings → Data →
  *Load sample briefing (debug)*.
