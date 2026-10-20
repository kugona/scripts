#!/usr/bin/env bash
# Download GeoLite2 City and build an IPv4/IPv6 allowlist.
set -euo pipefail
umask 077
: "${MAXMIND_ACCOUNT_ID:?Set MAXMIND_ACCOUNT_ID}"
: "${MAXMIND_LICENSE_KEY:?Set MAXMIND_LICENSE_KEY}"
out=${1:-./allowed.cidrs}
for cmd in curl python3; do command -v "$cmd" >/dev/null; done
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# Keep credentials out of curl's process arguments. Do not run with bash -x.
printf 'machine download.maxmind.com login %s password %s\n' \
    "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" > "$tmp/netrc"
curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 30 --max-time 1800 --proto '=https' --proto-redir '=https' \
    --netrc-file "$tmp/netrc" \
    'https://download.maxmind.com/geoip/databases/GeoLite2-City-CSV/download?suffix=zip' \
    --output "$tmp/city.zip"
python3 - "$tmp/city.zip" "$out" <<'PY'
import collections
import csv
import io
import ipaddress
import os
import pathlib
import sys
import tempfile
import zipfile

archive, target = sys.argv[1:]
regions = {'09': 'Luhansk', '14': 'Donetsk', '65': 'Kherson', '23': 'Zaporizhzhia'}
counts = collections.Counter()
with zipfile.ZipFile(archive) as z:
    def rows(suffix):
        matches = [n for n in z.namelist() if n.endswith('/' + suffix)]
        if len(matches) != 1:
            raise ValueError('Missing or ambiguous CSV: ' + suffix)
        with z.open(matches[0]) as f:
            yield from csv.DictReader(io.TextIOWrapper(f, encoding='utf-8-sig'))

    selected = {}
    for row in rows('GeoLite2-City-Locations-en.csv'):
        country = row['country_iso_code']
        region = row['subdivision_1_iso_code']
        if country == 'RU':
            selected[row['geoname_id']] = 'RU'
        elif country == 'UA' and region in regions:
            selected[row['geoname_id']] = regions[region]

    networks = {4: [], 6: []}
    for version in (4, 6):
        for row in rows(f'GeoLite2-City-Blocks-IPv{version}.csv'):
            # Physical geolocation only; registered country is not a substitute.
            group = selected.get(row['geoname_id'])
            if group:
                net = ipaddress.ip_network(row['network'])
                if net.version != version or net.prefixlen == 0:
                    raise ValueError('Invalid network: ' + row['network'])
                networks[version].append(net)
                counts[group] += 1
    missing = [g for g in ['RU', *regions.values()] if not counts[g]]
    if missing:
        raise ValueError('No networks for these regions; old list kept: ' + ', '.join(missing))
    result = [str(n) for v in (4, 6) for n in ipaddress.collapse_addresses(networks[v])]

dest = pathlib.Path(target).absolute()
dest.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix='.geo-', dir=dest.parent)
try:
    with os.fdopen(fd, 'w', encoding='ascii') as f:
        f.write('\n'.join(result) + '\n')
    os.replace(temporary, dest)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print('Source blocks:', dict(counts))
print(f'Saved {len(result)} CIDRs to {dest}')
PY
