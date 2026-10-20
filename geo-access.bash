#!/usr/bin/env bash
# Standalone GeoLite2 download and host firewall setup.
set +x
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Запустите через sudo bash geo-access.sh' >&2; exit 1; }
# Read prompts from the controlling terminal, including curl | bash launches.
exec 8<>/dev/tty || { echo 'Для ввода нужен интерактивный терминал.' >&2; exit 1; }
printf '<start script>\n' >&8
cancel() { echo 'Отменено.' >&2; exit 1; }
ask_value() {
    local prompt=$1 secret=${2:-no} value
    if [[ $secret == yes ]]; then
        read -r -s -u 8 -p "$prompt " value || return 1
        printf '\n' >&8
    else
        read -r -u 8 -p "$prompt " value || return 1
    fi
    printf '%s\n' "$value"
}
choose_backend() {
    local choice
    printf 'Выберите firewall:\n1) UFW\n2) iptables\n3) nftables\n' >&8
    read -r -u 8 -p 'Введите номер или название [3]: ' choice || return 1
    case ${choice,,} in
        1|ufw) echo ufw ;;
        2|iptables) echo iptables ;;
        3|nftables|'') echo nftables ;;
        *) echo 'Неверный вариант firewall.' >&2; return 1 ;;
    esac
}
backend=${1:-}
if [[ $backend == --* ]]; then
    mode=$backend
    backend=
else
    mode=${2:---apply}
fi
case "$mode" in
    --apply|--check|--remove) ;;
    *) echo 'Использование: sudo bash geo-access.sh [nftables|iptables|ufw] [--apply|--check|--remove]' >&2; exit 1 ;;
esac
if [[ $mode != --remove ]]; then
    MAXMIND_ACCOUNT_ID=$(ask_value 'Введите MaxMind Account ID:') || cancel
    [[ $MAXMIND_ACCOUNT_ID =~ ^[0-9]+$ ]] || { echo 'Account ID должен состоять из цифр.' >&2; exit 1; }
    MAXMIND_LICENSE_KEY=$(ask_value 'Введите MaxMind License Key:' yes) || cancel
    [[ $MAXMIND_LICENSE_KEY =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Пустой ключ или недопустимые символы.' >&2; exit 1; }
fi
if [[ -z $backend ]]; then
    backend=$(choose_backend) || cancel
fi
case $backend in
    nftables) dependencies=(nft) ;;
    iptables) dependencies=(iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore) ;;
    ufw) dependencies=(ufw iptables ip6tables iptables-restore ip6tables-restore) ;;
    *) echo 'Backend: nftables|iptables|ufw' >&2; exit 1 ;;
esac
case "$mode" in
    --apply|--check|--remove) ;;
    *) echo 'Использование: sudo bash geo-access.sh [nftables|iptables|ufw] [--apply|--check|--remove]' >&2; exit 1 ;;
esac
for cmd in python3 flock "${dependencies[@]}"; do
    command -v "$cmd" >/dev/null || { echo "Установите зависимость: $cmd" >&2; exit 1; }
done
exec 9>/run/geo-web.lock
flock -x 9
# UFW must already be active; enabling it could change access to other ports.
if [[ $backend == ufw ]]; then
    LC_ALL=C ufw status | head -n 1 | grep -qx 'Status: active' || {
        echo 'UFW должен быть уже включен и настроен (включая SSH).' >&2; exit 1;
    }
    grep -Eq '^IPV6=yes$' /etc/default/ufw || {
        echo 'Для UFW требуется IPV6=yes в /etc/default/ufw.' >&2; exit 1;
    }
fi
if [[ $mode == --remove && $backend == nftables ]]; then
    nft delete table inet geo_web
    exit
fi
if [[ $mode == --remove && $backend == iptables ]]; then
    for tool in iptables ip6tables; do
        while "$tool" -w -C INPUT -j GEO_WEB 2>/dev/null; do
            "$tool" -w -D INPUT -j GEO_WEB
        done
        if "$tool" -w -S GEO_WEB >/dev/null 2>&1; then
            "$tool" -w -F GEO_WEB
            "$tool" -w -X GEO_WEB
        fi
    done
    exit
fi
if [[ $mode != --remove ]]; then
command -v curl >/dev/null || { echo 'Установите curl' >&2; exit 1; }
echo 'Скачивание GeoLite2 City и подготовка списка...'
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
if [[ $mode != --remove ]]; then
# Keep credentials out of curl's process arguments. Do not run with bash -x.
printf 'machine download.maxmind.com login %s password %s\n' \
    "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" > "$tmp/netrc"
curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 30 --max-time 1800 --proto '=https' --proto-redir '=https' \
    --netrc-file "$tmp/netrc" \
    'https://download.maxmind.com/geoip/databases/GeoLite2-City-CSV/download?suffix=zip' \
    --output "$tmp/city.zip"
unset MAXMIND_ACCOUNT_ID MAXMIND_LICENSE_KEY
rm -f -- "$tmp/netrc"
python3 - "$tmp/city.zip" "$tmp/allowed.cidrs" <<'PY'
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

fi
if [[ $backend == nftables ]]; then
if nft list table inet geo_web >/dev/null 2>&1; then
    echo 'delete table inet geo_web' > "$tmp/rules.nft"
fi
python3 - "$tmp/allowed.cidrs" >> "$tmp/rules.nft" <<'PY'
import ipaddress
import sys
networks = {4: [], 6: []}
with open(sys.argv[1], encoding='ascii') as f:
    for line in f:
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        net = ipaddress.ip_network(line)
        if net.prefixlen == 0:
            raise ValueError('Default routes are forbidden')
        networks[net.version].append(net)
if not networks[4] or not networks[6]:
    raise ValueError('Expected nonempty IPv4 and IPv6 lists')
print('table inet geo_web {')
for version, kind in [(4, 'ipv4_addr'), (6, 'ipv6_addr')]:
    items = ', '.join(map(str, ipaddress.collapse_addresses(networks[version])))
    print(f' set allowed{version} {{ type {kind}; flags interval; elements = {{ {items} }}; }}')
print(' chain input { type filter hook input priority -10; policy accept;')
print('  iifname "lo" accept')
# Replies to connections initiated by this host are not incoming service access.
print('  ct direction reply accept')
for protocol in ('tcp', 'udp'):
    print(f'  {protocol} dport {{ 80, 443 }} ip saddr @allowed4 counter accept')
    print(f'  {protocol} dport {{ 80, 443 }} ip6 saddr @allowed6 counter accept')
    print(f'  {protocol} dport {{ 80, 443 }} counter drop')
print(' }\n}')
PY
nft --check --file "$tmp/rules.nft"
if [[ $mode == --check ]]; then
    echo 'Rules validated; nothing applied.'
else
    # Delete/recreate is a single atomic transaction; no unprotected interval.
    nft --file "$tmp/rules.nft"
    echo 'Applied. Inspect: nft list table inet geo_web'
fi

fi

if [[ $backend != nftables ]]; then
    if [[ $backend == iptables ]]; then
        iptables-save -t filter > "$tmp/old4"
        ip6tables-save -t filter > "$tmp/old6"
    else
        cp /etc/ufw/before.rules "$tmp/old4"
        cp /etc/ufw/before6.rules "$tmp/old6"
    fi
    python3 - "$tmp" "$backend" "$mode" <<'PY'
import ipaddress
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
backend, mode = sys.argv[2:]
nets = {4: [], 6: []}
if mode != '--remove':
    for line in (root / 'allowed.cidrs').read_text().splitlines():
        n = ipaddress.ip_network(line)
        if n.prefixlen == 0:
            raise ValueError('Default route forbidden')
        nets[n.version].append(n)
    if not all(nets.values()):
        raise ValueError('IPv4 and IPv6 required')
for v in (4, 6):
    rules = [':GEO_WEB - [0:0]', '-A GEO_WEB -i lo -j RETURN',
             '-A GEO_WEB -m conntrack --ctdir REPLY -j RETURN']
    for proto in ('tcp', 'udp'):
        # Only web packets enter this chain's accept/drop logic.
        for n in ipaddress.collapse_addresses(nets[v]):
            rules.append(f'-A GEO_WEB -p {proto} -m multiport --dports 80,443 -s {n} -j ACCEPT')
        rules.append(f'-A GEO_WEB -p {proto} -m multiport --dports 80,443 -j DROP')
    old = (root / f'old{v}').read_text()
    if backend == 'iptables':
        # Modify only our own chain, keeping the rest of the filter table.
        lines = ['*filter', ':GEO_WEB - [0:0]', '-F GEO_WEB']
        lines += ['-D INPUT -j GEO_WEB'] * old.splitlines().count('-A INPUT -j GEO_WEB')
        lines += rules[1:] + ['-I INPUT 1 -j GEO_WEB', 'COMMIT']
        new = '\n'.join(lines) + '\n'
    else:
        old = re.sub(r'(?ms)^# BEGIN GEO_ACCESS\n.*?^# END GEO_ACCESS\n', '', old)
        new = old
        if mode != '--remove':
            # Place before stock UFW established/related acceptance.
            block = '\n'.join(['# BEGIN GEO_ACCESS', rules[0],
                              '-F GEO_WEB', '-A ufw-before-input -j GEO_WEB', *rules[1:],
                              '# END GEO_ACCESS']) + '\n'
            sections = list(re.finditer(r'(?m)^\*filter\s*$', old))
            if len(sections) != 1:
                raise ValueError('Expected one UFW filter table')
            begin = sections[0].end()
            commit = re.search(r'(?m)^COMMIT\s*$', old[begin:])
            if not commit:
                raise ValueError('Missing UFW COMMIT')
            end = begin + commit.start()
            first_rule = re.search(r'(?m)^-[AI] ', old[begin:end])
            position = begin + first_rule.start() if first_rule else end
            new = old[:position] + block + old[position:]
    (root / f'new{v}').write_text(new)
PY
    if [[ $backend == iptables ]]; then
        iptables-restore --wait 10 --noflush --test < "$tmp/new4"
        ip6tables-restore --wait 10 --noflush --test < "$tmp/new6"
    else
        iptables-restore --wait 10 --test < "$tmp/new4"
        ip6tables-restore --wait 10 --test < "$tmp/new6"
    fi
    if [[ $mode == --check ]]; then
        echo "Проверка $backend завершена; правила не применялись."
        exit
    fi
    if [[ $backend == iptables ]]; then
        if ! { iptables-restore --wait 10 --noflush < "$tmp/new4" &&
               ip6tables-restore --wait 10 --noflush < "$tmp/new6"; }; then
            echo 'Ошибка применения; восстановление filter из снимков.' >&2
            iptables-restore --wait 10 < "$tmp/old4"
            ip6tables-restore --wait 10 < "$tmp/old6"
            exit 1
        fi
    else
        # Preserve permissions of existing files. Back up before modifying.
        cp -p /etc/ufw/before.rules /etc/ufw/before.rules.geo-access.bak
        cp -p /etc/ufw/before6.rules /etc/ufw/before6.rules.geo-access.bak
        cat "$tmp/new4" > /etc/ufw/before.rules
        cat "$tmp/new6" > /etc/ufw/before6.rules
        if ! ufw reload; then
            cat "$tmp/old4" > /etc/ufw/before.rules
            cat "$tmp/old6" > /etc/ufw/before6.rules
            ufw reload
            exit 1
        fi
    fi
    if [[ $backend == ufw && $mode == --remove ]]; then
        for tool in iptables ip6tables; do
            if "$tool" -w -S GEO_WEB >/dev/null 2>&1; then
                "$tool" -w -F GEO_WEB
                "$tool" -w -X GEO_WEB
            fi
        done
    fi
    echo "Готово: $backend ($mode)."
fi
