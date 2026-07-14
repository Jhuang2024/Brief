# Linked Apps: LockedInFit & Social Climber

Brief can include two personal sections in every morning briefing:

- **LockedInFit** — what you did yesterday (workouts, nutrition, sleep, steps) and your health reminders for today.
- **Social Climber** — yesterday's social activity (interactions, events) and today's social reminders (follow-ups, birthdays, events).

There is no server involved. All three apps run on the same iPhone and share a
single App Group container; each source app writes a small JSON "brief feed"
file into it, and Brief reads those files at generation time. The sections are
assembled deterministically from the feeds — the AI editor never sees or
rewrites them, so nothing can be hallucinated.

## The App Group

All three apps declare the same App Group in Signing & Capabilities:

```
group.com.jerry.personalOS
```

LockedInFit and Social Climber already use this group for their peer bridge
(`lockedinfit_public_context_v1.json` / `socialclimber_public_context_v1.json`).
The brief feeds are two additional, richer files in the same container:

| File | Writer | Reader |
|---|---|---|
| `lockedinfit_brief_feed_v1.json` | LockedInFit | Brief |
| `socialclimber_brief_feed_v1.json` | Social Climber | Brief |

Unlike the peer-bridge snapshots (deliberately minimal, consumed by the *other*
app), the brief feeds are written for the user's own eyes in their own morning
brief, so they may carry names, titles, and metric details.

## Feed schema (v1)

Written atomically (temp file + replace), JSON, ISO-8601 dates.

```jsonc
{
  "app": "LockedInFit",              // or "SocialClimber"
  "schemaVersion": 1,
  "generatedAt": "2026-07-13T21:14:05Z",   // ISO-8601, when the feed was written
  "days": [                          // up to 3 most recent local days with data, newest first
    {
      "date": "2026-07-13",          // LOCAL calendar day, "yyyy-MM-dd"
      "lines": [                     // ≤ 8 human-readable summary lines, most important first
        "Completed Push Day A — 62 min, 8 exercises",
        "2,150 cal / 168 g protein (target 2,300 / 170)"
      ]
    }
  ],
  "reminders": [                     // overdue + due within 2 days of generatedAt, ≤ 12
    {
      "id": "stable-string",
      "title": "Face check-in",
      "detail": "optional secondary text",   // optional; may be absent
      "dueDate": "2026-07-14T09:00:00Z",     // ISO-8601
      "isAllDay": false,             // true → Brief hides the time
      "overdue": false               // true when past due and incomplete at write time
    }
  ]
}
```

Rules for writers:

- **Publish opportunistically** — every time the app already refreshes its
  peer-bridge snapshot (dashboard load/refresh). Overwrites are atomic, so
  frequent writes are safe.
- **`days[].date` is a local calendar day.** Compute each day's lines from that
  day's records only. Include a day only if it has something to say.
- **Recurring reminders** (e.g. daily checklist items): project an occurrence
  for tomorrow as well, so a feed written tonight still carries tomorrow
  morning's items.
- **Fail silent.** No App Group container, no signing, encoding error → no-op.
  The feed must never affect the writing app's own behavior.

Rules for Brief (the reader):

- **Yesterday** = the day before the briefing date, matched against
  `days[].date` in the local timezone. If missing, fall back to the most recent
  entry within the last 3 days and label it with its date.
- **Today's reminders** = entries with `overdue == true`, plus entries whose
  `dueDate` falls on the briefing day (local).
- **Staleness**: a feed older than 48 hours is treated as unavailable
  ("open the app to refresh"); 24–48 hours renders with an "as of" caveat.
- **Defensive decoding**: missing keys, unknown fields, or a corrupt file must
  read as "no data", never an error. Schema versions above 1 are accepted
  (additive changes only).

## Setup

1. LockedInFit and Social Climber already declare the App Group; Brief's target
   needs the **App Groups capability** with `group.com.jerry.personalOS` checked
   (the entitlement file is in the repo; Xcode will register the group with
   your team the first time you build with a signing team selected).
2. Open LockedInFit and Social Climber at least once after updating so they
   write their first feed.
3. In Brief's Settings, the LockedInFit and Social Climber sections can be
   toggled independently.

If a feed is missing or stale, Brief says so in the section rather than
silently omitting it, so you can tell "not set up" apart from "nothing
happened yesterday".
