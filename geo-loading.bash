#!/usr/bin/env bash
# Download GeoLite2 City and build an IPv4/IPv6 allowlist.
set +x
set -euo pipefail
umask 077
account_id=
license_key=
out=./allowed.cidrs
out_set=false
for arg in "$@"; do
    case $arg in
        --account_id=*|--account-id=*) account_id=${arg#*=} ;;
        --license_key=*|--license-key=*|-license_key=*) license_key=${arg#*=} ;;
        --output=*) out=${arg#*=}; out_set=true ;;
        -h|--help)
            printf '%s\n' 'Usage: bash download-geo.sh [--account_id=ID] [--license_key=KEY] [--output=FILE|FILE]'
            exit 0 ;;
        -*) echo "Неизвестный параметр: ${arg%%=*}" >&2; exit 1 ;;
        *)
            [[ $out_set == false ]] || { echo 'Укажите только один выходной файл.' >&2; exit 1; }
            out=$arg; out_set=true ;;
    esac
done
for cmd in curl python3; do command -v "$cmd" >/dev/null; done
if [[ -z $account_id || -z $license_key ]]; then
    # stdin may contain Bash source when launched through curl | bash.
    exec 8<>/dev/tty || {
        echo 'Нет терминала. Передайте --account_id=... и --license_key=...' >&2
        exit 1
    }
    if [[ -z $account_id ]]; then
        read -r -u 8 -p 'Введите MaxMind Account ID: ' account_id
    fi
    if [[ -z $license_key ]]; then
        read -r -s -u 8 -p 'Введите MaxMind License Key: ' license_key
        printf '\n' >&8
    fi
    exec 8>&-
fi
[[ $account_id =~ ^[0-9]+$ ]] || { echo 'Account ID должен состоять из цифр.' >&2; exit 1; }
[[ $license_key =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Пустой ключ или недопустимые символы.' >&2; exit 1; }
[[ -n $out ]] || { echo 'Укажите выходной файл.' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# Keep credentials out of curl's process arguments. Do not run with bash -x.
printf 'machine download.maxmind.com login %s password %s\n' \
    "$account_id" "$license_key" > "$tmp/netrc"
unset account_id license_key
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
