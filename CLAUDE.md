# Coach — iOS

Native SwiftUI trainer dashboard, the counterpart to the Coach PWA
(`www.dugcanlift.com/coach/`, source in the `LIFT` superproject's `coach/`
submodule). A trainer receives a client's LIFT training/nutrition log as a
compact link and reviews it here — training volume, fuel vs. goal,
bodyweight trend, per-lift progression.

## Build commands

```bash
make doctor     # verify tooling
make project    # regenerate Coach.xcodeproj from project.yml
make build      # build for simulator
make test       # run unit tests
make run        # build, install, launch
make logs       # tail app logs
```

Never edit `Coach.xcodeproj` — it is generated and gitignored. To change
targets, entitlements, Info.plist keys or capabilities, edit `project.yml`
and run `make project`.

## Architecture

- **`Sources/Shared/`** — SwiftData models, the link decoder, the backup
  codec. Kept separate from `Sources/App/` from day one even though there
  is no widget target yet, matching `lift-ios`'s own split — cheap now,
  and avoids a retroactive split if a widget is ever added later.
- **`Sources/App/`** — SwiftUI views (`RosterView`, `ClientDetailView`,
  `ConnectView`).

## Design spec

`LIFT` superproject repo,
`docs/superpowers/specs/2026-09-10-coach-ios-design.md` — the binding
design authority for v1 (Roster + Client + Connect; Cook/Train deferred
to v2). Read it before writing an implementation plan or making an
architectural judgment call this file doesn't cover.

## Conventions that matter

**No backend, no accounts.** Matches both LIFT's and the Coach PWA's own
design exactly — single trainer per device, `SwiftData` is the only
persistence, nothing here ever talks to a server DUGCANLIFT operates.

**Universal Links do not work on this team.** Doug's signing team
(`QG57FJM5C8`) is a free Apple Personal Team — Associated Domains fails at
build time on a free team (confirmed by `lift-ios`'s own build history).
Do not add the Associated Domains entitlement or attempt to intercept
`https://www.dugcanlift.com/coach/#...` links via Universal Links. v1
ingestion is a "Paste a link" text field; a Share Extension (which needs
no Associated Domains entitlement) is a documented fast-follow, not v1.

**The wire format is a contract with `lift-ios`, not just a doc.**
`SHARE-FORMAT.md`/`BACKUP-FORMAT.md` (in the `LIFT` superproject's
`coach/` submodule and mirrored at `dugcanlift-site/coach/`) describe the
intended shape; `lift-ios`'s `Sources/Shared/CoachShare.swift` (encoder)
and `Sources/Shared/PlanLinkCodec.swift` (a real decoder for the reverse
direction, and this app's direct template) are the actual, shipped,
tested behavior. Where the two disagree, match the real code, not the
prose — see the design spec's "Decoding" section for three specific,
already-identified discrepancies.

**Weights are pounds on the wire, always** (`SHARE-FORMAT.md`), regardless
of what unit a client's own app displays. Don't convert on decode; store
what the wire says and let a future display-preference feature handle
presentation, mirroring `lift-ios`'s "canonical unit, display converts at
the view layer only" rule for its own `WeightUnit`.

**Coach's UI matches LIFT's brand colors, on every platform.** `lift-ios`'s
`Sources/App/Theme.swift` is the canonical palette — "design tokens
extracted from the Android build of LIFT... sampled directly from app
screenshots," already an established cross-platform token set (Android →
iOS once; iOS → this repo now). Port `Theme.swift` verbatim (same hex
values, same token names: `background`, `surface`, `accent`,
`accentMuted`, `textPrimary`, `textSecondary`, `hairline`) rather than
inventing a separate Coach palette — a trainer using both LIFT and Coach
should never wonder if they're in a different product. When Coach Android
or Coach Watch are built, port the same hex values there too (from
whichever LIFT platform's own theme file is most convenient to read them
from) rather than resampling screenshots independently.

## Constraints

- iOS 17.0 minimum (SwiftData).
- No backend, no accounts, no push notifications.
- No Cook/Train (recipe/workout authoring) in v1 — that's a v2, per the
  design spec's explicit scope cut.
