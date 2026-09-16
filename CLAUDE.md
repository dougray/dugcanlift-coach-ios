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

Note on itemized-food servings: `lift-ios`'s encoder always sends
`servings: 1` with already-multiplied totals, so "never multiply" looked
like a safe reading of the wire format when only that encoder was
checked. That's `lift-ios`-specific behavior, not a general wire-format
rule — Android's real encoder sends true per-serving macros plus a real
servings count, so the importer must multiply on decode (a no-op for
`lift-ios` payloads, correct for Android ones). See
`Sources/Shared/ShareLinkImporter.swift`.

**Weights are pounds on the wire, always** (`SHARE-FORMAT.md`), regardless
of what unit a client's own app displays. Don't convert on decode; store
what the wire says, mirroring `lift-ios`'s "canonical unit, display
converts at the view layer only" rule for its own `WeightUnit`.

`Client.displayUnit` is that view-layer conversion, and it is wired as of
issue #7 — `ClientDisplay.weightValue` / `weightText` / `weightWithUnit`,
dividing by 2.2046226218 for a "kg" client. It was decoded, stored and
round-tripped for weeks while no view read it, so a client who logs in
kilograms saw 209.4 where Android showed 95. A converted value must never
reach storage, a statistic or a comparison: convert at the point of
display and nowhere else.

**A lift's identity is name *and* equipment.** The exercise dictionary is
keyed `"name|equipment"` because a cable pulldown and a machine pulldown
are not the same lift. Grouping the e1RM chart on `exerciseName` alone
merged them into one zig-zagging trend line — use `ClientDisplay.liftKey`.

**Coach's UI matches LIFT's brand colors, on every platform.** `Theme` —
"design tokens extracted from the Android build of LIFT... sampled directly
from app screenshots," already an established cross-platform token set
(Android → iOS once) — now lives in `dugcanlift-kit`'s `LiftCore` product,
not a per-app file. Use that shared `Theme` (same hex values, same token
names: `background`, `surface`, `accent`, `accentMuted`, `textPrimary`,
`textSecondary`, `hairline`) rather than inventing a separate Coach palette
or porting a copy — a trainer using both LIFT and Coach should never wonder
if they're in a different product. When Coach Android or Coach Watch are
built, port the same hex values there too (read them from `LiftCore`'s
`Theme.swift`, the one canonical source now) rather than resampling
screenshots independently.

**Light and dark both exist, and System is the default.** `Theme`'s tokens
resolve per interface style (LiftKit 1.7.0), so use them rather than any fixed
colour. Apply `.liftAppearance()` — never `.preferredColorScheme(.dark)` — on
the root and on any sheet that needs it, and draw a card with `LiftCard` or
`.liftCardBackground()` rather than `.background(Theme.surface, ...)`: light
cards need `Theme.cardBorder`, which a bare background leaves off.

## Constraints

- iOS 17.0 minimum (SwiftData).
- No backend, no accounts, no push notifications.
- Cook and Train are v2 (merged 2026-09-12) — see the `LIFT`
  superproject's `docs/superpowers/specs/2026-09-11-coach-ios-v2-design.md`.

## App Store

`Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data,
which stays true only while nothing reaches the developer — see "Coach makes
exactly two network calls". Adding any request, SDK or required-reason API
(`UserDefaults` is CA92.1; file timestamps C617.1, for SQLite) means revisiting
it. `ITSAppUsesNonExemptEncryption` is `false` in `project.yml`: HTTPS only.
Listing text is in `fastlane/metadata/en-US`, screenshots (6.9", sample data) in
`fastlane/screenshots/en-US`. Keep the description to what the app does.

## Shared code lives in LiftKit

Domain models, wire codecs, the theme and day keys live in
`dugcanlift-kit`, not here. Two products, and the split matters:

- **`LiftCore`** — no SQLite dependency, so LIFT's widget extension can
  link it.
- **`LiftReference`** — GRDB and the 2.3 MB of reference databases. Apps
  only. Adding this to a widget target would hand it a SQLite dependency
  and data it never opens.

A change there reaches two shipped apps. `@Model` types are shared, so a
property change is a schema change for both — and `lift-ios`'s
`LiftSchemaVersions.swift` explains what that costs.

Day keys are **local**, and day arithmetic goes through `Calendar`. Never
`now - days * 86400`: it repeats a day across a DST fall-back.

## `ClientFoodEntry`, and why it is not `FoodEntry`

`LiftCore` carries its own `FoodEntry` — the athlete-side one — and
**SwiftData identifies an entity by its class's simple name, not
module-qualified**. Two `@Model` classes named `FoodEntry` in one schema do
not clash loudly: the schema builds with no error, reports a single entity
holding whichever type was listed last, and then fails at `save()` with a
Core Data validation error naming the *other* type's properties.

Coach reaches that state as soon as Cook stores `LiftCore.PlannedMeal` here,
because `PlannedMeal.makeFoodEntry()` returns a `LiftCore.FoodEntry`.
Qualifying the Swift name as `Coach.FoodEntry` does not help; that is symbol
lookup, one level above entity identity.

`EntityNameCollisionTests` pins this. Do not rename the type back.

**The rename dropped existing rows, deliberately.** Renaming a `@Model`
class renames its entity, and Coach has no migration plan — the store opens
cleanly and the old rows are simply gone. Chosen on 2026-09-12 over writing
a full frozen-graph migration, because Coach was days old and its data is
re-creatable: re-paste a client's share link, or restore a backup file,
whose JSON uses plain field names independent of the entity name. If Coach
ever holds data that is not re-creatable, that calculation changes and a
future rename needs a real migration.

## Train

Workout templates are `LiftCore`'s `Routine` / `RoutineExercise` /
`RoutinePrescribedSet`. Scheduling is Coach's own `ScheduledSession`, which
holds `clientID` and `routineID` as plain values rather than relationships —
a template is reused across clients and weeks, and cascade rules do not match
how a coach thinks about that. The cost is that SwiftData's delete rules never
reach a session, so deleting a `Routine` directly would orphan its bookings.
`ScheduledSession.deleteRoutineAndSessions` deletes the routine and every
session booked against it in one action; call it from anywhere a `Routine` is
deleted, never `context.delete(routine)` alone. `TrainView` confirms first and
says how many booked days the delete empties, across every client
(`bookingCount` / `deleteWarning`), matching Coach web and Coach Android.

An orphan can still exist in a store written before the reaper, or restored
from such a backup. It shows in the week as "Removed workout"
(`TrainPlanView.name(of:)`), where the coach can remove it, and the encoder
drops it from a send, because `x` must index a workout that is in `w`.

**`RoutinePrescribedSet` stores kilograms. `PLAN-FORMAT`'s set tuple is
pounds.** `PlanLinkEncoder.kgToLb` converts on the way out, LIFT's
`PlanImporter` converts back on the way in, and both delegate to
`LiftCore.WeightUnit` rather than carrying their own factor. A missing
conversion is silent and 2.2x wrong on a client's phone.
`PlanLinkEncoderTests` pins it — removing the conversion fails four tests.

`PlanLinkInteropTests` decodes `Tests/Fixtures/web-plan-link.txt`, a link the
**Coach web app's own encoder** produced. It is the only test here that
proves interoperability rather than agreement with itself. Do not regenerate
it from this code; that would defeat its entire purpose.

A set's fields are all optional. `[null, 5]` is "five reps, you pick the
weight". Blank must never become zero, in the payload or on screen.

Only **trailing** nulls are trimmed from a set tuple. A conditioning piece is
`[null, null, null, 600, 1600]`, and trimming leading nulls would slide
distance into the weight slot.

Train's screens use a raw `ScrollView` and so must inset themselves for the
floating tab bar. `List` and `Form` reserve that space automatically, which
is why `RosterView` and `ConnectView` do not need it.

## Cook

Recipes, ingredients, planned meals and shopping ticks are `LiftCore`'s
`Recipe` / `RecipeIngredient` / `PlannedMeal` / `ShoppingListCheck`. Coach adds
no recipe models of its own. `LiftCore.FoodEntry` is deliberately **not** in the
schema: `PlannedMeal.makeFoodEntry()` can build one, but a coach plans meals
rather than logging them.

**`IngredientParser` and `CookFormat` live in `LiftCore`** as of 1.1.0. The
parsing rules exist in four places — the package, `coach/parser.js`, and the
Android and web builds of LIFT — and `parser.js` says plainly that all four must
give the same answer for the same line. Do not add a local copy.

**The count sentinel is `"\u{0000}count"`.** An ingredient with no unit ("2
eggs") still needs a grouping key, so two eggs are never added to two cups of
anything — but it is not a unit and must never reach a screen.
`CookFormat.amountsLabel` drops it.

**Only weights get costed.** `g`, `kg`, `mg`, `oz`, `lb`, `lbs`. Pricing "2 tbsp
olive oil" means inventing a density, and a confident wrong calorie count is
worse than a gap the coach can see. The gap is stated in words, with a count,
in the recipe editor's macro section and on the library card.

**A typed macro wins over a computed one, and blank stays blank.**
`MacroFields` holds both rules, as a value type with no view in it, because a
rule living in a view's `@State` cannot be tested. A zero written by an
untouched form becomes a zero-calorie dinner in a client's day total.

**Match the formatter to the parser that reads the text back.** There are two
parsers with opposite locale behaviour in Cook, and pairing either with the
other's formatter is a silent corruption, not a crash. `OptionalNumberField
.value(from:)` is locale-aware (a `NumberFormatter`, grouping off) — pair it
with `OptionalNumberField.string(from:)`, and nothing else: `CookFormat
.trimmed` emits a `.` decimal that a German parser reads as a thousands
separator, so a reopened recipe's 36.5 g of protein comes back nil and the
`?? 0` fallback writes a zero into a client's day. `IngredientParser.parse` is
locale-invariant and reads digits and `.` only — pair it with `CookFormat
.trimmed`, and never `OptionalNumberField.string`, which would write
"600,5 g" in `de_DE` and be read back as 600. `RecipeEditorView.load()` is the
servings field, the first kind; `ingredientLine(for:grams:)` is an ingredient
line, the second. Both defects were found in code the plan supplied;
`MacroTallyTests` pins the first under an explicit `de_DE` locale.

**`onChange` fires on programmatic writes, not just on typing.**
`MacroFields.applyComputed` records the exact string it wrote to each field,
and `macroField`'s `onChange` calls `userEdited(_:to:)`, which marks a field
typed only when the new text differs from that record. Calling `markTyped`
from `onChange` directly froze every macro at the first looked-up
ingredient's contribution, because the first `applyComputed` marked all four
fields as typed before a second ingredient's numbers could ever land. Do not
"simplify" it back to `markTyped`.

**`u` is omitted from the wire when macros are nil or all-zero.**
`MacroFields.entered()` returns non-nil the moment any field has content, so a
coach typing `0` into calories would otherwise ship `u:[0,0,0,0,0]` — a
zero-calorie dinner in a client's day total. `PlanLinkEncoder.planRecipe`
guards it explicitly rather than trusting `entered()` alone.

**A recipe's weight is `totalWeightGrams`, always grams.** The editor shows
grams or ounces as the coach's `@AppStorage("recipeWeightUnit")` preference —
never a volume, for the reason only weights get costed. **Switching the unit
converts through grams; it never relabels the number.** Relabelling turned
1200 g into 1200 oz, a dish 28 times heavier, before `reweigh()` existed. Do not
"simplify" the picker's `onChange` away. Zero, negative or non-finite is "not
weighed" (`BackupCodec.weighed`), never a dish that weighs nothing. The field
travels in `BackupCodec` and `WebLibraryImporter` under the same spelling Coach
web and Coach Android write, so a weight survives moving between any of them.

**`PlannedMeal.snapshotNutrition` is per serving, never pre-scaled.** Scaling
happens at the point of use. This is the invariant the 2026-09-10 half-calories
bug came from breaking.

**A planned meal's client lives in `@AppStorage`, not on the model.**
`LiftCore.PlannedMeal` has no client field — on LIFT it belongs to the only
person on the device. Adding one is a schema change for two shipped apps, so
Coach keeps a UUID→clientID map under `cookPlanOwners` instead. It is the
smaller of two bad options and it is reversible: if Cook ever needs to query
meals by client at scale, the fix is a Coach-owned `MealBooking` model, not a
package change. The map is a contract between five participants, not three:
`CookPlanView` (writes), `ShoppingView` (reads), `CookView.delete` (sweeps
entries for the meals it deletes, via `sweepOwners`), and `BackupCodec.restore`
and `WebLibraryImporter.importLibrary` (both write it via the shared
`MealOwners` helper). Decode it once per body evaluation and thread the
result down — `CookPlanView`'s `mealRow` alone is called 7 days x 4 meal
types = 28 times per render, and the map was being decoded on every one of
those calls before review.

**Shopping ticks belong to one client.** `LiftCore.ShoppingListCheck` is keyed
by item name alone, because on LIFT the list has one owner; in Coach that made a
tick for one client a tick for all of them. Coach stores `ClientShoppingCheck`
instead — its own `@Model`, `clientID` plus `itemKey` — and `ShoppingListCheck`
is not in Coach's schema. The name is chosen so it cannot collide with a
`LiftCore` entity (see "`ClientFoodEntry`, and why it is not `FoodEntry`").
"Clear ticks" clears the selected client's only.

`itemKey` is `ShoppingListLine.key`, stored exactly as `ShoppingList.build`
derived it. The normalisation (lowercase, trimmed) lives inline in that package
function with no public helper, so Coach never re-derives a key — a second copy
of the rule could only drift. `ShoppingListTests` pins the per-client rules.

Dropping `ShoppingListCheck` from the schema dropped whatever shared ticks an
older build had stored. That was checked, not assumed: a store written by main
with clients, meals and two ticks opened under the new schema with everything
but the ticks intact. Ticks are one week's shop, so losing them was accepted
over a migration. The schema list itself is `CoachSchema.models`, which
`CoachApp` and the tests both read, so the two cannot drift.

**`LiftReference.FoodRecord` has no public initializer.** Its stored
properties are `public`, but Swift's synthesized memberwise init is
`internal`, so `FoodRecord(id:name:...)` does not compile outside the
package. Tests build one by decoding JSON instead — see
`RecipeEditingTests.record(...)`. A public init belongs in a future kit
release; don't work around the gap with `@testable import` tricks that would
stop working the day the package adds one.

**Coach makes exactly two network calls, both in Cook's imports.** Neither
talks to a server DUGCANLIFT operates, and both have explicit offline and
failure states.

1. **TheMealDB** (`MealDBClient`), searched by dish name. An imported dish
   carries no nutrition of its own — servings stays at 1, because TheMealDB
   does not say how many a dish feeds and guessing four would divide every
   macro by a number nobody chose.
2. **A recipe page the coach pastes** (`RecipeLinkImportView`), read as
   schema.org JSON-LD by `LiftCore.RecipeJSONLD`. Servings come from the
   page's own yield when it states one and from a stepper when it does not,
   for the same reason TheMealDB's stays at 1.

Both send a `User-Agent` naming the app rather than impersonating a browser.
Several large recipe sites answer 403 regardless — measured, and they refuse a
browser string identically, so the block is not about the agent — and an
honest refusal the coach can read beats a disguise.

Cook has **four** import sources; the other two need no connection. The
catalogue (`RecipeCatalogView`) reads bundled data, and a pasted caption
(`RecipePasteImportView`) reads text the coach supplies. The network count is
the one to keep at two.

**A pasted caption is edited, not reviewed.** `RecipeLinkImportView` can review
because JSON-LD is labelled — the publisher already said which strings are
ingredients. A caption is prose, so `LiftCore.CaptionRecipe` only ever
*proposes* a split and `RecipePasteImportView` is an editor. That is what makes
the feature safe: a wrong split costs the coach an edit, never a number,
because `IngredientParser` still reads the quantities on save from the text
finally approved. Do not turn it into a review screen, and do not let the
parser infer past what the text states — its title rule (the first line or
none) and its yield rule (a line must open with a yield word and carry a
number) are both pinned, and both exist because the looser version silently
removed a real line or halved every macro in a dish.

The two boxes are deliberate. A per-line Ingredient/Step picker is a day of UI
to solve what cut-and-paste solves, and reparsing the boxes on save is the rule
`WebLibraryImporter` already follows: the raw text is the contract.

**Social video is out of reach and that is not a bug to fix.** TikTok, Instagram
and Reels publish no schema.org `Recipe`; YouTube publishes a `VideoObject`.
They also serve a JavaScript shell to a plain fetch and several 403 outright.
Pasting the caption is the supported path, not a workaround waiting on a better
scraper.

**Where an imported recipe's macros come from is a tested rule, not view
code.** `LinkImportMacros` decides it: a source's own figures win, and costing
only fills a gap, because a site publishing nutrition has measured a whole
dish while costing can only price what converts to a weight. Nothing costable
leaves the macros nil rather than zero — the same "blank stays blank" rule
`MacroFields` holds on the typed side. It lives in `Sources/Shared/` with no
view in it for the reason `MacroFields` does: a rule in a view's `@State`
cannot be tested, and this one decides whether a number reaches a client's day
total. `LinkImportMacrosTests` pins all four branches.

## Backups

`BackupCodec` is **v2** and carries the whole library. v1 carried only clients,
which meant every workout template written since Train shipped was absent from
every backup — silently, while Connect said a backup was the only way to move a
coach's work.

**Clients restore by replace; the library merges by id.** The inconsistency is
deliberate. Replace is what Coach has always done for the roster and its tests
pin it. The library follows the web app's rule instead — "an older backup must
never delete newer work sitting on this device" — and a v1 file, which has no
library at all, must leave the phone's library alone rather than emptying it.

`WebLibraryImporter` reads the **web Coach** backup, which is a different file:
the two apps store a client's days differently, so only the library halves line
up. Ingredient lines are **reparsed** on the way in rather than field-mapped —
the raw text is the contract, and reparsing is how both sides stay in agreement
about what a line means. Set weights in that file are **pounds**; a missing
conversion is silent and 2.2x wrong.

**`PlanLinkEncoder` omits an empty `r`/`m`/`w`/`k` rather than sending `[]`.**
PLAN-FORMAT says a training-only week carries no `r` or `m` key at all, and
`Tests/Fixtures/web-plan-meals.txt` — captured from the web app's own
encoder — has no `w` or `k` keys. That is not the same rule the web app
follows for `r`/`m`, though: `Tests/Fixtures/web-plan-link.txt` decodes to
`"r":[],"m":[]` — the web app's `encodePlan` always emits `r` and `m`, even
empty, and emits `w`/`k` only when there are workouts. Coach's own
omit-all-four-when-empty rule is Coach's own choice, permitted by
PLAN-FORMAT and safe because every decoder treats all four keys as
optional. `PlanLinkMealInteropTests` checks the fixture's raw JSON key order
(`{"v"` first, never `{"l"`) before decoding, specifically because `Codable`
discards key order and would otherwise let a Coach-regenerated fixture pass
as if it still proved interop.

Meal ownership travels in the backup too, as `BackupMeal.clientID`, and is
written back into `cookPlanOwners` on restore and on web import via the
shared `MealOwners` helper: `PlannedMeal` has no client field of its own (see
"A planned meal's client lives in `@AppStorage`, not on the model" above), so
a restored or imported meal with no entry in that map is stored in SwiftData
but permanently invisible to every screen that reads it.

## Outdoor

A client's runs, walks and hikes arrive in the share link (SHARE-FORMAT.md
"Outdoor", decoded by `LiftCore` 1.8.0): a day's `o` tuples, all-time bests
`ob`, and `lr`, the newest route — sent only when the client opted in. They are
stored as the wire's own JSON in optional `Data` properties
(`TrainingDay.outdoorData`, `Client.outdoorBestsData` / `lastRouteData`), read
through typed accessors. No new `@Model` types, so adding them was a
lightweight migration; it was checked by installing over a real store holding
an imported client, not assumed.

**`o` goes with its day.** Days are replaced whole, so a run deleted at home
disappears here too.

**`ob` and `lr` follow the newest send, and absent clears them.** A payload
whose `z` is at least `Client.exportedAtEpochSec` replaces both, including with
nothing: a client who turns route sharing off expects the route gone, not
frozen at the last one they sent. An older link changes neither, or pasting a
stale link late would bring an old route back. Name, unit, platform and goal
follow the same rule (an absent goal leaves the stored one alone), and days do
not: each link is the truth for the days it covers, whenever it arrives. `exportedAtEpochSec`
travels in backups, or a restore would let the next stale link win.
In a backup these are `outdoor`, `outdoorBests`, `lastRoute` and
`exportedAtEpochSec`, as **objects with named fields, not the wire's tuples** —
Coach Android's names and shapes exactly, so one file moves between the two
apps. `lastRoute.polyline` is the encoded string as received.

**The route is already trimmed by the sender.** Its first and last 200 m are
cut off by the client's app, so a client's front door never leaves their
phone. Coach draws exactly what arrives and never trims, extends or smooths it;
the card says so in words.

**Formatting is `OutdoorDisplay`**, a port of Coach web's `coach/route.js`:
miles for a client whose unit is `lb`, kilometres for `kg`; a pace only from
1 km up; a best that is null or zero shows "—", never a zero. Distances keep
`toFixed`'s rounding of the binary value (2795 m is "2.79 km"), which
`OutdoorShareTests` pins against the web app's own output.

**The map is MapKit, as LIFT iOS's Last route card draws it**: a non-interactive
`Map(initialPosition: .automatic, interactionModes: [])` with
`.allowsHitTesting(false)`, so scrolling the client screen scrolls it. Unlike
the web Coach, which draws on a canvas so no tile server learns where a client
runs, MapKit fetches Apple's map tiles for that area. That is the system
framework's request, not one Coach makes, so the two-network-call count in Cook
is unchanged — but it is a deliberate trade, and a reason not to add a second
map anywhere casually.

`Tests/Fixtures/outdoor-share-link.txt` and `outdoor-share-expected.json` were
written by LIFT web. Do not regenerate them from Swift.

## Saturated fat, sugar and sodium

Tracked and shown, **never targeted**: no goal, bar or colour anywhere
(SHARE-FORMAT.md, PLAN-FORMAT.md "Saturated fat, sugar and sodium", LiftKit
1.9.0).

**Storage follows the outdoor pattern.** A day's `fx` is
`TrainingDay.nutrientTotalsData`, the wire's own `WireNutrientTotals` as JSON,
stored exactly as sent and never re-derived from the foods. An itemised food's
`fe` is `ClientFoodEntry.nutrientDetailsData`, a `WireNutrientDetails` held
**as eaten** — multiplied by servings on import like the macros, though `fe` is
per serving. `fe` aligns with `f` by *position*, so the importer indexes it by
the `f` position, not by the foods it kept. Null stays null; all-unknown is
stored as nil. Days are replaced whole, so a link without `fx` clears it.

LiftKit 1.9.0 added `NutritionFacts.saturatedFatG`, a new column on `Recipe`
and two on `PlannedMeal`. Coach has no migration plan and needs none: installing
over a real store (2 clients, 56 days, 4 recipes, 20 planned meals, ticks,
routines) opened cleanly with every row and value identical and the new columns
nil. Checked, not assumed.

**A partial total is a floor, not a day.** `NutrientDisplay` (a port of Coach
Android's `NutrientDisplay.kt` and `Stats.nutrientAverages`) says "Sodium
1,840 mg · from 3 of 5 foods" when coverage is partial, and averages only over
days that recorded that nutrient, always saying how many. A nutrient nobody
recorded gets no line — not a zero, not a dash.

**The recipe editor has fields for all three**, following fibre's rules in
`MacroFields`, not the four macros': blank loads blank and untyped, costing
fills them only when the ingredients carried a figure (grams to one decimal,
sodium whole), a typed value wins, blank saves nil. `entered(merging:)` is gone
— with a field, a merge would bring back a value the coach just cleared. A form
holding only sodium saves zeros in the four macros, the only shape
`NutritionFacts` allows; `PlanLinkEncoder` and `CookView.macroLine` both read
that as "macros not set".

**`ux` is the kit's**: `ShareNutrients.itemRow(perServing:)` rounds and trims
trailing nulls, and nil omits the key. It can travel without `u`.

**Backup names are Coach Android's, exactly.** A day carries
`nutrientTotals: {saturatedFatG, sugarG, sodiumMg, foods, withSaturatedFat,
withSugar, withSodium}` — omitted when none, an unknown total an explicit
`null`. A food carries `saturatedFatG`/`sugarG`/`sodiumMg` as eaten, each
omitted when unknown. Recipes and planned meals get `saturatedFatG` for free,
because `NutritionFacts` is encoded directly. Files written before any of this
still restore. `WebLibraryImporter` reads the three from a web recipe's
`nutritionPerServing` leniently: a non-number is unknown, not a failed import.
