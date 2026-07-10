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
| `BGTaskSchedulerPermittedIdentifiers` | `com.jerry.brief.refresh` | The BGAppRefreshTask identifier |
| `GIDClientID` | placeholder — replace in step 3 | Google Sign-In |
| `CFBundleURLTypes` → URL scheme | placeholder — replace in step 3 | Google Sign-In redirect |

The **Background Modes → Background fetch** capability is provided by the
`UIBackgroundModes` entry; you do not need to toggle anything in Signing &
Capabilities. Notification permission is requested at runtime — no capability
needed for local notifications.

If you change the bundle identifier, also change the background task
identifier is **not** required — it is an app-chosen string and stays
`com.jerry.brief.refresh`.

---

## 2. AI Provider

Brief talks to whatever OpenAI-style `/chat/completions` endpoint you point
it at. It currently defaults to **Bazaarlink** (`https://bazaarlink.ai/api/v1`),
but **Settings → AI Provider** has an API Base URL field so any compatible
provider works without a rebuild.

1. Create an API key with your provider and make sure it has credit (or is
   using a free tier).
2. Build and run the app (Cmd-R) on your iPhone.
3. In the app: **Settings → AI Provider**:
   - **API Base URL** — defaults to `https://bazaarlink.ai/api/v1`. Change
     this to switch providers (no trailing `/chat/completions`, no trailing
     slash).
   - **API Key** — paste the key → **Save Key**. Stored in the iOS
     Keychain, never in source or logs, and only ever sent to the base URL
     above.
   - **Test Connection** — sends one minimal completion request to confirm
     the key and base URL work together.
4. **Structured JSON output** and **Web search plugin** toggles, further
   down the same screen, control OpenRouter-style extensions to the
   request that Bazaarlink also appears to use:
   - *Structured JSON output* sends a strict `response_format: json_schema`
     field so responses are guaranteed to match Brief's data model. Turn
     this off only if your provider rejects that field outright — Brief
     falls back to asking for JSON in plain language, which is less
     reliable but still generally decodable.
   - *Web search plugin* attaches OpenRouter's `plugins: [{id: "web"}]`
     block so research requests are grounded in live search results. If
     your provider doesn't support this specific plugin syntax, turn it
     off — research will then rely on the model's own knowledge instead of
     live web search, which will be noticeably less current.
   - If you're not sure whether a new provider supports either extension,
     leave both on and watch **Settings → Data → Export diagnostic JSON**
     after a generation attempt: HTTP errors there usually name the
     rejected field.
5. **Settings → Models** — research and editor models both default to
   `openai/gpt-oss-120b:free`: OpenAI's open-weight GPT model (gpt-oss),
   on the free tier, following the same `:free` suffix convention
   OpenRouter uses. This slug is an informed guess about Bazaarlink's
   catalog, not a verified one — run **Test Connection** after setup, and
   if it's rejected, try `auto:free` or check Bazaarlink's own model list
   for the exact free-tier slug.

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
  7:30 AM) and says "Your morning brief is waiting."
- **Background App Refresh** — best-effort pre-generation before your morning
  time. iOS decides if/when it runs; the app never depends on it and always
  generates on launch when today's brief is missing or stale.

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
