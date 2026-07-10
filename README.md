# Brief

A private morning intelligence briefing for one person.

Open once. Understand the day. Leave.

Brief replaces the morning round of news sites, ESPN, F1 apps, weather apps,
and Google Calendar with a single five-minute editorial briefing: what
happened in the world overnight, what matters in technology and AI, Formula 1
and sports, UC Berkeley, today's calendar, and the weather — researched on
the web via an OpenAI-style chat completions API (OpenRouter by default,
any compatible provider by changing one URL in Settings), edited into a
compact brief, and rendered in an editorial, newspaper-inspired interface.

- **Native SwiftUI**, iPhone, iOS 17+, Swift concurrency, SwiftData
- **No backend, no accounts, no analytics** — the phone calls your chosen AI
  provider, Google Calendar (read-only), and Open-Meteo directly
- API key lives in the Keychain; preferences and history stay on device
- Deliberately finite: no feeds, no trending tabs, no engagement mechanics

See [SETUP.md](SETUP.md) for the one-time AI provider and Google Cloud setup.
