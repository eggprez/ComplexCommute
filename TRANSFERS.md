# Out-of-station transfers

Places where two separate stations sit close enough that changing between them on the street is worth
offering, like WMATA's Farragut Crossing. Researched 2026-09-21 for NYC, DC, Boston and Atlanta, using agency
GTFS (platform coordinates) and agency fare pages.

## What the app does

- **Same place = within a five-minute walk** (`Timetable.samePlaceWalkSeconds`; the app's walk estimate is
  straight line × 1.3 at 1.3 m/s, so about 300 m platform to platform).
  - The router always links every platform of a station in the same place, whatever else is nearby.
  - A station picked as a waypoint also stands for its same-place neighbors. For example, "Farragut North"
    can start on the Blue Line at Farragut West, with the walk shown.
  - A station's departure board adds a section for each same-place neighbor ("Farragut West · 3 min walk"),
    showing only departures that can still be reached on foot.
  - The map shows a change between them as one transfer point.
- **Nearby = within 400 m** (`walkLinkRadiusMeters`): stops are linked by the nearest stop of each pattern
  (route and stop sequence) that the stop doesn't already serve.
  - This replaced "the 8 nearest stops". On the installed NYC feeds, that cap was dropping 177 of the 384
    rail-to-rail links within a five-minute walk, because bus stops were closer. The dropped links included
    Penn Station LIRR to 34 St–Penn, Grand Central Metro-North to the subway, and PATH 14 St to the subway.
  - The new rule also builds faster (0.28 s vs 0.72 s for all of NYC) and routes faster (30 ms vs 59 ms for
    nine queries), because it skips stops that only lead back onto lines already at hand.
- **In feed:** transfers the agency publishes in `transfers.txt` come first and keep the agency's time.
- Every street walk is costed as walk + the rider's buffer. Fares aren't modeled.
- **Free transfer labels:** the official free transfers below are listed in `FreeTransfer.all` (GTFSKit), keyed
  by feed and parent station ids. A trip that changes there says so: under the transfer on the timeline
  ("Farragut Crossing: free with SmarTrip within 30 min"), and as "free transfer" in the change instruction on
  the Lock Screen and the Watch.

## Official free out-of-system transfers

| City | Transfer | Rule | In the agency's GTFS? | In the app |
|---|---|---|---|---|
| DC | **Farragut Crossing**: Farragut North (Red) ↔ Farragut West (BL/OR/SV), 207 m | SmarTrip; re-enter within 30 min; charged as one trip. Contactless: unconfirmed | **No.** WMATA publishes no transfers.txt | Same place (3.4 min), labelled |
| NYC | Lexington Av/59 St ↔ Lexington Av/63 St | OMNY or pay-per-ride MetroCard, same card, within 2 h (uses the one free transfer) | Yes (180–300 s) | From the feed, labelled |
| NYC | Junius St (3) ↔ Livonia Av (L) | Same as above; permanent since 2020, overpass under construction | Yes (300 s) | From the feed, labelled |
| Boston | none | Fall 2026 pilot: unlimited transfers within 2 h, same payment method. Whether leaving one subway station and entering another counts is unconfirmed | n/a | n/a |
| Atlanta | none official | Tapping out loads a transfer, up to 4 in 3 h. Rail-to-rail by re-entry is likely free but unconfirmed; the Streetcar has no transfers | n/a | n/a |

WMATA's Farragut Crossing is the only official one missing from its agency's feed. The same-place rule now
covers it.

## Useful street changes (not free, but real)

Pairs within a five-minute walk that add lines the other station lacks and aren't in the feed. Listed with
the platform-to-platform gap. The full lists come from `Scripts/nearby-stations.py`.

**DC:**
- Metro ↔ MARC/VRE at Rockville (18 m), Franconia–Springfield (40 m), New Carrollton (43 m), College Park (47 m),
  L'Enfant (75 m), Silver Spring (118 m), King St ↔ Alexandria VRE (140 m), Greenbelt (167 m), Union Station
  MARC (182 m) and Crystal City (286 m, the longest).
- Union Station Metro ↔ VRE is 330 m (5.5 min): "nearby" rather than same place.
- Unofficial Metro-to-Metro pairs from the research, measured entrance to entrance:
  - Gallery Place ↔ Metro Center, 261 m. They share the Red Line, which connects them in-system.
  - Judiciary Sq ↔ Gallery Place, 359 m.
  - Federal Triangle ↔ Metro Center, 371 m.
  - McPherson Sq ↔ Farragut North, 402 m.

  Measured platform to platform, all of these are beyond 300 m, so the router offers them only where they
  fall within the 400 m radius.
- The Purple Line is not open (expected around the turn of 2028). The DC Streetcar ended on March 31, 2026.

**NYC:** there are dozens, and the busiest matter most:
- Penn Station: LIRR/NJT ↔ 1/2/3 and A/C/E.
- Grand Central: Metro-North and LIRR ↔ 4/5/6/7/S.
- Atlantic Terminal ↔ Barclays Ctr.
- Jamaica ↔ Sutphin Blvd.
- Woodside.
- Harlem–125 St.
- PATH at 33 St, 23 St, 14 St, 9 St and WTC ↔ the subway. As of Sept 1, 2026, PATH takes only its own TAPP
  card, so none of these is free.
- Newark Penn, Hoboken and Exchange Place ↔ light rail.
- Downtown Manhattan pairs: Wall St 2/3 ↔ 4/5, Rector St 1 ↔ R/W, Chambers St, Canal St, Fulton St ↔ Cortlandt.
- Broadway G ↔ Hewes/Lorimer J/M, 277–348 m. Free only temporarily, in 2014 and 2019–20.
- Queensboro Plaza ↔ Queens Plaza, 307 m: "nearby".

**Boston:**
- Boylston ↔ Chinatown (159 m).
- Government Center ↔ State (156 m).
- Aquarium ↔ Long Wharf and Central Wharf ferries (103–271 m).
- Cleveland Circle ↔ Reservoir (122 m).
- Blandford St ↔ Lansdowne (177 m).
- Symphony ↔ Mass Ave (208 m).
- Northeastern ↔ Ruggles (309 m, just over).
- Copley ↔ Back Bay (326 m: "nearby").
- Kenmore ↔ Lansdowne is about 5 min by Wikipedia's measure.
- Bowdoin ↔ Charles/MGH is 10–12 min, too far. The Red Blue Connector has not been built.

**Atlanta:** Five Points is the only line-to-line rail change, and it is inside fare control. The only
street changes are to the Streetcar: Peachtree Center (same stop), and Woodruff Park and Park Place near Five
Points and Peachtree Center (236–343 m). The Streetcar has separate fares.

## Adding a city

1. Add its feeds to `FeedCatalog`. Nothing about transfers is per-city: the same-place and nearby rules
   work from platform coordinates.
2. Run `Scripts/nearby-stations.py <feed zips…>` with all of the city's feeds together. Read the "same place"
   and "nearby" rows for anything surprising:
   - Platforms placed at the parent's centroid, which makes gaps look shorter or longer than they are.
   - A bus-only feed tagged with a rail route type.
3. Look up the agency's official out-of-system transfers (fare page, "transfers") and add each one to
   `FreeTransfer.all` with its rule. Check whether its transfers.txt has them too. One that is missing and
   farther than a five-minute walk would also need a walk link added by hand. None does today.
4. Add the city to the tables above.
