# Privacy Policy

**ComplexCommute**
Last updated: September 20, 2026

## Summary

ComplexCommute does not collect, transmit, or store any personal information. There is no
account to create, no analytics, no advertising, and no tracking. Everything the app knows
about you stays on your iPhone.

## What stays on your device

- **Your location.** Used to plan trips from where you are and to re-plan while you travel. It
  is read by the app on your device and never leaves it. The app does not record location
  history. While a trip is in progress, and only then, the app keeps reading your location with
  the screen locked so the trip on your Lock Screen and Apple Watch stays current; this stops
  when the trip ends. During a trip the app also asks iOS to watch the station you're heading
  for and the end of the leg you're on, so it notices you arriving or leaving even when closed.
  Those places are removed when the trip moves on or ends.
- **Your motion.** During a trip only, the app reads whether your iPhone's motion sensor thinks
  you're walking, driving or on a vehicle, to notice when you park and when your train pulls out.
  It is used on your device, never stored, and never leaves it.
- **Directions.** When you ask for turn-by-turn directions, the place you are heading to is handed
  to the maps app you chose, Apple Maps or Google Maps, which then works under its own privacy
  policy. Nothing else about your trip goes with it.
- **The trip in progress.** Kept on your iPhone so it can be picked back up if the app is
  closed and shown in a Live Activity, which iOS also shows on your own paired Apple Watch.
- **Your commutes and saved places.** Stored locally on your iPhone using Apple's SwiftData.
  They are not uploaded anywhere.
- **Agency API keys.** If you add a key to receive realtime arrivals, it is stored in the iOS
  Keychain on that device and is sent only to the agency it belongs to.
- **Transit schedules.** Agency GTFS feeds you choose to download are stored on your device and
  used for routing locally.

## What the app connects to

ComplexCommute makes network requests only to public transit agencies, and only to fetch
schedules, realtime arrivals, and service alerts:

- Metropolitan Transportation Authority (MTA)
- Washington Metropolitan Area Transit Authority (WMATA)
- NJ Transit
- Port Authority Trans-Hudson (PATH)
- Maryland Transit Administration (MARC)
- Virginia Railway Express (VRE)
- Massachusetts Bay Transportation Authority (MBTA)
- Metropolitan Atlanta Rapid Transit Authority (MARTA)

These requests ask for public timetable and service data. They do not include your identity,
your location, or your trip. Any API key you have entered is sent only to the agency that
issued it, as that agency requires.

Map rendering, place search, and driving and walking directions use Apple's MapKit and are
handled by Apple under
[Apple's privacy policy](https://www.apple.com/legal/privacy/).

## What we never do

- No data is sent to the developer. There is no server.
- No analytics, crash reporting, or advertising SDKs. The app has no third-party dependencies.
- No data is sold or shared with anyone.
- No tracking across apps or websites.

## Your control

Deleting the app removes everything it stored, including saved commutes, places, downloaded
schedules, and any API keys. You can revoke location access at any time in
Settings › Privacy & Security › Location Services; the app still plans trips, you just enter a
starting point by hand.

## Children

The app is not directed at children and collects nothing from anyone, including children.

## Changes

If this policy changes, the updated version will be posted here with a new date.

## Contact

Questions about this policy: open an issue at
<https://github.com/eggprez/ComplexCommute/issues>.
