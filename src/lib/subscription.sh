# ── lib/subscription.sh ───────────────────────────────────────────────────────
# 订阅服务：把本机的 Snell 用户（含 ShadowTLS）以订阅链接输出，Sub-Store 可以
# 像订阅 3x-ui 那样用 source=remote 订阅本机，Mihomo / Surge 也能直接导入。
#
# 输出目标：clash（默认，给 Sub-Store 与 Mihomo）、clash-full、surge（含 v6 与
# ShadowTLS）、base64、json、health。Clash 目标会自动跳过 Mihomo 不支持的节点
# （snell v6、ShadowTLS），并在响应里用注释说明跳过了什么。
#
# 服务是纯 python3 标准库的 HTTP 服务（不需要 pip），配置在
# ${SNELL_CONF_DIR}/.subscription（600），token 写在路径里。每次请求都重新读
# 配置文件与 users/*.conf，所以加用户、改 PSK 之后订阅立即生效，不用重启。
#
# 由 snell.sh 引用（# @bundle），不单独发布。

SNELL_SUB_CONF="${SNELL_CONF_DIR}/.subscription"
SNELL_SUB_SVC="${INSTALL_DIR}/snell-subscription"
SNELL_SUB_UNIT="${SYSTEMD_DIR}/snell-subscription.service"
SNELL_SUB_UNIT_NAME="snell-subscription"
SNELL_SUB_PORT_DEFAULT="13357"
SNELL_SUB_TLS_PORT_DEFAULT="40332"

# 读配置里某个键的值
snell_sub_get() {   # <key>
    [ -f "$SNELL_SUB_CONF" ] || return 1
    sed -n "s/^$1=//p" "$SNELL_SUB_CONF" | tail -n 1
}

# 幂等写入配置（文件 600：里面的 token 等同凭据）
snell_sub_set() {   # <key> <value>
    mkdir -p "$(dirname "$SNELL_SUB_CONF")" 2>/dev/null || true
    touch "$SNELL_SUB_CONF" 2>/dev/null || return 1
    if grep -q "^$1=" "$SNELL_SUB_CONF" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$SNELL_SUB_CONF"
    else
        echo "$1=$2" >> "$SNELL_SUB_CONF"
    fi
    chmod 600 "$SNELL_SUB_CONF" 2>/dev/null || true
}

snell_sub_token_new() { tr -dc A-Za-z0-9 < /dev/urandom | head -c 40; }

# 生成默认配置。已有的键不动，所以重复执行不会把 token / 端口换掉
snell_sub_ensure_conf() {
    mkdir -p "${SNELL_CONF_DIR}" 2>/dev/null || true
    [ -f "$SNELL_SUB_CONF" ] || : > "$SNELL_SUB_CONF"
    chmod 600 "$SNELL_SUB_CONF" 2>/dev/null || true

    [ -n "$(snell_sub_get SUB_TOKEN)" ] || snell_sub_set SUB_TOKEN "$(snell_sub_token_new)"
    [ -n "$(snell_sub_get SUB_PORT)" ] || snell_sub_set SUB_PORT "$SNELL_SUB_PORT_DEFAULT"
    [ -n "$(snell_sub_get SUB_BIND)" ] || snell_sub_set SUB_BIND "127.0.0.1"
    [ -n "$(snell_sub_get SUB_ENABLED)" ] || snell_sub_set SUB_ENABLED "1"
    grep -q '^SUB_SERVER=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_SERVER ""
    grep -q '^SUB_COUNTRY=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_COUNTRY ""
    grep -q '^SUB_TLS_ENABLED=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_TLS_ENABLED "0"
    grep -q '^SUB_TLS_PORT=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_TLS_PORT "40332"
    grep -q '^SUB_CERT=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_CERT ""
    grep -q '^SUB_KEY=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_KEY ""
    grep -q '^SUB_PUBLIC=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_PUBLIC ""
    # Clash 目标默认不带 v6：mihomo 在 v1.19.34 之前遇到 version: 6 会整份配置加载失败
    grep -q '^SUB_INCLUDE_V6=' "$SNELL_SUB_CONF" 2>/dev/null || snell_sub_set SUB_INCLUDE_V6 "0"

    # 节点地址与地区只在为空时自动补，用户手动设过就尊重手动值
    if [ -z "$(snell_sub_get SUB_SERVER)" ]; then
        local ip
        ip=$(get_public_ipv4 2>/dev/null)
        [ -n "$ip" ] && snell_sub_set SUB_SERVER "$ip"
    fi
    if [ -z "$(snell_sub_get SUB_COUNTRY)" ]; then
        local address country
        address=$(snell_sub_get SUB_SERVER)
        if [ -n "$address" ]; then
            country=$(get_ip_country "$address" 2>/dev/null)
            case "$country" in
                [A-Z][A-Z]) snell_sub_set SUB_COUNTRY "$country" ;;
            esac
        fi
    fi
    return 0
}

# 订阅服务本体（python3 标准库；改这里的话同步改仓库里的同名 .py）
snell_sub_write_service() {
    mkdir -p "$(dirname "$SNELL_SUB_SVC")" || return 1
    cat > "$SNELL_SUB_SVC" <<'SNELLSUB_PY'
#!/usr/bin/env python3
"""Snell subscription endpoint.

Reads the local Snell users (``/etc/snell/users/*.conf``) and the ShadowTLS
units that front them, then serves them as a subscription so that Sub-Store can
consume this host with ``source=remote`` (the same way it consumes 3x-ui).

Routes (TOKEN comes from ``/etc/snell/.subscription``)::

    GET /<TOKEN>/sub                       Clash proxies fragment (default)
    GET /<TOKEN>/sub?target=clash          same as above
    GET /<TOKEN>/sub?target=clash-full     ready-to-use Clash config
    GET /<TOKEN>/sub?target=surge          Surge proxy lines (all versions)
    GET /<TOKEN>/sub?target=base64         base64 of the Surge lines
    GET /<TOKEN>/sub?target=json           JSON {"proxies": [...]}
    GET /<TOKEN>/clash.yaml                alias of target=clash
    GET /<TOKEN>/full.yaml                 alias of target=clash-full
    GET /<TOKEN>/surge.txt                 alias of target=surge
    GET /<TOKEN>/base64.txt                alias of target=base64
    GET /<TOKEN>/json                      alias of target=json
    GET /<TOKEN>/health                    liveness probe

Every response is ``no-store``: the accounts change whenever a user is added or
a PSK is rotated, and both Sub-Store and the clients must see the new values.
Extra query parameters (``noCache=true``, ``target=ClashMeta`` ...) are ignored
so one URL can be shared by Sub-Store and a client.  ``notes=1`` appends the
"why was this node skipped" comments; they are off by default because some
mobile clients reject any line that is not a ``- {...}`` proxy entry.

Clash targets emit one proxy per line as a flow mapping (``- {"name":...}``),
not the indented block form: iOS clients in the Clash family (Stash and
friends) drop multi-line proxy blocks, the whole node silently disappears.

Two things Clash clients historically could not use are filtered out of the
Clash targets by default, because emitting them would make the whole profile
invalid:

* Snell v6 - mihomo v1.19.34 (PR #3410) added outbound version 6 support;
  turn it on with ``SUB_INCLUDE_V6=1`` (``snell sub v6``)
* ShadowTLS-wrapped nodes (Mihomo's snell outbound has no shadow-tls plugin)

The Surge targets carry everything, since Surge supports all of it. Nothing is
lost silently: the skipped nodes are listed in a YAML comment.

Only the Python standard library is used, so no pip install is needed.
"""

import base64
import hmac
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CONF_PATH = os.environ.get('SNELL_SUB_CONF', '/etc/snell/.subscription')
UNIT_DIR = os.environ.get('SNELL_SUB_UNIT_DIR', '/etc/systemd/system')

CLASH_VERSIONS = (4, 5)          # mihomo before v1.19.34 only accepts these; v6 via SUB_INCLUDE_V6=1
IP_CACHE_TTL = 600              # seconds to reuse a detected public address
UNIT_CACHE_TTL = 15             # seconds to reuse systemd is-active answers

_ip_cache = {'value': '', 'at': 0.0}
_unit_cache = {}


# ── configuration ────────────────────────────────────────────────────────────

def read_conf(path=CONF_PATH):
    conf = {}
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                conf[key.strip()] = value.strip()
    except OSError:
        pass
    return conf


def conf_value(conf, key, default=''):
    value = conf.get(key, '')
    return value if value != '' else default


# ── reading the installed users ──────────────────────────────────────────────

def parse_conf_file(path):
    """Parse one snell-*.conf: the same keys the shell side writes."""
    values = {}
    marker = ''
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                m = re.match(r'^#\s*version-choice\s*=\s*(v[456])\s*$', line)
                if m:
                    marker = m.group(1)
                    continue
                if line.startswith('#') or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                values[key.strip()] = value.strip()
    except OSError:
        return None

    ports = re.findall(r':(\d+)', values.get('listen', ''))
    if not ports:
        return None
    return {
        'conf': path,
        'port': int(ports[-1]),
        'psk': values.get('psk', ''),
        'mode': values.get('mode', ''),
        'version': marker,          # empty => fall back to the unit below
        'ipv6': values.get('ipv6', ''),
    }


def unit_channel(service):
    """Which channel a unit runs (ExecStart=.../snell-server-v5)."""
    path = os.path.join(UNIT_DIR, service)
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError:
        return ''
    m = re.search(r'ExecStart=\S*snell-server-(v[456])\b', text)
    return m.group(1) if m else ''


def unit_active(service):
    """systemd unit active? Answers are cached; non-systemd hosts say yes."""
    if not os.path.isdir('/run/systemd/system'):
        return True
    now = time.time()
    hit = _unit_cache.get(service)
    if hit and now - hit[1] < UNIT_CACHE_TTL:
        return hit[0]
    try:
        rc = subprocess.run(['systemctl', 'is-active', '--quiet', service],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            timeout=5).returncode
        active = rc == 0
    except (OSError, subprocess.SubprocessError):
        active = True
    _unit_cache[service] = (active, now)
    return active


def collect_users():
    """Every enabled Snell user, with the version resolved as the shell does."""
    users_dir = os.path.join(os.path.dirname(CONF_PATH), 'users')
    try:
        names = sorted(os.listdir(users_dir))
    except OSError:
        return []

    # main user first, the rest by port: the main one is the node people look for
    def order(name):
        if name == 'snell-main.conf':
            return (0, 0)
        match = re.search(r'(\d+)\.conf$', name)
        return (1, int(match.group(1)) if match else 0)

    users = []
    for name in sorted(names, key=order):
        if not name.endswith('.conf'):
            continue
        parsed = parse_conf_file(os.path.join(users_dir, name))
        if not parsed or not parsed['psk']:
            continue
        if not parsed['version']:
            # no marker (older install): the unit knows which binary it runs
            main_port = users[0]['port'] if users else None
            service = 'snell.service' if main_port == parsed['port'] else 'snell-%d.service' % parsed['port']
            parsed['version'] = unit_channel(service) or unit_channel('snell.service') or 'v4'
        if parsed['version'] == 'v6' and not parsed['mode']:
            parsed['mode'] = 'default'
        parsed['service'] = ('snell.service' if name == 'snell-main.conf'
                             else 'snell-%d.service' % parsed['port'])
        parsed['active'] = unit_active(parsed['service'])
        users.append(parsed)
    return users


def collect_shadowtls(users):
    """ShadowTLS v3 units that front a local Snell user."""
    by_port = {u['port']: u for u in users}
    try:
        names = sorted(os.listdir(UNIT_DIR))
    except OSError:
        return []

    nodes = []
    for name in names:
        if not (name.startswith('shadowtls-snell-') and name.endswith('.service')):
            continue
        try:
            with open(os.path.join(UNIT_DIR, name), 'r', encoding='utf-8', errors='replace') as fh:
                exec_line = ''
                for line in fh:
                    if line.startswith('ExecStart='):
                        exec_line = line.strip()
                        break
        except OSError:
            continue
        if not exec_line:
            continue

        def grab(pattern):
            m = re.search(pattern, exec_line)
            return m.group(1) if m else ''

        listen_port = grab(r'--listen\s+\S*:(\d+)')
        backend_port = grab(r'--server\s+\S*:(\d+)')
        password = grab(r'--password\s+(\S+)')
        sni = grab(r'--tls\s+([^\s]+)')
        if not (listen_port and backend_port and password):
            continue
        backend = by_port.get(int(backend_port))
        if not backend or not unit_active(name):
            continue
        nodes.append({
            'port': int(listen_port),
            'backend_port': int(backend_port),
            'psk': backend['psk'],
            'version': backend['version'],
            'mode': backend['mode'],
            'password': password,
            'sni': sni,
            'service': name,
        })
    return nodes


# ── addressing ───────────────────────────────────────────────────────────────

def detect_public_ip(conf):
    """Configured address first; otherwise ask once and cache for a while."""
    explicit = conf_value(conf, 'SUB_SERVER')
    if explicit:
        return explicit

    now = time.time()
    if _ip_cache['value'] and now - _ip_cache['at'] < IP_CACHE_TTL:
        return _ip_cache['value']
    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip'):
        try:
            with urllib.request.urlopen(url, timeout=4) as resp:
                candidate = resp.read(64).decode('ascii', 'replace').strip()
        except Exception:                                   # noqa: BLE001 - any failure means "try the next one"
            continue
        if re.match(r'^[0-9a-fA-F:.]+$', candidate):
            _ip_cache.update(value=candidate, at=now)
            return candidate
    return ''


def node_name(conf, prefix, version, port, stls=False):
    parts = []
    tag = conf_value(conf, 'SUB_TAG')
    if tag:
        parts.append(tag)
    if prefix:
        parts.append(prefix)
    parts.append('Snell')
    if stls:
        parts.append('STLS')
    parts.append(version)
    parts.append(str(port))
    return '-'.join(parts)


def build_nodes(conf):
    """Normalised node list, Clash-ready fields included."""
    users = collect_users()
    stls = collect_shadowtls(users)
    hidden = [u for u in users if not u['active']]
    users = [u for u in users if u['active']]

    server = detect_public_ip(conf)
    country = conf_value(conf, 'SUB_COUNTRY')
    nodes = []

    for u in users:
        digits = int(u['version'][1:])
        nodes.append({
            'name': node_name(conf, country, u['version'], u['port']),
            'server': server,
            'port': u['port'],
            'psk': u['psk'],
            'version': digits,
            'mode': u['mode'],
            'stls': None,
            'udp': True,
        })

    for s in stls:
        digits = int(s['version'][1:])
        nodes.append({
            'name': node_name(conf, country, s['version'], s['port'], stls=True),
            'server': server,
            'port': s['port'],
            'psk': s['psk'],
            'version': digits,
            'mode': s['mode'],
            'stls': {'password': s['password'], 'sni': s['sni'], 'version': 3},
            'udp': True,
        })

    return nodes, hidden


# ── rendering ────────────────────────────────────────────────────────────────

def yaml_quote(value):
    return '"%s"' % str(value).replace('\\', '\\\\').replace('"', '\\"')


def clash_skip_reason(node, include_v6):
    if node['stls']:
        return 'ShadowTLS 需要 Surge，Mihomo 的 snell 出站不支持'
    if node['version'] not in CLASH_VERSIONS and not include_v6:
        return 'Mihomo v1.19.34 之前只接受 version 4 / 5（snell sub v6 可开启）'
    return ''


def clash_objects(nodes, include_v6):
    """Split nodes into (usable, skipped) for Clash-family targets."""
    usable = []
    skipped = []
    for node in nodes:
        reason = clash_skip_reason(node, include_v6)
        if reason:
            skipped.append('%s（%s）' % (node['name'], reason))
        else:
            usable.append(node)
    return usable, skipped


def clash_entry(node):
    """One proxy as a single-line flow mapping.

    iOS 的 Clash 系客户端（Stash / ClashX 移动端等）解析不了块式写法，
    多行缩进的节点会被当成非法条目整条丢掉，只认 ``- {json}`` 这种单行流式映射。
    """
    item = {
        'name': node['name'],
        'type': 'snell',
        'server': node['server'],
        'port': node['port'],
        'psk': node['psk'],
        'version': node['version'],
        'udp': bool(node['udp']),
        'reuse': True,
    }
    if node['version'] >= 6 and node.get('mode'):
        item['mode'] = node['mode']
    return json.dumps(item, ensure_ascii=False, separators=(',', ':'))


def clash_notes(hidden, skipped):
    """Optional ``#`` comments; off by default so strict clients never see them."""
    notes = []
    if skipped:
        notes.append('# 已跳过 %d 个此目标无法使用的节点：' % len(skipped))
        for item in skipped:
            notes.append('#   - %s' % item)
    if hidden:
        notes.append('# 已跳过 %d 个未在运行的服务：%s'
                     % (len(hidden), ', '.join(str(u['port']) for u in hidden)))
    return notes


def render_clash(nodes, conf, hidden, include_v6=False, notes=False):
    lines = []
    usable, skipped = clash_objects(nodes, include_v6)

    if notes:
        lines.extend(clash_notes(hidden, skipped))

    if not usable:
        if notes:
            lines.append('# 没有可用的节点：本机只有 Surge 才能用的 Snell（v6 / ShadowTLS）')
        lines.append('proxies: []')
        return '\n'.join(lines) + '\n'

    lines.append('proxies:')
    for node in usable:
        lines.append('- %s' % clash_entry(node))
    return '\n'.join(lines) + '\n'


def render_clash_full(nodes, conf, hidden, include_v6=False, notes=False):
    fragment = render_clash(nodes, conf, hidden, include_v6, notes)
    usable, _skipped = clash_objects(nodes, include_v6)
    names = [node['name'] for node in usable]
    head = [
        '# Snell-Plus 生成的完整 Clash 配置（可直接导入 Mihomo / Clash Verge）',
        'mixed-port: 7890',
        'allow-lan: false',
        'mode: rule',
        'log-level: info',
        'external-controller: 127.0.0.1:9090',
        '',
    ]
    body = fragment.rstrip('\n').split('\n')
    tail = ['', 'proxy-groups:', '  - name: Proxy', '    type: select', '    proxies:']
    if names:
        tail.extend('      - %s' % yaml_quote(name) for name in names)
    tail.append('      - DIRECT')
    tail.extend(['', 'rules:', '  - MATCH,Proxy', ''])
    return '\n'.join(head + body + tail)


def surge_line(node):
    parts = ['%s = snell' % node['name'],
             str(node['server']),
             str(node['port']),
             'psk = %s' % node['psk'],
             'version = %d' % node['version']]
    if node['version'] >= 6 and node['mode']:
        parts.append('mode = %s' % node['mode'])
    parts.append('reuse = true')
    parts.append('tfo = true')
    if node['stls']:
        if node['stls']['password']:
            parts.append('shadow-tls-password = %s' % node['stls']['password'])
        if node['stls']['sni']:
            parts.append('shadow-tls-sni = %s' % node['stls']['sni'])
        parts.append('shadow-tls-version = %d' % node['stls']['version'])
    return ', '.join(parts)


def render_surge(nodes, hidden):
    lines = []
    if hidden:
        lines.append('# 已跳过 %d 个未在运行的服务：%s'
                     % (len(hidden), ', '.join(str(u['port']) for u in hidden)))
    lines.extend(surge_line(node) for node in nodes)
    if not nodes:
        lines.append('# 没有可用的节点：确认至少有一个用户的 snell 服务在运行')
    return '\n'.join(lines) + '\n'


def render_json(nodes):
    payload = []
    for node in nodes:
        item = {
            'name': node['name'],
            'type': 'snell',
            'server': node['server'],
            'port': node['port'],
            'psk': node['psk'],
            'version': node['version'],
        }
        if node['mode']:
            item['mode'] = node['mode']
        if node['stls']:
            item['shadow-tls'] = node['stls']
        payload.append(item)
    return json.dumps({'proxies': payload}, ensure_ascii=False, indent=2) + '\n'


def render(target, notes=False):
    conf = read_conf()
    nodes, hidden = build_nodes(conf)
    include_v6 = conf_value(conf, 'SUB_INCLUDE_V6') == '1'

    if target in ('clash-full', 'full', 'config'):
        return render_clash_full(nodes, conf, hidden, include_v6, notes), 'text/yaml; charset=utf-8'
    if target in ('surge', 'surge-list'):
        return render_surge(nodes, hidden), 'text/plain; charset=utf-8'
    if target in ('base64', 'b64', 'v2ray', 'general'):
        text = render_surge(nodes, hidden)
        return base64.b64encode(text.encode('utf-8')).decode('ascii') + '\n', 'text/plain; charset=utf-8'
    if target in ('json', 'js'):
        return render_json(nodes), 'application/json; charset=utf-8'
    return render_clash(nodes, conf, hidden, include_v6, notes), 'text/yaml; charset=utf-8'


PATH_TARGETS = {
    'sub': '',
    'clash.yaml': 'clash',
    'clash': 'clash',
    'full.yaml': 'clash-full',
    'surge.txt': 'surge',
    'base64.txt': 'base64',
    'json': 'json',
}


# ── HTTP ─────────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    server_version = 'SnellSubscription/1.0'
    sys_version = ''

    def log_message(self, fmt, *args):                       # keep the journal short
        sys.stderr.write('%s - %s\n' % (self.address_string(), fmt % args))

    def _send(self, code, body, content_type='text/plain; charset=utf-8'):
        raw = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(raw)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split('/') if p]
        if not parts:
            self._send(404, 'not found\n')
            return

        conf = read_conf()
        token = conf_value(conf, 'SUB_TOKEN')
        if not token or not hmac.compare_digest(parts[0], token):
            # same answer for "wrong token" and "no such path": nothing to probe
            self._send(404, 'not found\n')
            return

        if len(parts) == 1:
            self._send(404, 'not found\n')
            return

        tail = parts[1].lower()
        if tail == 'health':
            self._send(200, 'ok\n')
            return

        if tail not in PATH_TARGETS:
            self._send(404, 'not found\n')
            return

        query = parse_qs(parsed.query)
        target = (query.get('target') or [''])[0].strip().lower()
        if not target:
            target = PATH_TARGETS[tail]
        notes = (query.get('notes') or [''])[0].strip().lower() in ('1', 'true', 'yes', 'on')

        try:
            text, content_type = render(target, notes)
        except Exception as exc:                             # noqa: BLE001 - report, never crash the service
            sys.stderr.write('render failed: %r\n' % (exc,))
            self._send(500, 'render failed\n')
            return

        self._send(200, text, content_type)


class TLSServer(ThreadingHTTPServer):
    """独立 HTTPS 监听；证书文件变更后自动重载，续期不用重启服务。"""

    def __init__(self, addr, handler, cert, key):
        self.cert = cert
        self.key = key
        self._stamp = None
        self._ctx = None
        super().__init__(addr, handler)
        self._reload(force=True)

    def _reload(self, force=False):
        try:
            stamp = (os.path.getmtime(self.cert), os.path.getmtime(self.key))
        except OSError:
            return
        if not force and stamp == self._stamp:
            return
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        try:
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        except (AttributeError, ValueError):
            pass
        ctx.load_cert_chain(self.cert, self.key)
        self._ctx = ctx
        self._stamp = stamp

    def get_request(self):
        self._reload()
        sock, addr = super().get_request()
        return self._ctx.wrap_socket(sock, server_side=True), addr

    def handle_error(self, request, client_address):
        pass


def main():
    conf = read_conf()
    port = int(conf_value(conf, 'SUB_PORT', '13357'))
    bind = conf_value(conf, 'SUB_BIND', '127.0.0.1')
    if not conf_value(conf, 'SUB_TOKEN'):
        sys.stderr.write('SUB_TOKEN missing in %s\n' % CONF_PATH)
        return 2
    if conf_value(conf, 'SUB_ENABLED', '1') != '1':
        sys.stderr.write('subscription disabled in %s\n' % CONF_PATH)
        return 0

    ThreadingHTTPServer.allow_reuse_address = True
    httpd = ThreadingHTTPServer((bind, port), Handler)
    sys.stderr.write('snell-subscription listening on %s:%d\n' % (bind, port))

    tls_httpd = None
    if conf_value(conf, 'SUB_TLS_ENABLED', '0').strip() == '1':
        tls_port = int((conf_value(conf, 'SUB_TLS_PORT', '0') or '0').strip() or 0)
        cert = conf_value(conf, 'SUB_CERT', '').strip()
        key = conf_value(conf, 'SUB_KEY', '').strip()
        if tls_port and os.path.isfile(cert) and os.path.isfile(key):
            try:
                tls_httpd = TLSServer(('0.0.0.0', tls_port), Handler, cert, key)
                sys.stderr.write('snell-subscription listening on https://0.0.0.0:%d\n' % tls_port)
            except OSError as exc:
                sys.stderr.write('HTTPS listen on %d failed: %r\n' % (tls_port, exc))
                tls_httpd = None
        else:
            sys.stderr.write('HTTPS disabled: missing cert/key or port (%s / %s / %s)\n'
                             % (tls_port, cert, key))

    if tls_httpd is not None:
        threading.Thread(target=tls_httpd.serve_forever, daemon=True).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        if tls_httpd is not None:
            tls_httpd.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
SNELLSUB_PY
    chmod 755 "$SNELL_SUB_SVC" || return 1
}

# python3 的绝对路径（写进 unit，避免 PATH 与 systemd 不一致）
snell_sub_python() {
    command -v python3 2>/dev/null || true
}

# 缺 python3 时尝试装一次；装不上返回非 0，由调用方决定怎么办
snell_sub_ensure_python() {
    [ -n "$(snell_sub_python)" ] && return 0
    echo -e "${YELLOW}订阅服务需要 python3，正在尝试安装...${RESET}"
    pkg_install python3 >/dev/null 2>&1 || pkg_install python3-minimal >/dev/null 2>&1 || true
    [ -n "$(snell_sub_python)" ] && return 0
    echo -e "${RED}装不上 python3，订阅服务无法运行${RESET}"
    return 1
}

snell_sub_write_unit() {
    local python
    python=$(snell_sub_python)
    [ -n "$python" ] || return 1
    cat > "$SNELL_SUB_UNIT" << EOF
[Unit]
Description=Snell subscription endpoint (Sub-Store remote)
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${python} ${SNELL_SUB_SVC}
Restart=on-failure
RestartSec=2s
# 只读配置、不写文件系统：这个服务不落任何数据
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ReadOnlyPaths=${SNELL_CONF_DIR} ${SYSTEMD_DIR}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SNELL_SUB_UNIT_NAME}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SNELL_SUB_UNIT" 2>/dev/null || true
}

snell_sub_enable() {
    snell_sub_ensure_conf || { echo -e "${RED}生成订阅配置失败${RESET}"; return 1; }
    snell_sub_ensure_python || return 1
    snell_sub_write_service || { echo -e "${RED}写入 ${SNELL_SUB_SVC} 失败${RESET}"; return 1; }
    snell_sub_write_unit || { echo -e "${RED}取不到 python3 路径${RESET}"; return 1; }
    snell_sub_set SUB_ENABLED 1

    systemctl daemon-reload 2>/dev/null || true
    # 先 enable 再 restart：unit 或程序刚被改写过，正在跑的进程要换成新的
    systemctl enable "$SNELL_SUB_UNIT_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SNELL_SUB_UNIT_NAME" >/dev/null 2>&1 || true

    local waited=0
    while [ "$waited" -lt 10 ]; do
        if systemctl is-active --quiet "$SNELL_SUB_UNIT_NAME"; then
            echo -e "${GREEN}订阅服务已启动（$(snell_sub_get SUB_BIND):$(snell_sub_get SUB_PORT)）${RESET}"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo -e "${RED}订阅服务没有起来，最近日志：${RESET}"
    journalctl -u "$SNELL_SUB_UNIT_NAME" -n 20 --no-pager 2>/dev/null | sed 's/^/   /'
    return 1
}

snell_sub_disable() {
    systemctl disable --now "$SNELL_SUB_UNIT_NAME" >/dev/null 2>&1 || true
    snell_sub_set SUB_ENABLED 0
    echo -e "${YELLOW}订阅服务已停用。配置与链接保留，重新启用后 token 不变${RESET}"
}

snell_sub_restart() {
    systemctl restart "$SNELL_SUB_UNIT_NAME" >/dev/null 2>&1 || {
        echo -e "${RED}重启失败，服务可能还没启用${RESET}"
        return 1
    }
    sleep 1
    echo -e "${GREEN}订阅服务已重启${RESET}"
}

snell_sub_status() {
    local state="未启用"
    systemctl is-enabled --quiet "$SNELL_SUB_UNIT_NAME" 2>/dev/null && state="已启用"
    if systemctl is-active --quiet "$SNELL_SUB_UNIT_NAME" 2>/dev/null; then
        state="${state} / 运行中"
    elif [ -f "$SNELL_SUB_UNIT" ]; then
        state="${state} / 已停止"
    fi

    echo -e "${CYAN}订阅服务：${RESET}${state}"
    [ -f "$SNELL_SUB_CONF" ] || { echo -e "${YELLOW}还没有配置，选「1」或执行 snell sub on 生成${RESET}"; return 0; }
    echo -e "${CYAN}监听：${RESET}$(snell_sub_get SUB_BIND):$(snell_sub_get SUB_PORT)"
    echo -e "${CYAN}节点地址：${RESET}$(snell_sub_get SUB_SERVER)"
    echo -e "${CYAN}地区标记：${RESET}$(snell_sub_get SUB_COUNTRY)"
    if [ "$(snell_sub_get SUB_INCLUDE_V6)" = "1" ]; then
        echo -e "${CYAN}Clash 输出 v6：${RESET}已开启（需要 mihomo v1.19.34+）"
    else
        echo -e "${CYAN}Clash 输出 v6：${RESET}未开启（只出 v4 / v5）"
    fi
    if [ -f "$SNELL_SUB_SVC" ]; then
        echo -e "${CYAN}程序：${RESET}${SNELL_SUB_SVC}"
    fi
    return 0
}

# 本机可用的订阅地址（不含 token，调用方自己拼）
snell_sub_base_url() {
    # 订阅服务默认只监听回环；公网由同一进程另开 HTTPS 端口
    echo "http://127.0.0.1:$(snell_sub_get SUB_PORT)"
}

snell_sub_links() {
    [ -f "$SNELL_SUB_CONF" ] || { snell_sub_ensure_conf || return 1; }
    local token base pub
    token=$(snell_sub_get SUB_TOKEN)
    base=$(snell_sub_base_url)
    pub=$(snell_sub_public_url 2>/dev/null) || pub=""

    echo
    echo -e "${CYAN}================================${RESET}"
    echo -e "${GREEN}订阅链接${RESET}"
    echo -e "${CYAN}================================${RESET}"
    if [ -n "$pub" ]; then
        echo -e "${YELLOW}公网 HTTPS（外部客户端 / 其它机器上的 Sub-Store）${RESET}"
        echo "  ${pub}/sub?target=clash"
        echo "  ${pub}/sub?target=surge"
        echo "  ${pub}/health"
        echo
        echo -e "${YELLOW}本机（回环不出网，同机 Sub-Store 用）${RESET}"
    else
        echo -e "${YELLOW}当前只有本机链接（外部不可用）${RESET}"
        echo -e "${YELLOW}开公网 HTTPS：snell sub public${RESET}"
        echo -e "${YELLOW}本机（回环不出网）${RESET}"
    fi
    echo -e "${YELLOW}Sub-Store remote / Clash（默认）${RESET}"
    echo "  ${base}/${token}/sub?target=clash"
    echo -e "${YELLOW}完整 Clash 配置（直接导入 Mihomo / Verge）${RESET}"
    echo "  ${base}/${token}/sub?target=clash-full"
    echo -e "${YELLOW}Surge（含 v6 与 ShadowTLS 节点）${RESET}"
    echo "  ${base}/${token}/sub?target=surge"
    echo -e "${YELLOW}base64 / JSON / 存活探测${RESET}"
    echo "  ${base}/${token}/sub?target=base64"
    echo "  ${base}/${token}/sub?target=json"
    echo "  ${base}/${token}/health"
    echo
    echo -e "${YELLOW}链接等同凭据，别公开贴；泄露后执行 snell sub token 重置${RESET}"
}

snell_sub_store_hint() {
    local token base
    token=$(snell_sub_get SUB_TOKEN)
    base=$(snell_sub_base_url)
    echo
    echo -e "${CYAN}Sub-Store 里新增订阅源${RESET}"
    echo -e "  类型     ${GREEN}remote${RESET}"
    echo -e "  名称     随意（例如 snell）"
    echo -e "  URL      ${GREEN}${base}/${token}/sub?target=clash${RESET}"
    echo
    echo -e "${YELLOW}要点：不要再往这个源里填内容（content）。remote 源如果残留旧内容，"
    echo -e "Sub-Store 会优先用内容里的旧 PSK，表现为「订阅是新的、输出是旧的」。${RESET}"
    echo -e "${YELLOW}需要保留 Snell v6 / ShadowTLS 节点时（例如给「小火箭」这类 Surge 集合用），"
    echo -e "URL 换成 target=surge：Surge 支持这些节点，Sub-Store 会自己按目标客户端过滤。${RESET}"
}

# 域名默认 <IP 横线形式>.sslip.io，证书复用机器上现成的那份。

# ──────────── 公网 HTTPS（服务自己监听独立端口，用 IP 证书） ────────────
# 对外给 https://<IP>:<port>/<token>/sub：不占 443、不改 nginx、不和面板抢端口。

snell_sub_tls_port_free() {   # <port> 无人监听 -> 0
    [ -n "$1" ] || return 1
    ! ss -lntH "sport = :$1" 2>/dev/null | grep -q .
}

# 输出 "cert|key"，优先能覆盖本机 IP 的证书
snell_sub_pick_ip_cert() {
    local ip d c k x
    ip=$(snell_sub_get SUB_SERVER)
    [ -n "$ip" ] || ip=$(get_public_ipv4 2>/dev/null)
    [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    local dirs="" 
    while IFS= read -r x; do
        [ -n "$x" ] && dirs="$dirs $(dirname "$x")"
    done < <(nginx -T 2>/dev/null | awk '/ssl_certificate /{print $2}' | tr -d ';' | sort -u)
    dirs="$dirs /root/cert/ip /root/cert/domain /etc/nginx/certs /etc/ssl/snell /etc/pki/tls/snell"

    if command -v openssl >/dev/null 2>&1; then
        for d in $dirs; do
            c="$d/fullchain.pem"; k="$d/privkey.pem"
            [ -f "$c" ] && [ -f "$k" ] || continue
            if openssl x509 -in "$c" -noout -checkhost "$ip" 2>/dev/null | grep -q 'does match'; then
                echo "${c}|${k}"; return 0
            fi
        done
    fi
    for d in $dirs; do
        c="$d/fullchain.pem"; k="$d/privkey.pem"
        [ -f "$c" ] && [ -f "$k" ] && { echo "${c}|${k}"; return 0; }
    done
    return 1
}

snell_sub_tls_port_pick() {
    local p base
    base=$(snell_sub_get SUB_TLS_PORT)
    [ -n "$base" ] || base=40332
    for p in "$base" $(seq 40332 40360); do
        snell_sub_tls_port_free "$p" && { echo "$p"; return 0; }
    done
    return 1
}

snell_sub_tls_enable() {   # [port]
    snell_sub_ensure_conf || return 1
    local picked cert key port code ip
    picked=$(snell_sub_pick_ip_cert) || {
        echo -e "${RED}没找到证书（fullchain.pem / privkey.pem），无法启用 HTTPS${RESET}"
        echo -e "${YELLOW}先给本机 IP 签一张证书，再执行：snell sub public${RESET}"
        return 1
    }
    cert=${picked%%|*}; key=${picked#*|}
    ip=$(snell_sub_get SUB_SERVER)

    port=${1:-$(snell_sub_get SUB_TLS_PORT)}
    [ -n "$port" ] || port=40332
    if ! snell_sub_tls_port_free "$port"; then
        port=$(snell_sub_tls_port_pick) || { echo -e "${RED}找不到可用端口${RESET}"; return 1; }
        echo -e "${YELLOW}默认端口被占用，改用 ${port}${RESET}"
    fi

    snell_sub_set SUB_TLS_ENABLED 1
    snell_sub_set SUB_TLS_PORT "$port"
    snell_sub_set SUB_CERT "$cert"
    snell_sub_set SUB_KEY "$key"
    snell_sub_set SUB_BIND "127.0.0.1"
    open_port "$port" TCP >/dev/null 2>&1 || true
    snell_sub_restart || return 1

    sleep 1
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
        "https://${ip}:${port}/$(snell_sub_get SUB_TOKEN)/health" 2>/dev/null)
    if [ "$code" = "200" ]; then
        snell_sub_set SUB_PUBLIC "https://${ip}:${port}/$(snell_sub_get SUB_TOKEN)"
        echo -e "${GREEN}公网 HTTPS 已就绪：https://${ip}:${port}/<token>/sub?target=clash${RESET}"
        echo -e "${CYAN}证书 ${cert}，端口 ${port}（不占 443，与 nginx 无关）${RESET}"
    else
        echo -e "${RED}端口已监听但自检失败（HTTP ${code:-超时}）${RESET}"
        echo -e "${YELLOW}排查：journalctl -u ${SNELL_SUB_UNIT_NAME} -n 30${RESET}"
        return 1
    fi
    return 0
}

snell_sub_tls_disable() {
    snell_sub_ensure_conf || return 1
    snell_sub_set SUB_TLS_ENABLED 0
    snell_sub_set SUB_PUBLIC ""
    snell_sub_restart >/dev/null 2>&1 || true
    echo -e "${GREEN}已关闭公网 HTTPS（订阅服务仍监听 127.0.0.1）${RESET}"
}

snell_sub_public_url() {
    local pub
    pub=$(snell_sub_get SUB_PUBLIC)
    [ -n "$pub" ] || return 1
    [ "$(snell_sub_get SUB_TLS_ENABLED)" = "1" ] || return 1
    echo "$pub"
}

snell_sub_do_public() {
    snell_sub_tls_enable || return 1
    snell_sub_links
}

snell_sub_do_local() {
    snell_sub_tls_disable
    snell_sub_links
}

# 自检：逐个目标请求一次本机端点，看到节点数和关键字段
snell_sub_check() {
    [ -f "$SNELL_SUB_CONF" ] || { echo -e "${RED}还没有订阅配置${RESET}"; return 1; }
    systemctl is-active --quiet "$SNELL_SUB_UNIT_NAME" 2>/dev/null || {
        echo -e "${RED}服务没在运行，先 snell sub on${RESET}"
        return 1
    }
    local token base url code body count failed=0
    token=$(snell_sub_get SUB_TOKEN)
    base=$(snell_sub_base_url)

    for target in clash clash-full surge base64 json; do
        url="${base}/${token}/sub?target=${target}"
        code=$(curl -s -o /tmp/snell-sub-check.$$ -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
        case "$target" in
            clash)      count=$(grep -c '^    type: snell' /tmp/snell-sub-check.$$ 2>/dev/null) ;;
            clash-full) count=$(grep -c '^    type: snell' /tmp/snell-sub-check.$$ 2>/dev/null) ;;
            surge)      count=$(grep -c ' = snell,' /tmp/snell-sub-check.$$ 2>/dev/null) ;;
            base64)     count=$(base64 -d < /tmp/snell-sub-check.$$ 2>/dev/null | grep -c ' = snell,') ;;
            json)       count=$(grep -c '"type": "snell"' /tmp/snell-sub-check.$$ 2>/dev/null) ;;
        esac
        [ -n "$count" ] || count=0
        if [ "$code" = "200" ]; then
            echo -e "  ${GREEN}OK${RESET}   ${target}   HTTP ${code}   ${count} 个节点"
        else
            echo -e "  ${RED}FAIL${RESET} ${target}   HTTP ${code}"
            failed=1
        fi
    done
    rm -f /tmp/snell-sub-check.$$

    local health
    health=$(curl -s --max-time 5 "${base}/${token}/health" 2>/dev/null)
    if [ "$health" = "ok" ]; then
        echo -e "  ${GREEN}OK${RESET}   health    HTTP 200"
    else
        echo -e "  ${RED}FAIL${RESET} health"
        failed=1
    fi
    return $failed
}

# 卸载时一并清掉订阅服务
snell_sub_cleanup() {
    if [ -f "$SNELL_SUB_UNIT" ] || systemctl list-unit-files 2>/dev/null | grep -q "^${SNELL_SUB_UNIT_NAME}\."; then
        echo -e "${YELLOW}正在移除订阅服务${RESET}"
        systemctl disable --now "$SNELL_SUB_UNIT_NAME" >/dev/null 2>&1 || true
        rm -f "$SNELL_SUB_UNIT" "$SNELL_SUB_SVC"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$SNELL_SUB_SVC" "$SNELL_SUB_CONF" 2>/dev/null || true
    return 0
}

# 安装流程末尾调用：装了就把订阅服务拉起来。失败只告警，不影响 Snell 本体
snell_sub_install_silent() {
    [ -f "$SNELL_CONF_FILE" ] || return 0
    if ! snell_sub_ensure_python; then
        echo -e "${YELLOW}跳过订阅服务（没有 python3）。装好后可以执行 snell sub on 再试${RESET}"
        return 0
    fi
    if snell_sub_enable; then
        snell_sub_tls_enable >/dev/null 2>&1 || true
        snell_sub_links
    else
        echo -e "${YELLOW}订阅服务没能启动，Snell 本体的安装不受影响；可稍后执行 snell sub on 重试${RESET}"
    fi
    return 0
}

snell_sub_menu() {
    local choice
    while true; do
        echo
        echo -e "${CYAN}========== 订阅服务（Sub-Store / Clash） ==========${RESET}"
        echo -e "  ${GREEN}1.${RESET} 查看订阅链接 / 启用服务"
        echo -e "  ${GREEN}2.${RESET} 停用服务"
        echo -e "  ${GREEN}3.${RESET} 重启服务"
        echo -e "  ${GREEN}4.${RESET} 服务状态"
        echo -e "  ${GREEN}5.${RESET} 自检（逐个目标请求一次）"
        echo -e "  ${GREEN}6.${RESET} Sub-Store remote 源怎么填"
        echo -e "  ${GREEN}7.${RESET} 开公网 HTTPS（IP + 独立端口）"
        echo -e "  ${GREEN}8.${RESET} 重置 token"
        echo -e "  ${GREEN}9.${RESET} 修改订阅端口"
        echo -e "  ${GREEN}10.${RESET} 设置节点地址 / 地区标记"
        echo -e "  ${GREEN}11.${RESET} 开 / 关公网 HTTPS"
        echo -e "  ${GREEN}12.${RESET} 修改 HTTPS 端口"
        echo -e "  ${GREEN}13.${RESET} Clash 输出 Snell v6（需 mihomo v1.19.34+）"
        echo -e "  ${GREEN}0.${RESET} 返回主菜单"
        if ! read -rp "  请选择: " choice; then return 0; fi
        case "$choice" in
            1)  snell_sub_ensure_conf && snell_sub_enable && snell_sub_links ;;
            2)  snell_sub_disable ;;
            3)  snell_sub_restart ;;
            4)  snell_sub_status ;;
            5)  snell_sub_check ;;
            6)  snell_sub_store_hint ;;
            7)  snell_sub_tls_enable && snell_sub_links ;;
            8)  snell_sub_reset_token ;;
            9)  snell_sub_change_port ;;
            10) snell_sub_change_server ;;
            11) snell_sub_toggle_bind ;;
            12) snell_sub_change_tls_port ;;
            13) snell_sub_toggle_v6 ;;
            0)  return 0 ;;
            *)  echo -e "${RED}请输入正确的选项${RESET}" ;;
        esac
        echo
        read -rp "  按回车继续..." _ || return 0
    done
}

snell_sub_reset_token() {
    snell_sub_ensure_conf || return 1
    snell_sub_set SUB_TOKEN "$(snell_sub_token_new)"
    echo -e "${GREEN}已重置 token（服务每次请求重读配置，不用重启）${RESET}"
    echo -e "${YELLOW}Sub-Store 里的旧 URL 会立刻失效，记得同步更新${RESET}"
    snell_sub_links
}

snell_sub_change_port() {
    snell_sub_ensure_conf || return 1
    local new_port
    read -rp "  新的订阅端口（当前 $(snell_sub_get SUB_PORT)）: " new_port
    case "$new_port" in
        ''|*[!0-9]*) echo -e "${RED}端口必须是数字${RESET}"; return 1 ;;
    esac
    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}端口范围是 1-65535${RESET}"
        return 1
    fi
    snell_sub_set SUB_PORT "$new_port"
    snell_sub_restart || return 1
    snell_sub_links
}

snell_sub_change_tls_port() {
    snell_sub_ensure_conf || return 1
    local cur p
    cur=$(snell_sub_get SUB_TLS_PORT)
    read -rp "  新的 HTTPS 端口（当前 ${cur:-40332}，回车不改）: " p
    [ -n "$p" ] || { echo -e "${CYAN}未修改${RESET}"; return 0; }
    case "$p" in
        *[!0-9]*) echo -e "${RED}端口必须是数字${RESET}"; return 1 ;;
    esac
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        echo -e "${RED}端口范围是 1-65535${RESET}"; return 1
    fi
    snell_sub_set SUB_TLS_PORT "$p"
    if [ "$(snell_sub_get SUB_TLS_ENABLED)" = "1" ]; then
        snell_sub_tls_enable "$p" || return 1
    else
        echo -e "${GREEN}HTTPS 端口已设为 ${p}（snell sub public 时生效）${RESET}"
    fi
    snell_sub_links
}

snell_sub_change_server() {
    snell_sub_ensure_conf || return 1
    local addr country
    read -rp "  节点地址（IP 或域名，当前 $(snell_sub_get SUB_SERVER)）: " addr
    if [ -n "$addr" ]; then
        snell_sub_set SUB_SERVER "$addr"
        country=$(get_ip_country "$addr" 2>/dev/null)
        case "$country" in
            [A-Z][A-Z]) snell_sub_set SUB_COUNTRY "$country"; echo -e "${GREEN}已识别地区：${country}${RESET}" ;;
        esac
    fi
    read -rp "  地区标记（节点名前缀，例如 US，留空不改）: " country
    [ -n "$country" ] && snell_sub_set SUB_COUNTRY "$country"
    echo -e "${GREEN}已更新，服务下次请求即生效${RESET}"
}

# Clash 目标是否带上 Snell v6：mihomo v1.19.34（PR #3410）起支持 version 6
snell_sub_toggle_v6() {
    snell_sub_ensure_conf || return 1
    local cur
    cur=$(snell_sub_get SUB_INCLUDE_V6)
    if [ "$cur" = "1" ]; then
        snell_sub_set SUB_INCLUDE_V6 "0"
        echo -e "${GREEN}已关闭：Clash 目标只输出 v4 / v5${RESET}"
    else
        snell_sub_set SUB_INCLUDE_V6 "1"
        echo -e "${GREEN}已开启：Clash 目标会输出 Snell v6${RESET}"
        echo -e "${YELLOW}需要 mihomo v1.19.34 及以上；旧版客户端遇到 version: 6 会整份配置加载失败${RESET}"
        echo -e "${CYAN}Surge / Stash 本来就支持 v6，不受这个开关影响${RESET}"
    fi
    echo -e "${CYAN}服务每次请求重读配置，无需重启${RESET}"
    snell_sub_links
}

# 公网订阅只走 HTTPS：不再提供 0.0.0.0 明文监听
snell_sub_toggle_bind() {
    snell_sub_ensure_conf || return 1
    if [ "$(snell_sub_get SUB_TLS_ENABLED)" = "1" ]; then
        snell_sub_do_local
    else
        snell_sub_do_public
    fi
}

# 非交互入口：snell sub <动作>
snell_sub_cli() {
    local action="${1:-show}" arg="${2:-}"
    case "$action" in
        show|"")        snell_sub_links ;;
        on|enable)      snell_sub_ensure_conf && snell_sub_enable && snell_sub_links ;;
        off|disable)    snell_sub_disable ;;
        restart)        snell_sub_restart ;;
        status)         snell_sub_status ;;
        check|test)     snell_sub_check ;;
        store|remote)   snell_sub_store_hint ;;
        https|tls)      snell_sub_tls_enable && snell_sub_links ;;
        tls-off)        snell_sub_tls_disable && snell_sub_links ;;
        token)          snell_sub_reset_token ;;
        port)           snell_sub_change_port ;;
        server)         snell_sub_change_server ;;
        tls-port)
            if [ -n "$arg" ]; then
                snell_sub_set SUB_TLS_PORT "$arg"
                [ "$(snell_sub_get SUB_TLS_ENABLED)" = "1" ] && snell_sub_tls_enable "$arg"
                snell_sub_links
            else
                snell_sub_change_tls_port
            fi ;;
        public)         snell_sub_do_public ;;
        local|private)  snell_sub_do_local ;;
        v6|include-v6)  snell_sub_toggle_v6 ;;
        menu)           snell_sub_menu ;;
        -h|--help|help)
            echo "用法：snell sub [show|on|off|restart|status|check|store|https|tls-port|token|port|server|public|local|v6|menu]"
            ;;
        *)
            echo -e "${RED}未知动作：${action}${RESET}"
            echo "用法：snell sub [show|on|off|restart|status|check|store|https|tls-port|token|port|server|public|local|v6|menu]"
            return 1
            ;;
    esac
}
