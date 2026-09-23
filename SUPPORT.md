# ComplexCommute Support

ComplexCommute chains drive, walk, and transit legs into a single planned trip, and times each
leg so it starts when the previous one ends.

## Getting started

1. **Download the agencies you use.** Tap the transit icon on the home sheet and download the
   feeds you need. Schedules are stored on your device, so routing works without a connection.
2. **Plan a trip.** Tap *Where to?* and pick a place or a station. Add stops to build a longer
   chain, and set the mode between each pair of stops.
3. **Tap Go.** Options re-plan from your location as you go. For a drive or a walk, tap
   *Directions in Maps* to be guided by Apple Maps (hold it to choose Google Maps instead);
   Commute keeps following your trip while you are in the other app.
   With the phone locked, the trip stays on your Lock Screen and in the Dynamic Island: how you
   are doing against your arrival time, and the next thing to do. Closing the app doesn't end a
   trip; open it again and it carries on.
5. **Say when you have to be there.** Choose *Arrive By* and the app answers with the latest time you
   can leave. Save the time with a commute and it is used every time you open it.

## Common questions

**How do I use it on Apple Watch?**
There is nothing to install. While a trip is under way, it appears in your Watch's Smart Stack:
the next thing to do, a countdown to it, and how many minutes early or late you are running.
Tap it to open Commute on your iPhone.

**Why does a transit leg say "estimate"?**
You have not downloaded that agency's schedule yet. Without it, the app falls back to a rough
travel-time estimate. Download the feed and the leg expands into real departures, transfers,
and stops.

**Why does the app skip a train I could have caught?**
Trips are planned with a buffer: by default, three minutes in hand when you reach a station and
every time you change trains or buses. Change it, or turn it off, under *Station Buffer* in
Transit Data. Once you are waiting at a station, the next departure counts again.

**What is a learned buffer?**
Every time you travel with Go, the app times your connections: how long there really was between
you reaching a platform and your train leaving. Under *Station Buffer* you will find the average
time you get at each station, and a **safe buffer** — the buffer that would have covered four out
of five of your connections. It is only ever a suggestion; tap *Use* to adopt it. You can delete
any connection that went nothing like the others, or forget the lot.

**What do the colours on the Arrive By bar mean?**
Green means you are within five minutes of the time you set, lighter green that you are more than
five minutes early, orange that you are five to ten minutes late, and red more than ten. Tap the
bar to change the time or remove it.

**When does the app notify me?**
Only about the trip in hand: when it is time to leave for a trip you set an arrival time for, and
when a plan turns up that would save you more than five minutes. It asks the first time you tap Go.

**Why is a line drawn straight from stop to stop?**
That agency does not publish the path its vehicles follow, or the schedule on your phone predates
this feature. Installed schedules update themselves on Wi-Fi; you can also choose *Update Now*.

**Why do I need an API key?**
Schedules work without one. Realtime arrivals and service alerts require a free key from the
agency, which you add in Settings. Each agency issues its own.

**Which agencies are supported?**
New York: MTA Subway and buses, Long Island Rail Road, Metro-North, NJ Transit rail and bus,
PATH. Washington: WMATA Metrorail and Metrobus, MARC, VRE. Boston: MBTA subway, bus,
Commuter Rail and ferry. Atlanta: MARTA rail, bus and the Atlanta Streetcar.

**Why is the first download large?**
Agency feeds contain every scheduled trip. They are imported once into a compact on-device
database, and you only download the agencies you select.

**Does my data leave my phone?**
No. See the [privacy policy](PRIVACY.md).

## Data sources

Schedules, real-time predictions and service alerts come from public data published by the
transit agencies below. It may not be real time, and may be inaccurate, incomplete or delayed.
It is provided as is, without warranty. ComplexCommute is independent and is not affiliated
with, endorsed by or licensed by any transit agency. The same credits are in the app under
*Transit Data → Data Sources*.

- **MTA** — Subway, buses, LIRR and Metro-North. Not endorsed by the MTA.
  [Terms](https://www.mta.info/developers/terms-and-conditions)
- **Port Authority of New York and New Jersey** — PATH. Not endorsed by the Port Authority.
- **NJ TRANSIT** — used under the [NJ TRANSIT Developer Terms](https://developer.njtransit.com/terms/).
  Not endorsed by NJ TRANSIT.
- **WMATA** — Metrorail and Metrobus, provided as is. Not endorsed by WMATA.
  [License](https://developer.wmata.com/license)
- **Maryland Transit Administration (MDOT MTA)** — MARC. MDOT MTA does not guarantee the
  accuracy of its data or endorse this app.
- **Virginia Railway Express** — provided as is. Not endorsed by VRE.
- **MBTA** — MBTA data provided by the Massachusetts Department of Transportation (MassDOT).
  [Developers](https://www.mbta.com/developers)
- **MARTA** — Rail, bus and Atlanta Streetcar. Not endorsed by MARTA.
- **511NY (New York State DOT)** — AirTrain JFK, provided as is. Not endorsed by NYSDOT or the Port Authority.
- **Airport links compiled by ComplexCommute** — AirTrain Newark, Massport's Logan shuttles, the BWI
  rail station shuttle and the ATL SkyTrain publish no schedules; their times are estimates.

Maps, place search and driving and walking directions are provided by Apple Maps.

## Requirements

iPhone running iOS 26 or later.

## Contact

Report a bug or ask a question:
<https://github.com/eggprez/ComplexCommute/issues>
