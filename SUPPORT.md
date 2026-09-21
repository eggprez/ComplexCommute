# ComplexCommute Support

ComplexCommute chains drive, walk, and transit legs into a single planned trip, and times each
leg so it starts when the previous one ends.

## Getting started

1. **Download the agencies you use.** Tap the transit icon on the home sheet and download the
   feeds you need. Schedules are stored on your device, so routing works without a connection.
2. **Plan a trip.** Tap *Where to?* and pick a place or a station. Add stops to build a longer
   chain, and set the mode between each pair of stops.
3. **Tap Go.** Options re-plan from your location as you go. Drive and walk legs are
   guided turn by turn in the app, with spoken directions you can mute from the banner.
4. **Check a station.** Tap any station in a trip, or on the map, to see what leaves there next.
   With the phone locked, the trip stays on your Lock Screen and in the Dynamic Island: how you
   are doing against your arrival time, and the next thing to do. Closing the app doesn't end a
   trip; open it again and it carries on.
5. **Say when you have to be there.** Choose *Arrive By* and the app answers with the latest time you
   can leave. Save the time with a commute and it is used every time you open it.

## Common questions

**How do I use it on Apple Watch?**
Open Commute on the Watch to see the trip under way on your iPhone, tell it you've arrived or
missed a train, or start a saved commute. During a trip the arrival bar also appears in the
Smart Stack. If you start a commute from the Watch while Commute is closed on your iPhone, open
it there once: iOS only lets the app keep a trip live once it has been opened.

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
PATH. Washington: WMATA Metrorail and Metrobus, MARC, VRE.

**Why is the first download large?**
Agency feeds contain every scheduled trip. They are imported once into a compact on-device
database, and you only download the agencies you select.

**Does my data leave my phone?**
No. See the [privacy policy](PRIVACY.md).

## Requirements

iPhone running iOS 26 or later.

## Contact

Report a bug or ask a question:
<https://github.com/eggprez/ComplexCommute/issues>
