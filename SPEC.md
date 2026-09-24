# ComplexCommute — Product & Technical Spec

Multi-modal commute planner for iOS: chain **drive → walk → transit → walk** legs into one trip,
with Apple Maps for maps/driving/walking and agency GTFS feeds for transit.

## Decisions (from kickoff Q&A, 2026-09-19)

| Area | Decision |
|---|---|
| Trip model | **Hybrid** — user pins waypoints + modes; app picks actual trains/transfers and times the chain |
| Usage | Saved recurring commutes **and** ad-hoc planning, both first-class. Commutes **save themselves** as they are built and edited; one-off trips save on request |
| NYC systems | MTA Subway, MTA Bus, LIRR, Metro-North, NJ Transit (rail + bus), PATH |
| DC systems | WMATA Metrorail, WMATA Metrobus, MARC, VRE |
| Boston systems | MBTA (subway, bus, Commuter Rail, ferry) — one feed, realtime without a key (added 2026-09-21) |
| Atlanta systems | MARTA (rail, bus, Atlanta Streetcar) — one feed; realtime covers buses only (added 2026-09-21) |
| Architecture | **All on-device** — GTFS static in local SQLite, on-device routing, direct realtime polling. No backend |
| API keys | **User-supplied**, per agency, in Settings; stored in Keychain; agency is schedule-only/disabled until key added |
| Platform | iPhone only, **iOS 26+**, SwiftUI, current system design language (Liquid Glass, standard components) |
| Leg types | Drive, Walk, Transit only |
| Drive leg | Plain traffic-aware ETA A→B; turn-by-turn **in the app** (no Apple Maps handoff, decided 2026-09-20), laid out like Apple Maps: dark maneuver sign on top, arrival / min / mi bar with End at the bottom |
| Station buffer | **3 min by default, 0–15 in Settings.** Time in hand on reaching a station (from a drive, a walk or another vehicle) and at every change of vehicles; dropped for the first boarding once the rider is already waiting at the station |
| Learned buffer | The app times every connection it can watch and reports the average time really in hand plus an 80th-percentile **safe buffer**, grouped by station and how the platform is reached. Suggested with one tap to apply; never applied behind the rider's back (decided 2026-09-20) |
| Arrive by | Set per trip or saved with a commute (asked once, when the commute is created). Answers with **one time to leave**, alternatives folded away. A colour-banded **Arrive By** bar tracks the trip against it: light green >5 min early, green within 5 min, orange 5–10 late, red beyond (decided 2026-09-20) |
| Look | Line diagrams, not text: itineraries are a vertical line (dotted walk, blue drive, route-colored ride) with stations as dots on it; rides on the map follow the agency's published shapes; departure boards show the next 3 per line + destination |
| Alternatives | Always show several itineraries (fastest / fewest transfers / least walking); user picks |
| Live behavior | **Live re-plan from current location** — options recompute continuously (~30 s) from GPS + realtime while app is open |
| On-the-go editing | Quick waypoint edits from the trip screen (swap station, add/drop waypoint, change leg mode) → instant recompute |
| Home screen | Full-screen map + resizable bottom sheet (Apple Maps style) |
| Storage | SwiftData + CloudKit sync for commutes/places; API keys in Keychain (not synced via CloudKit) |
| Project | XcodeGen (`project.yml`) + local Swift package for logic, unit-tested from CLI |
| v1 extras | Service alerts, leave-by notifications and a Live Activity in v1; on Apple Watch, the Live Activity in the Smart Stack rather than a Watch app (decided 2026-09-21). Home Screen widgets: later |
| Outside the app | Leg-level instructions only on the Lock Screen and the Watch (no turn-by-turn); a trip with no arrive-by shows its arrival time where the bar would be; kept current by background location, not push (decided 2026-09-20) |

## Key platform constraint

`MKDirections` returns full routes for **driving and walking** only. For transit it returns an ETA
only — no steps. So: MapKit handles map rendering, search/geocoding and drive + walk legs (route, steps,
traffic ETA); **transit legs are computed on-device from agency GTFS + GTFS-realtime**. MapKit has no
navigation mode either, so guidance is built from `MKRoute.steps` (each step's polyline leads *up to* its maneuver).

## Core concepts

- **Place** — named coordinate (Home, Apartment, Office) or a transit **Stop**.
- **Trip template** — ordered **waypoints** with a **mode** between each pair
  (`drive`, `walk`, `transit`). A saved template is a **Commute**.
- **Itinerary** — a resolved trip: concrete legs with times. Transit segments expand into one or
  more rides + transfers. Several itineraries are produced per template.
- **Active trip** — the itinerary being followed; re-planned from the user's live position.

### Timing a chain

Legs resolve left-to-right from the departure time: drive/walk durations from MapKit (drive uses live
traffic), transit segments from the router starting at the moment the previous leg ends. Realtime trip
updates overlay scheduled times.

"Arrive by" keeps that same forward router and hunts for the departure instead of reversing the search.
Each pass leaves as late as the last pass's spare time allows, or steps back by what it overshot —
bisecting towards the last departure known to work when stepping back isn't reaching an earlier
vehicle — which closes on the last vehicle that makes it within two or three passes.

## Architecture

```
ComplexCommute/            SwiftUI app (views, SwiftData models, MapKit, location)
Packages/CommuteKit/
  CommuteCore              Pure models: modes, waypoints, legs, itineraries, chain timing
  GTFSKit                  Feed catalog, streaming zip/CSV → one SQLite file per feed, stop search;
                           GTFS-realtime decoding later (phase 4). No third-party dependencies.
  TransitRouting           Timetable (RAPTOR layout), RaptorRouter, TransitPlanner actor → [LegOption]
```

- Feed storage: `Application Support/Feeds/<feed-id>.sqlite`, excluded from backup. String ids are mapped
  to dense integer indexes at import; imports build a temp file and swap it in atomically.
  The subway (565k stop_times) imports in seconds to ~15 MB.

- Routing: **RAPTOR** (round-based; naturally yields fewest-transfer vs. earliest-arrival
  Pareto options), footpath transfers from `transfers.txt` + proximity. On real data (subway + PATH)
  the day's timetable builds in ~0.4 s once per service day and a query takes ~10 ms.
- **Same place** (2026-09-21): stations within a five-minute walk count as one place. They are always linked on
  foot, a station waypoint takes in its neighbors, and departure boards list theirs too (Farragut North ↔ Farragut West).
  Proximity links keep the nearest stop of each pattern within 400 m rather than the 8 nearest stops, which let bus
  stops crowd out stations. Out-of-station transfers per city, and the check to run when adding a city, are in
  [TRANSFERS.md](TRANSFERS.md) (`Scripts/nearby-stations.py`).
- Known data issue: PATH's official feed calendar ended 2026-06-01; feeds past their calendar reuse the
  same weekday of their final published week and are flagged in Transit Data.
- Realtime: GTFS-RT TripUpdates/Alerts where available; WMATA + MTA Bus Time JSON APIs otherwise.
- Feeds are downloaded per region on demand (user enables NYC, DC, Boston and/or Atlanta), refreshed periodically.

## Agency feed notes

| Agency | Static | Realtime | Key |
|---|---|---|---|
| MTA Subway | GTFS **supplemented** (planned work for 7 days; refreshed daily on Wi-Fi) | GTFS-RT, matched by origin time + route + direction (~88%) | none |
| MTA Bus | GTFS (per borough) | GTFS-RT, one citywide 1.5 MB feed | none (open as of 2026-09) |
| LIRR / Metro-North | GTFS | GTFS-RT | none |
| NJ Transit | GTFS (public zip) | GTFS-RT | NJT developer credentials (realtime only) |
| PATH | GTFS | unofficial/bridged feed | none |
| WMATA Rail + Bus | GTFS (needs key, `api_key` header) | GTFS-RT + predictions JSON | WMATA key |
| MARC | GTFS (MTA Maryland) | GTFS-RT | none |
| VRE | GTFS | limited | none |
| AirTrain JFK | GTFS from 511NY (not the Port Authority) | none | none |
| Airport links | **Built in** (`BuiltInFeeds`): AirTrain Newark, Massport Logan shuttles 22/33/55/88, BWI rail station shuttle, ATL SkyTrain — headway-based, generated on the phone | none | none |

Static URLs verified 2026-09-19 and live in `FeedCatalog.swift`. Realtime details get verified in phase 4.

## Phases

1. ✅ **Shell** — project, map + bottom sheet, places, commute templates (SwiftData), trip editor,
   drive/walk legs via MapKit drawn on the map, chain timing, Apple Maps handoff.
2. ✅ **GTFS static** — feed catalog, download/unzip/import to SQLite, stop search, stops as waypoints,
   Transit Data settings with per-feed install and WMATA key entry (Keychain).
3. ✅ **Transit routing** — RAPTOR over per-day in-memory timetables (patterns, non-overtaking lanes, published +
   same-station + proximity footpaths, so agencies interconnect), latest-departure pass, successive-departure
   alternatives with pointless-option filtering, expired-calendar fallback, rides drawn in route colors.
   Falls back to MapKit's transit ETA where no installed feed connects the waypoints.
4. ✅ **Realtime** — dependency-free GTFS-realtime decoder; `RealtimeService` fetches per-feed sources (shared URLs
   fetched once, 30–60 s freshness, stale data dropped after 5 min, failures fall back to the schedule);
   predictions are folded into the timetable so the router catches late trains and re-checks connections;
   alerts attach to the rides they affect. Live for MTA subway/bus/LIRR/Metro-North (no key) and WMATA (key).
   Not yet: NJ Transit (token API), PATH (unofficial feed, trip ids don't match), MARC (endpoint unverified).
5. ✅ **Active trip** — `ActiveTrip` (CommuteCore) tracks the current leg from GPS proximity, the clock (a train's
   departure passing means aboard, since GPS dies underground) and rider corrections ("I'm at…", "I missed this
   train"). Every 20 s and on arrival at a waypoint it re-plans what's left: drive/walk legs from the actual
   position (without sliding the departure once moving), transit from the station while waiting, and only the
   legs after a ride once aboard. The followed trains are kept while still catchable; a broken plan is replaced
   with a notice, and an alternative is offered only if it saves 5+ minutes. Edit Trip reopens the remaining
   trip in the editor. The screen stays awake while a trip is active.
6. ✅ **See it, search it, ride it, drive it** —
   - Commutes autosave: "New Commute" is stored once it has two stops, auto-named from its endpoints (a name the
     rider chose is kept), and every edit is written through.
   - The map shows what a transit leg will do: route badges where each line is boarded, `A → B` badges at transfers,
     rings at exits and dots at the stops passed; all tappable. A leg without an installed schedule says so and links
     to Transit Data instead of being an unexplained dashed line.
   - Search like Maps: `MKLocalSearchCompleter` suggestions with highlighted matches beside instant station results,
     category suggestions and submitted searches list rich results (category, distance, address), recents, and Apple's
     transit POIs resolve to the matching station of an installed feed.
   - Departure boards: `Timetable.departures` lists what leaves a station next (live where predicted), filterable by
     line, opened from any station in an itinerary (boarding, exit, the expandable stops between), a stop waypoint,
     the active trip, or the map.
   - In-app navigation: `RouteStep` + stateless `RouteProgress` (CommuteCore) place the traveller on the leg's steps;
     a banner over a heading-up camera shows the next maneuver, `VoiceGuide` speaks it (mutable), straying 50 m
     re-routes at once, and step lists replace the Open in Maps buttons.
   Not yet: walking directions for the walks *inside* a transit leg (to/from/between stations) — pin the station as a
   waypoint with a Walk leg to get them; guidance with the screen locked (needs background location + audio).
7. ✅ **Make it look like what it is** (2026-09-20, after first rides with it) —
   - Real geometry: `shapes.txt` is imported (schema 2: one packed Float32 blob per shape, Douglas–Peucker'd to 4 m, `trips.shape_idx`);
     `TransitPlanner` fetches a ride's shape on demand and `clipped(passing:)` cuts it to the stops ridden, following them in
     order so loops are cut at the right pass. No shape, or one that misses the stops, falls back to stop-to-stop lines.
     Schema-1 files stay usable and re-import themselves on Wi-Fi.
   - Station buffer: `RaptorRouter.changeSeconds` is the rider's buffer. Same platform → the buffer; an in-station transfer →
     max(agency minimum, buffer); a street walk to another station → walk + buffer; reaching the first station → walk + buffer
     (shown as "Wait", not as walking). `LegResolving` carries `isWaitingAtOrigin` so a rider already on the platform
     isn't told the train in front of them is uncatchable.
   - `TripTimeline`: the expanded option and the active trip's remainder are one line diagram; `SegmentStrip` summarizes a
     trip as chips; route badges are bullets (disc for 1–2 characters, lozenge otherwise) in three sizes.
   - `DepartureGroup`: boards list one row per line + destination with its next three countdowns.
   - Navigation like Maps: maneuver sign, "Then" strip, mute button, gently pitched heading-up camera with traffic, and a summary
     bar (arrival, minutes, miles, End) that is all the collapsed sheet shows. While driving it names the train being driven
     to and the sheet says how many minutes there are to spare for it.
   Known limit: MapKit draws 3D buildings over route lines when pitched and gives apps no lane guidance or speed limits.
8. ✅ **Be there by, and learn what it really takes** (2026-09-20) —
   - Arrive by: `ChainPlanner.plan(_:arrivingBy:)` searches for the latest departure that still arrives in
     time; the editor answers with one **Leave at** card and folds the rest into *Other Departures*.
     A commute is asked once, when it is created, whether it has a standing arrival time (stored as a
     `TimeOfDay`, applied to today or tomorrow), which can also be set or dropped from the trip editor.
   - Arrive By bar: `ArriveByProgress` (CommuteCore) bands the projected arrival — light green more than
     5 min early, green within 5 min either side, orange 5–10 min late, red beyond — above the trip's
     summary bar, tappable to change or remove the target, and settling on the real arrival once done.
     No target, no bar; one can be set mid-trip from the trip's controls.
   - Learned buffers: `ActiveTrip` records a `ConnectionRecord` for every connection it can time — reaching
     a station by road or on foot (the leg boundary), turning up on the platform for a trip that starts with
     a ride (GPS within 200 m), and, where realtime says what became of them, changes of vehicle inside a
     leg. Each holds what the plan promised and what the day delivered, so `BufferLearning` can report the
     average time really in hand and the 80th-percentile buffer that would have covered them, by station and
     approach, pooled for the overall suggestion. Stored in SwiftData (`ConnectionLog`, CloudKit-safe),
     reviewable and deletable per connection under *Buffers*, and applied only when the rider taps Use.
     "I missed this train" corrects that platform's record rather than counting it twice.
   - Notifications: `TripNotifier` raises a local notification for a plan that saves 5+ minutes (once per
     alternative) and a "time to leave" reminder for an arrive-by trip, asked for the first time the rider
     taps Go. A `BGAppRefreshTask` keeps a trip in progress, or the commute nearest its standing arrival
     time, re-planned while the app is away.
   Known limits: an in-progress ride's times freeze once aboard (re-planning only covers what is after it),
   so a change of vehicle learns from delays known before boarding; background refresh runs when iOS grants
   it, and cannot plan from `.currentLocation` without a recent fix.

9. ✅ **The trip, wherever the app isn't** (2026-09-20) —
   - `TripGlance` (CommuteCore): the Arrive By standing plus one leg-level `TripInstruction` — leave, drive/walk to,
     board, change (with the walk across), exit (stops left, what follows), arrived — each with the deadline it counts
     down to. Pure and unit-tested; it is the Live Activity's content state.
   - Live Activity (`ComplexCommuteWidgets`): the Arrive By bar and the next instruction on the Lock Screen, in the
     Dynamic Island (line bullet or mode symbol · minutes early/late), and, through `.supplementalActivityFamilies([.small])`,
     in the Watch's Smart Stack. Countdowns are timer text so they tick between updates; five minutes without a word
     from the app and the activity dims and says so. `TripActivityController` feeds it newest-wins, re-says an unchanged
     glance every two minutes to stay fresh, and leaves the verdict up for ten minutes after arriving.
   - Following a trip no longer depends on a view: `TripPlannerModel` owns the follow loop and takes fixes straight from
     `LocationService`, which holds a `CLBackgroundActivitySession` (background mode `location`, still When In Use)
     for as long as the trip lasts. `AppServices.tripDidChange` is the one place a change fans out to the Live Activity,
     the disk.
   - Survives being closed: `ActiveTrip` is Codable and `ActiveTripStore` rewrites it whenever what it shows changes.
     Launch picks it back up (unless finished or 30 min past its arrival), re-adopts the Live Activity still on the
     Lock Screen, and opens straight onto the trip.
   - Apple Watch: no Watch app (removed 2026-09-21). iOS mirrors the Live Activity into the Smart Stack, and the
     `.small` family draws `WristActivityView`.
   - The Arrive By bar leads every presentation (decided 2026-09-21): first and largest on the Lock Screen, the Watch
     and the expanded Dynamic Island, a miniature bar in the compact leading slot beside minutes early/late. The next
     instruction, its countdown and the departures from a change sit under it. Without an arrive-by, the expected
     arrival takes the bar's place. The Watch has room for the bar and one line under it, so no departures there.
   - `Shared/` holds the SwiftUI that has to look the same in the app and the widget extension (the bar's track, bullets, mode styling).
   Known limits: iOS only lets a Live Activity and background location *begin* with the app in front.

10. ✅ **Leave the turns to the maps apps** (2026-09-20) —
   - In-app navigation is gone (the maneuver banner, `VoiceGuide`, step lists, the heading-up camera, `RouteStep`/`RouteProgress`,
     off-route re-routing). A drive, a walk, or the walk to a platform is handed to Apple Maps or Google Maps
     (`DirectionsApp`, a universal link for Google; tap = the app used last, hold = the other; also under Transit Data ›
     Directions In). The trip carries on being followed from the background, the Live Activity and the Watch; the 20-second
     re-plan measures what's left from wherever the rider really is.
   - Arrive By bar, redrawn: ±30 min (`ArriveByProgress.scale`), painted with its bands (`span(of:)`), a dotted line on the
     target, "−30 min"/"+30 min" at the ends, and a ball that takes the colour of the band it is in. In the app it is a card
     of its own at the head of the trip. The same track, without end labels, on the Dynamic Island and the Watch.
   - `RaptorRouter.stayingAboard`: where two lines share stops before parting, a change onto the train *behind* the one
     boarded is folded into waiting for that train where the rider got on. (RAPTOR's fewer-rides tie-break already avoids this
     in the cases tested; the fold guarantees it.)

11. ✅ **Changes and airports** (2026-09-21) —
   - Next departures at a change: within `ActiveTrip.changeLookahead` (5 min) of boarding — getting off for another
     vehicle, reaching a station by road or on foot, a street crossing like Farragut North → West (inside a transit leg or
     as its own walk leg), or waiting on the platform — `upcomingChange` names the station and where the next vehicle is
     ridden to. `AppServices` looks up `TransitPlanner.departures(from:toward:)` (every line that stops there, not just the
     planned one; reusing the trip's timetable) every 30 s, and `TripGlance.connections` carries the next three still
     catchable (after the walk across) to the Lock Screen, Dynamic Island and Watch: planned one bold, live times green.
   - Airports: DCA/IAD (Metrorail), MARTA Airport, SL1 and LGA's Q70/M60 were already in agency feeds. AirTrain JFK is
     downloaded from 511NY. Links with no published schedule are `BuiltInFeeds`: written out as GTFS on the phone,
     installed with their city, rebuilt when `BuiltInFeeds.version` changes, stops placed on the stations they meet so
     walking links join them to the rest. Loops are laid out as station→terminals and terminals→station halves.
   Known limits: built-in times are estimates on headways; AirTrain Newark's 2026 weekday bus replacement (5 AM–3 PM,
   through mid-Nov) and Terminal A's shuttle from the P2 station aren't modelled.

12. **Later** — Home Screen widgets.

## Design guidelines

Standard iOS components and behaviors throughout: system materials/Liquid Glass (no custom chrome),
SF Symbols, Dynamic Type, Dark Mode, `List`/`Form` for settings and editors, sheets with detents,
system transit-style line badges using agency route colors from GTFS, VoiceOver labels on all legs.
