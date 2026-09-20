# ComplexCommute — Product & Technical Spec

Multi-modal commute planner for iOS: chain **drive → walk → transit → walk** legs into one trip,
with Apple Maps for maps/driving/walking and agency GTFS feeds for transit.

## Decisions (from kickoff Q&A, 2026-09-19)

| Area | Decision |
|---|---|
| Trip model | **Hybrid** — user pins waypoints + modes; app picks actual trains/transfers and times the chain |
| Usage | Saved recurring commutes **and** ad-hoc planning, both first-class |
| NYC systems | MTA Subway, MTA Bus, LIRR, Metro-North, NJ Transit (rail + bus), PATH |
| DC systems | WMATA Metrorail, WMATA Metrobus, MARC, VRE |
| Architecture | **All on-device** — GTFS static in local SQLite, on-device routing, direct realtime polling. No backend |
| API keys | **User-supplied**, per agency, in Settings; stored in Keychain; agency is schedule-only/disabled until key added |
| Platform | iPhone only, **iOS 26+**, SwiftUI, current system design language (Liquid Glass, standard components) |
| Leg types | Drive, Walk, Transit only |
| Drive leg | Plain traffic-aware ETA A→B (no parking buffer concept); hand off to Apple Maps for turn-by-turn |
| Alternatives | Always show several itineraries (fastest / fewest transfers / least walking); user picks |
| Live behavior | **Live re-plan from current location** — options recompute continuously (~30 s) from GPS + realtime while app is open |
| On-the-go editing | Quick waypoint edits from the trip screen (swap station, add/drop waypoint, change leg mode) → instant recompute |
| Home screen | Full-screen map + resizable bottom sheet (Apple Maps style) |
| Storage | SwiftData + CloudKit sync for commutes/places; API keys in Keychain (not synced via CloudKit) |
| Project | XcodeGen (`project.yml`) + local Swift package for logic, unit-tested from CLI |
| v1 extras | Service alerts in v1. Leave-by notifications, Live Activity/widgets, Watch app: designed for, built later |

## Key platform constraint

`MKDirections` returns full routes for **driving and walking** only. For transit it returns an ETA
only — no steps. So: MapKit handles map rendering, search/geocoding, drive + walk legs, and Apple
Maps handoff; **transit legs are computed on-device from agency GTFS + GTFS-realtime**.

## Core concepts

- **Place** — named coordinate (Home, Apartment, Office) or a transit **Stop**.
- **Trip template** — ordered **waypoints** with a **mode** between each pair
  (`drive`, `walk`, `transit`). A saved template is a **Commute**.
- **Itinerary** — a resolved trip: concrete legs with times. Transit segments expand into one or
  more rides + transfers. Several itineraries are produced per template.
- **Active trip** — the itinerary being followed; re-planned from the user's live position.

### Timing a chain

Legs resolve left-to-right from the departure time (or right-to-left for "arrive by"):
drive/walk durations from MapKit (drive uses live traffic), transit segments from the router
starting at the moment the previous leg ends. Realtime trip updates overlay scheduled times.

## Architecture

```
ComplexCommute/            SwiftUI app (views, SwiftData models, MapKit, location)
Packages/CommuteKit/
  CommuteCore              Pure models: modes, waypoints, legs, itineraries, chain timing
  GTFSKit                  Feed catalog, streaming zip/CSV → one SQLite file per feed, stop search;
                           GTFS-realtime decoding later (phase 4). No third-party dependencies.
  TransitRouting           RAPTOR router over the local timetable, multi-criteria   (phase 3)
```

- Feed storage: `Application Support/Feeds/<feed-id>.sqlite`, excluded from backup. String ids are mapped
  to dense integer indexes at import; imports build a temp file and swap it in atomically.
  The subway (565k stop_times) imports in seconds to ~15 MB.

- Routing: **RAPTOR** (round-based; naturally yields fewest-transfer vs. earliest-arrival
  Pareto options), footpath transfers from `transfers.txt` + proximity.
- Realtime: GTFS-RT TripUpdates/Alerts where available; WMATA + MTA Bus Time JSON APIs otherwise.
- Feeds are downloaded per region on demand (user enables NYC and/or DC), refreshed periodically.

## Agency feed notes

| Agency | Static | Realtime | Key |
|---|---|---|---|
| MTA Subway | GTFS | GTFS-RT (NYCT extensions) | none |
| MTA Bus | GTFS (per borough) | Bus Time SIRI / GTFS-RT | MTA Bus Time key |
| LIRR / Metro-North | GTFS | GTFS-RT | none |
| NJ Transit | GTFS (public zip) | GTFS-RT | NJT developer credentials (realtime only) |
| PATH | GTFS | unofficial/bridged feed | none |
| WMATA Rail + Bus | GTFS (needs key, `api_key` header) | GTFS-RT + predictions JSON | WMATA key |
| MARC | GTFS (MTA Maryland) | GTFS-RT | none |
| VRE | GTFS | limited | none |

Static URLs verified 2026-09-19 and live in `FeedCatalog.swift`. Realtime details get verified in phase 4.

## Phases

1. ✅ **Shell** — project, map + bottom sheet, places, commute templates (SwiftData), trip editor,
   drive/walk legs via MapKit drawn on the map, chain timing, Apple Maps handoff.
2. ✅ **GTFS static** — feed catalog, download/unzip/import to SQLite, stop search, stops as waypoints,
   Transit Data settings with per-feed install and WMATA key entry (Keychain).
3. **Transit routing** — RAPTOR, multiple alternatives, full chained itineraries.
4. **Realtime + keys** — Settings key entry (Keychain), realtime overlays, service alerts.
5. **Active trip** — live re-plan from GPS, quick waypoint edits on the go.
6. **Later** — leave-by notifications, Live Activity + widgets, Apple Watch.

## Design guidelines

Standard iOS components and behaviors throughout: system materials/Liquid Glass (no custom chrome),
SF Symbols, Dynamic Type, Dark Mode, `List`/`Form` for settings and editors, sheets with detents,
system transit-style line badges using agency route colors from GTFS, VoiceOver labels on all legs.
