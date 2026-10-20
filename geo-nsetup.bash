#!/usr/bin/env bash
# Download GeoLite2 City and restrict selected host ports using the selected firewall.
set +x
set -euo pipefail
umask 077
account_id=
license_key=
out=./allowed.cidrs
out_set=false
backend=
exclude_ips='[]'
ports=80,443
mode=--apply
for arg in "$@"; do
    case $arg in
        --account_id=*|--account-id=*) account_id=${arg#*=} ;;
        --license_key=*|--license-key=*|-license_key=*) license_key=${arg#*=} ;;
        --firewall=*) backend=${arg#*=} ;;
        --exclude_ip=*) exclude_ips=${arg#*=} ;;
        --ports=*) ports=${arg#*=} ;;
        --check) mode=--check ;;
        --rollback) mode=--remove ;;
        --output=*) out=${arg#*=}; out_set=true ;;
        -h|--help)
            printf '%s\n' 'Usage: bash download-geo.sh [--account_id=ID] [--license_key=KEY] [--firewall=ufw|iptables|nftables] [--ports=80,443,8443] [--exclude_ip=["1.1.1.1","::1"]] [--output=FILE|FILE] [--check|--rollback]'
            exit 0 ;;
        -*) echo "Неизвестный параметр: ${arg%%=*}" >&2; exit 1 ;;
        *)
            [[ $out_set == false ]] || { echo 'Укажите только один выходной файл.' >&2; exit 1; }
            out=$arg; out_set=true ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo 'Запустите скрипт от root или через sudo bash.' >&2; exit 1; }
if [[ $mode != --remove ]]; then
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
fi
if [[ -z $backend ]]; then
    exec 8<>/dev/tty || { echo 'Нет терминала. Передайте --firewall=ufw|iptables|nftables' >&2; exit 1; }
    printf 'Выберите firewall:\n1) UFW\n2) iptables\n3) nftables\n' >&8
    read -r -u 8 -p 'Введите номер или название [3]: ' choice
    case ${choice,,} in
        1|ufw) backend=ufw ;;
        2|iptables) backend=iptables ;;
        3|nftables|'') backend=nftables ;;
        *) echo 'Неверный вариант firewall.' >&2; exit 1 ;;
    esac
    exec 8>&-
fi
case $backend in
    nftables) dependencies=(nft) ;;
    iptables) dependencies=(iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore) ;;
    ufw) dependencies=(ufw iptables ip6tables iptables-restore ip6tables-restore) ;;
    *) echo 'Backend: nftables|iptables|ufw' >&2; exit 1 ;;
esac
case "$mode" in
    --apply|--check|--remove) ;;
    *) echo 'Использование: sudo bash download-geo.sh --firewall=ufw|iptables|nftables [--check]' >&2; exit 1 ;;
esac
for cmd in python3 flock "${dependencies[@]}"; do
    command -v "$cmd" >/dev/null || { echo "Установите зависимость: $cmd" >&2; exit 1; }
done
exec 9>/run/geo-web.lock
flock -x 9
ufw_is_active() {
    # Drain the complete output: head/grep -q can cause SIGPIPE under pipefail.
    LC_ALL=C ufw status | grep -x 'Status: active' >/dev/null
}
ufw_geo_is_installed() {
    local tool chain first proto address batch
    for tool in iptables ip6tables; do
        chain=ufw-before-input
        [[ $tool == ip6tables ]] && chain=ufw6-before-input
        first=$("$tool" -w -S "$chain" | awk '/^-A / && !seen++ {print}') || return 1
        [[ $first == "-A $chain -j GEO_WEB" ]] || return 1
        "$tool" -w -C INPUT -j "$chain" || return 1
        for proto in tcp udp; do
            while IFS= read -r batch; do
                "$tool" -w -C GEO_WEB -p "$proto" -m multiport --dports "$batch" -j DROP || return 1
            done < "$tmp/port-batches"
        done
    done
    while IFS= read -r address; do
        tool=iptables
        [[ $address == *:* ]] && tool=ip6tables
        for proto in tcp udp; do
            while IFS= read -r batch; do
                "$tool" -w -C GEO_WEB -p "$proto" -m multiport --dports "$batch" \
                    -s "$address" -m comment --comment geo-exception -j ACCEPT || return 1
            done < "$tmp/port-batches"
        done
    done < "$tmp/excluded.cidrs"
}
# UFW must already be active; enabling it could change access to other ports.
if [[ $backend == ufw && $mode != --remove ]]; then
    ufw_is_active || {
        echo 'UFW должен быть уже включен и настроен (включая SSH).' >&2; exit 1;
    }
    grep -Eq '^IPV6=yes$' /etc/default/ufw || {
        echo 'Для UFW требуется IPV6=yes в /etc/default/ufw.' >&2; exit 1;
    }
fi

if [[ $mode == --remove && $backend == nftables ]]; then
    if nft list table inet geo_web >/dev/null 2>&1; then
        nft delete table inet geo_web
    fi
    echo 'Геофильтр nftables удалён.'
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
    echo 'Геофильтр iptables удалён.'
    exit
fi
# Remember whether UFW was active; rollback must not enable an inactive firewall.
ufw_was_active=false
if [[ $backend == ufw ]] && ufw_is_active; then
    ufw_was_active=true
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
python3 - "$ports" "$tmp" <<'PY'
import pathlib
import re
import sys

raw, directory = sys.argv[1:]
parts = raw.split(',')
if any(not re.fullmatch(r'[0-9]{1,5}', p.strip()) for p in parts):
    raise SystemExit('--ports: укажите номера портов через запятую, например 80,443,8443')
ports = sorted({int(p) for p in parts})
if any(p < 1 or p > 65535 for p in ports):
    raise SystemExit('--ports: допустимы номера от 1 до 65535')
root = pathlib.Path(directory)
(root / 'ports').write_text(','.join(map(str, ports)))
(root / 'port-batches').write_text(''.join(','.join(map(str, ports[i:i+15])) + '\n' for i in range(0, len(ports), 15)))
print('Порты геофильтра (TCP/UDP):', ','.join(map(str, ports)))
PY
python3 - "$exclude_ips" "$tmp/excluded.cidrs" <<'PY'
import ipaddress
import json
import pathlib
import sys

raw, target = sys.argv[1:]
try:
    values = json.loads(raw)
except json.JSONDecodeError:
    # Bash removes inner quotes in --exclude_ip=["1.1.1.1"]. Accept that spelling.
    if not (raw.startswith('[') and raw.endswith(']')):
        raise SystemExit('--exclude_ip: ожидается список IP в квадратных скобках')
    values = [v.strip() for v in raw[1:-1].split(',')] if raw[1:-1].strip() else []
if not isinstance(values, list) or any(not isinstance(v, str) for v in values):
    raise SystemExit('--exclude_ip: ожидается список строк с IP-адресами')
try:
    addresses = sorted(set(map(ipaddress.ip_address, values)), key=lambda a: (a.version, int(a)))
except ValueError as error:
    raise SystemExit(f'--exclude_ip: {error}')
pathlib.Path(target).write_text(''.join(f'{a}/{a.max_prefixlen}\n' for a in addresses))
print(f'Исключений из геофильтра: {len(addresses)}')
PY
if [[ $mode != --remove ]]; then
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
regions = {'09': 'Luhansk', '14': 'Donetsk', '65': 'Kherson', '23': 'Zaporizhzhia', '43': 'Crimea', '40': 'Sevastopol'}
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

rm -f -- "$tmp/netrc"
cp -- "$out" "$tmp/allowed.cidrs"
# Keep exceptions separate from geographic networks and emit exact source rules.
fi
if [[ $backend == nftables ]]; then
if nft list table inet geo_web >/dev/null 2>&1; then
    echo 'delete table inet geo_web' > "$tmp/rules.nft"
fi
python3 - "$tmp/allowed.cidrs" "$tmp/excluded.cidrs" "$tmp/ports" >> "$tmp/rules.nft" <<'PY'
import ipaddress
import sys
with open(sys.argv[3], encoding='ascii') as f:
    ports = ', '.join(f.read().strip().split(','))
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
with open(sys.argv[2], encoding='ascii') as f:
    for line in f:
        net = ipaddress.ip_network(line.strip())
        if net.prefixlen != net.max_prefixlen:
            raise ValueError('Exception must be a single IP')
        family = 'ip' if net.version == 4 else 'ip6'
        for protocol in ('tcp', 'udp'):
            print(f'  {protocol} dport {{ {ports} }} {family} saddr {net} counter accept')
for protocol in ('tcp', 'udp'):
    print(f'  {protocol} dport {{ {ports} }} ip saddr @allowed4 counter accept')
    print(f'  {protocol} dport {{ {ports} }} ip6 saddr @allowed6 counter accept')
    print(f'  {protocol} dport {{ {ports} }} counter drop')
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
ports_file = root / 'ports'
ports = ports_file.read_text().strip().split(',') if ports_file.exists() else ['80', '443']
port_batches = [','.join(ports[i:i+15]) for i in range(0, len(ports), 15)]
nets = {4: [], 6: []}
exceptions = {4: [], 6: []}
exception_file = root / 'excluded.cidrs'
if exception_file.exists():
    for line in exception_file.read_text().splitlines():
        n = ipaddress.ip_network(line)
        if n.prefixlen != n.max_prefixlen:
            raise ValueError('Exception must be a single IP')
        exceptions[n.version].append(n)
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
    for n in exceptions[v]:
        for proto in ('tcp', 'udp'):
            for batch in port_batches:
                rules.append(f'-A GEO_WEB -p {proto} -m multiport --dports {batch} -s {n} -m comment --comment geo-exception -j ACCEPT')
    for proto in ('tcp', 'udp'):
        # Apply to selected ports only. multiport accepts at most 15 ports per rule.
        for batch in port_batches:
            for n in ipaddress.collapse_addresses(nets[v]):
                rules.append(f'-A GEO_WEB -p {proto} -m multiport --dports {batch} -s {n} -j ACCEPT')
            rules.append(f'-A GEO_WEB -p {proto} -m multiport --dports {batch} -j DROP')
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
            input_chain = 'ufw-before-input' if v == 4 else 'ufw6-before-input'
            if not re.search(r'^:' + re.escape(input_chain) + r'\s', old, re.M):
                raise ValueError(f'Missing UFW chain: {input_chain}')
            block = '\n'.join(['# BEGIN GEO_ACCESS', rules[0],
                              '-F GEO_WEB', f'-A {input_chain} -j GEO_WEB', *rules[1:],
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
        if [[ $ufw_was_active == true ]] && { ! ufw reload || ! ufw_is_active ||
            { [[ $mode != --remove ]] && ! ufw_geo_is_installed; }; }; then
            echo 'Ошибка UFW; восстанавливаю прежние файлы и активное состояние.' >&2
            cat "$tmp/old4" > /etc/ufw/before.rules
            cat "$tmp/old6" > /etc/ufw/before6.rules
            # A failed reload can disable UFW. It was active before this run.
            if ! ufw --force enable; then
                echo 'Не удалось восстановить UFW. Проверьте ufw status и конфигурацию.' >&2
            fi
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
