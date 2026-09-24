#!/usr/bin/env python3
"""Lists separate stations close enough to change between on foot, for checking a city before (or after) adding it.

    Scripts/nearby-stations.py wmata-rail.zip marc.zip vre.zip [--meters 450]

Takes GTFS zips or unzipped folders (one city's feeds together, so links across agencies show up). Stations are
grouped by parent_station, only rail, ferry and other non-bus stops count, and the distance is the shortest
between any two of their platforms, which is what the app's router measures. Pairs where one station already
serves every line of the other are skipped: there is nothing to change onto.

Each pair is marked:
  same place   within a five-minute walk (Timetable.samePlaceWalkSeconds): always linked, and picking either
               station as a waypoint or opening its departure board takes in the other
  nearby       within the router's walk radius (Timetable.walkLinkRadiusMeters): linked as a street walk
  in feed      the agency's transfers.txt links them already, with its own time
The walk estimate is the app's: straight line x 1.3 for streets, at 1.3 m/s.
"""
import argparse, csv, io, math, os, zipfile
from collections import defaultdict

BUS = {3, 11} | set(range(700, 800))
SAME_PLACE_SECONDS = 300
WALK_RADIUS_METERS = 400


def meters(a, b):
    (la1, lo1), (la2, lo2) = map(lambda p: map(math.radians, p), (a, b))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def walk_seconds(m):
    return m * 1.3 / 1.3


def reader(source, name):
    if zipfile.is_zipfile(source):
        archive = zipfile.ZipFile(source)
        if name not in archive.namelist():
            return None
        return csv.DictReader(io.TextIOWrapper(archive.open(name), encoding='utf-8-sig'))
    path = os.path.join(source, name)
    return csv.DictReader(open(path, encoding='utf-8-sig')) if os.path.exists(path) else None


def load(source):
    feed = os.path.splitext(os.path.basename(source.rstrip('/')))[0]
    routes = {r['route_id']: r for r in reader(source, 'routes.txt')}
    line_of_trip = {}
    for trip in reader(source, 'trips.txt'):
        route = routes[trip['route_id']]
        if int(route['route_type']) not in BUS:
            line_of_trip[trip['trip_id']] = route['route_short_name'] or route['route_long_name']
    lines_at = defaultdict(set)
    for call in reader(source, 'stop_times.txt'):
        line = line_of_trip.get(call['trip_id'])
        if line:
            lines_at[call['stop_id']].add(line)

    rows = {r['stop_id']: r for r in reader(source, 'stops.txt')}
    stations = {}
    for stop_id, lines in lines_at.items():
        row = rows[stop_id]
        parent = row.get('parent_station') or stop_id
        station = stations.setdefault(parent, {'feed': feed, 'name': rows.get(parent, row)['stop_name'],
                                               'platforms': [], 'lines': set(), 'ids': {parent}})
        station['platforms'].append((float(row['stop_lat']), float(row['stop_lon'])))
        station['lines'] |= lines
        station['ids'].add(stop_id)

    transfers = set()
    for row in reader(source, 'transfers.txt') or []:
        if row.get('transfer_type') != '3':
            transfers |= {(feed, row['from_stop_id'], row['to_stop_id']), (feed, row['to_stop_id'], row['from_stop_id'])}
    return list(stations.values()), transfers


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('feeds', nargs='+', help='GTFS zips or folders for one city')
    parser.add_argument('--meters', type=float, default=450, help='widest gap to list (default 450)')
    args = parser.parse_args()

    stations, transfers = [], set()
    for source in args.feeds:
        found, linked = load(source)
        stations += found
        transfers |= linked

    pairs = []
    for i, a in enumerate(stations):
        for b in stations[i + 1:]:
            if not (a['lines'] - b['lines'] and b['lines'] - a['lines']):
                continue
            gap = min(meters(p, q) for p in a['platforms'] for q in b['platforms'])
            if gap > args.meters:
                continue
            in_feed = a['feed'] == b['feed'] and any((a['feed'], x, y) in transfers for x in a['ids'] for y in b['ids'])
            pairs.append((gap, a, b, in_feed))

    print(f'{len(stations)} stations, {len(pairs)} pairs within {args.meters:.0f} m\n')
    for gap, a, b, in_feed in sorted(pairs, key=lambda p: p[0]):
        seconds = walk_seconds(gap)
        kind = 'in feed' if in_feed else 'same place' if seconds <= SAME_PLACE_SECONDS else 'nearby' if gap <= WALK_RADIUS_METERS else 'too far'
        describe = lambda s: f"{s['name']} [{s['feed']}] ({', '.join(sorted(s['lines']))[:40]})"
        print(f'{gap:4.0f} m  {seconds / 60:4.1f} min  {kind:<10}  {describe(a)}  <->  {describe(b)}')


if __name__ == '__main__':
    main()
