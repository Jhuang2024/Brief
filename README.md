# Brief

A private morning intelligence briefing for one person.

Open once. Understand the day. Leave.

Brief replaces the morning round of news sites, ESPN, F1 apps, weather apps,
Gmail, and Google Calendar with a single five-minute editorial briefing:
what happened in the world overnight, what matters in technology and AI,
Formula 1 and sports, UC Berkeley, today's calendar, overnight email, and
the weather — researched on the web via OpenRouter and/or Bazaarlink (both
can be configured at once, with automatic failover to whichever one works),
edited into a compact brief, and rendered in an editorial,
newspaper-inspired interface. Email is read-only, shown verbatim, and never
sent to any AI provider.

When [LockedInFit](https://github.com/Jhuang2024/locked-in-fit) and
[Social Climber](https://github.com/Jhuang2024/Social-Climber) are installed
on the same iPhone, the brief also carries a section from each: yesterday's
workouts, nutrition, and sleep, yesterday's social activity, and each app's
reminders for today — read on-device from a shared App Group, rendered
verbatim, never sent to any AI provider. See
[LINKED_APPS.md](LINKED_APPS.md).

- **Native SwiftUI**, iPhone, iOS 17+, Swift concurrency, SwiftData
- **No backend, no accounts, no analytics** — the phone calls your AI
  provider(s), Google Calendar (read-only), and Open-Meteo directly
- API keys live in the Keychain; preferences and history stay on device
- **Automatic local backups** (same design as LockedInFit's): the briefing
  history, alerts, and preferences are snapshotted after each generation
  and on backgrounding, rotated locally, and mirrored to the shared App
  Group container so they survive app updates and reinstalls; restore from
  Settings → Backups. A byte-for-byte copy of the raw store is also taken
  before any schema migration. API keys are never in a backup.
- Deliberately finite: no feeds, no trending tabs, no engagement mechanics

See [SETUP.md](SETUP.md) for the one-time AI provider and Google Cloud setup.
