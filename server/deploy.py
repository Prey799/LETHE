#!/usr/bin/env python3
"""LETHE provisioning; run by SSH worker. No secret values are printed."""
import base64
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import types
import contextlib
import removal

VERSION = '0.7.2'
RELEASE = 'v2.11.7-naive'
URL = 'https://github.com/klzgrad/forwardproxy/releases/download/v2.11.7-naive/caddy-forwardproxy-naive.tar.xz'
SHA256 = 'ac97057c925bb098eb575e7b0cb8bd547d4c5f845b09a3dedfbe34444aa7ae88'
ETC = Path('/etc/lethe')
OPT = Path('/opt/lethe')
UNIT = Path('/etc/systemd/system/lethe-caddy.service')
EGRESS_UNIT = Path('/etc/systemd/system/lethe-egress.service')
WEB = Path('/var/www/lethe')
STATE = Path('/var/lib/lethe-caddy')
SERVICE_USER = 'lethe-caddy'

class DeployError(Exception):
    pass

def run(args, timeout=40, check=True, data=None):
    # Never return an external command's stderr to the GUI: config errors may contain secrets.
    p = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=timeout, env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive', 'LC_ALL': 'C'})
    if check and p.returncode:
        raise DeployError('Команда %s завершилась с кодом %d.' % (Path(args[0]).name, p.returncode))
    return p

def emit(event, **fields):
    print(json.dumps({'event': event, **fields}, ensure_ascii=False), flush=True)

def step(message):
    emit('progress', message=message)

def validate(c):
    for key in ('vpsIp', 'exitIp'):
        try:
            ip = ipaddress.IPv4Address(c[key])
            if not ip.is_global: raise ValueError()
        except (KeyError, ValueError):
            raise DeployError('Нужен публичный IPv4: ' + key)
    domain = str(c.get('vpsDomain', '')).lower()
    if len(domain) > 253 or '.' not in domain or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', p) for p in domain.split('.')):
        raise DeployError('Некорректное доменное имя.')
    try:
        ipaddress.ip_address(domain)
        raise DeployError('Для сертификата нужен домен, а не IP.')
    except ValueError:
        pass
    if not re.fullmatch(r'[^\s<>"{}\\@]+@[^\s<>"{}\\@]+\.[^\s<>"{}\\@]+', str(c.get('email', ''))):
        raise DeployError('Укажите email для сертификата.')
    for key in ('vpnUser', 'vpnPassword'):
        value = c.get(key, '')
        if not isinstance(value, str) or not value or len(value) > 512 or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
            raise DeployError('Некорректные данные VPN: ' + key)
    if ':' in c['vpnUser']:
        raise DeployError('В имени VPN нельзя использовать двоеточие.')
    if len(c['vpnPassword']) < 16:
        raise DeployError('Для нового сервера нужен пароль VPN длиной не менее 16 символов.')
    return c

def caddyfile(c):
    # Credentials are injected into adapted JSON, never interpreted as Caddyfile tokens.
    return '''{
    admin off
    default_bind %s
    order forward_proxy before file_server
    servers {
        protocols h1 h2
    }
    log {
        exclude http.log.error
    }
}
:443, %s {
    tls %s
    forward_proxy {
        basic_auth LETHE_PLACEHOLDER LETHE_PLACEHOLDER
        hide_ip
        hide_via
        probe_resistance
    }
    file_server {
        root /var/www/lethe
    }
}
''' % (c['vpsIp'], c['vpsDomain'], c['email'])

def inject_auth(obj, user, password):
    found = 0
    if isinstance(obj, dict):
        if obj.get('handler') == 'forward_proxy':
            # Go [][]byte is JSON-base64; its bytes already contain HTTP Basic base64.
            basic = base64.b64encode((user + ':' + password).encode())
            obj['auth_credentials'] = [base64.b64encode(basic).decode()]
            found += 1
        for value in obj.values(): found += inject_auth(value, user, password)
    elif isinstance(obj, list):
        for value in obj: found += inject_auth(value, user, password)
    return found

def nft_config(uid, address):
    ipaddress.IPv4Address(address)
    return ('table ip lethe_v060 {\n chain postrouting {\n'
            '  type nat hook postrouting priority srcnat; policy accept;\n'
            '  meta skuid %d ct direction original counter snat to %s\n }\n}\n') % (int(uid), address)

def active(name):
    return run(['systemctl', 'is-active', '--quiet', name], check=False).returncode == 0

def listening_ports():
    if shutil.which('ss'):
        text = run(['ss', '-H', '-ltnp'], check=False).stdout.decode(errors='replace')
        return [line for line in text.splitlines() if re.search(r':(?:80|443)\s', line)]
    lines = []
    for filename in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            for line in Path(filename).read_text().splitlines()[1:]:
                fields = line.split()
                if fields[3] == '0A' and fields[1].split(':')[-1] in ('0050', '01BB'):
                    lines.append('unknown :%d ' % int(fields[1].split(':')[-1], 16))
        except FileNotFoundError:
            pass
    return lines

def status():
    if removal.path(removal.JOURNAL).exists():
        return {'status': 'partial_removal', 'installed': True, 'managed': True, 'removable': True,
                'message': 'Удаление не завершено. Можно повторно проверить состав и продолжить удаление.'}
    manifest = ETC / 'manifest.json'
    if manifest.exists():
        try:
            m = json.loads(manifest.read_text())
            valid = (m.get('product') == 'LETHE' and UNIT.exists() and (OPT / 'caddy').exists() and (ETC / 'config.json').exists())
            if not valid: raise ValueError()
            return {'status': 'installed', 'installed': True, 'managed': True, 'removable': True,
                    'running': active('lethe-caddy.service'), 'domain': m.get('domain', ''),
                    'version': m.get('version', ''), 'message': 'Сервер установлен'}
        except (ValueError, OSError):
            return {'status': 'conflict', 'installed': False, 'removable': True, 'message': 'Обнаружена неполная установка LETHE. Проверьте состав перед удалением.'}
    if any(p.exists() for p in (ETC, OPT, UNIT, EGRESS_UNIT, WEB, STATE)):
        return {'status': 'conflict', 'installed': False, 'message': 'Есть файлы предыдущей установки LETHE. Автоматическая перезапись отключена.'}
    if removal.path('/opt/https-tunnel-lab/PROJECT').exists():
        try:
            kind, domain, _, _ = removal.identify(removal_api())
            if kind == 'legacy':
                return {'status': 'installed', 'installed': True, 'managed': True, 'removable': True,
                        'kind': 'legacy', 'domain': domain, 'running': active('https-tunnel-caddy.service'),
                        'message': 'Сервер установлен: HTTPS Tunnel Lab с агентом мониторинга и доступами устройств.'}
        except (DeployError, ValueError, OSError):
            return {'status': 'conflict', 'installed': False, 'removable': False, 'message': 'Обнаружены файлы HTTPS Tunnel Lab, но принадлежность не подтверждена.'}
    listeners = listening_ports()
    # Recognize an existing external server without changing its configuration.
    if any('"caddy"' in line for line in listeners):
        for process in Path('/proc').glob('[0-9]*'):
            try:
                if (process / 'comm').read_text().strip() != 'caddy': continue
                binary = str((process / 'exe').resolve(strict=True))
                modules = run([binary, 'list-modules'], timeout=15, check=False).stdout
                if b'http.handlers.forward_proxy' in modules and any(re.search(r':443\s', line) and ('pid=' + process.name + ',') in line for line in listeners):
                    return {'status': 'installed', 'installed': True, 'managed': False, 'running': True,
                            'message': 'Сервер установлен: обнаружен работающий Caddy с forward_proxy. Настройки не изменены.'}
            except (OSError, DeployError, subprocess.TimeoutExpired):
                continue
    if listeners:
        return {'status': 'conflict', 'installed': False, 'message': 'Порт 80 или 443 занят другой службой. Установка заблокирована.'}
    for unit in ('caddy.service', 'caddy-naive.service', 'naive.service'):
        if run(['systemctl', 'show', '-p', 'LoadState', '--value', unit], check=False).stdout.strip() == b'loaded':
            return {'status': 'conflict', 'installed': False, 'message': 'Найдена существующая служба %s. Автоматическая перезапись отключена.' % unit}
    return {'status': 'absent', 'installed': False, 'message': 'Сервер не установлен. VPS свободен для установки.'}

def os_check():
    release = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            k, v = line.split('=', 1); release[k] = v.strip('"')
    supported = {'debian': {'12', '13'}, 'ubuntu': {'22.04', '24.04'}}
    if release.get('VERSION_ID') not in supported.get(release.get('ID'), set()):
        raise DeployError('Поддерживаются Debian 12/13 и Ubuntu 22.04/24.04.')
    if platform.machine() not in ('x86_64', 'amd64'):
        raise DeployError('Эта версия установщика поддерживает VPS x86-64.')
    if not Path('/run/systemd/system').is_dir():
        raise DeployError('Нужна система с работающим systemd.')

def network_check(c):
    # One A address; reject stray AAAA rather than leave unreliable ACME validation.
    try:
        infos = socket.getaddrinfo(c['vpsDomain'], 443, type=socket.SOCK_STREAM)
    except socket.gaierror:
        raise DeployError('Домен не разрешается в DNS.')
    v4 = {i[4][0] for i in infos if i[0] == socket.AF_INET}
    v6 = {i[4][0] for i in infos if i[0] == socket.AF_INET6}
    if v4 != {c['vpsIp']} or v6:
        raise DeployError('DNS должен содержать единственную A-запись на IP входа; удалите другие A и AAAA.')
    interfaces = json.loads(run(['ip', '-j', '-4', 'addr', 'show']).stdout)
    local = {a['local'] for interface in interfaces for a in interface.get('addr_info', [])}
    if not {c['vpsIp'], c['exitIp']}.issubset(local):
        raise DeployError('IP входа и выхода должны быть назначены этому VPS. NAT VPS в этой версии не поддерживается.')
    if run(['nft', 'list', 'table', 'ip', 'lethe_v060'], check=False).returncode == 0:
        raise DeployError('Таблица lethe_v060 уже существует; требуется проверка предыдущей установки.')

def download_binary(folder):
    archive = folder / 'caddy.tar.xz'
    request = urllib.request.Request(URL, headers={'User-Agent': 'LETHE/' + VERSION})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=60) as response, archive.open('wb') as dest:
        total = 0
        while True:
            data = response.read(1024 * 1024)
            if not data: break
            total += len(data)
            if total > 100 * 1024 * 1024: raise DeployError('Размер загрузки превышает ограничение.')
            digest.update(data); dest.write(data)
    if digest.hexdigest() != SHA256:
        raise DeployError('SHA-256 Caddy не совпал. Установка остановлена.')
    binary = folder / 'caddy'
    with tarfile.open(archive, 'r:xz') as tar:
        member = tar.getmember('caddy-forwardproxy-naive/caddy')
        if not member.isfile() or member.size > 150 * 1024 * 1024: raise DeployError('Неверный архив Caddy.')
        with tar.extractfile(member) as source, binary.open('wb') as out: shutil.copyfileobj(source, out)
    binary.chmod(0o755)
    if b'http.handlers.forward_proxy' not in run([str(binary), 'list-modules']).stdout:
        raise DeployError('В Caddy отсутствует модуль forward_proxy.')
    return binary

def private_write(path, content, mode=0o600):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    os.fchmod(fd, mode)
    with os.fdopen(fd, 'w', encoding='utf-8') as out: out.write(content)

def tls_check(c):
    context = ssl.create_default_context()
    with socket.create_connection((c['vpsIp'], 443), timeout=6) as raw:
        with context.wrap_socket(raw, server_hostname=c['vpsDomain']) as secure:
            secure.sendall(('GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' % c['vpsDomain']).encode())
            data = b''
            while len(data) < 65536:
                part = secure.recv(4096)
                if not part: break
                data += part
            return b'LETHE server ready' in data and b'200 OK' in data.split(b'\r\n', 1)[0]

def curl_quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def proxy_check(c, folder, authenticated):
    path = folder / ('probe-auth.cfg' if authenticated else 'probe-anon.cfg')
    lines = ['silent', 'show-error', 'fail', 'connect-timeout = 10', 'max-time = 25',
             'noproxy = ""', 'proxy = ' + curl_quote('https://' + c['vpsDomain'] + ':443'),
             'resolve = ' + curl_quote(c['vpsDomain'] + ':443:' + c['vpsIp']),
             'url = "https://api.ipify.org"', 'write-out = "\\nLETHE_CONNECT=%{http_connect}"']
    if authenticated: lines.append('proxy-user = ' + curl_quote(c['vpnUser'] + ':' + c['vpnPassword']))
    private_write(path, '\n'.join(lines) + '\n')
    try:
        p = run(['curl', '-q', '--config', str(path)], timeout=35, check=False)
        body, _, code = p.stdout.decode(errors='replace').rpartition('\nLETHE_CONNECT=')
        return p.returncode, body.strip(), code.strip()
    finally:
        path.unlink(missing_ok=True)

def install(c):
    validate(c); os_check()
    current = status()
    if current['status'] != 'absent': return current
    step('Устанавливаю системные зависимости…')
    run(['apt-get', '-o', 'DPkg::Lock::Timeout=120', 'update'], timeout=600)
    run(['apt-get', '-o', 'DPkg::Lock::Timeout=120', 'install', '-y', '--no-install-recommends',
         'ca-certificates', 'curl', 'python3', 'xz-utils', 'iproute2', 'nftables'], timeout=900)
    network_check(c)
    try:
        pwd.getpwnam(SERVICE_USER)
        raise DeployError('Пользователь lethe-caddy уже существует. Автоматическая установка остановлена.')
    except KeyError:
        pass
    # Ownership is tracked; rollback touches only files created by this attempt.
    created = []; user_created = False; success = False; caddy_started = False; egress_started = False
    with tempfile.TemporaryDirectory(prefix='lethe-install-') as temp:
        folder = Path(temp)
        step('Загружаю Caddy/NaiveProxy и проверяю SHA-256…')
        binary = download_binary(folder)
        template = folder / 'Caddyfile'
        private_write(template, caddyfile(c))
        adapted = json.loads(run([str(binary), 'adapt', '--config', str(template), '--adapter', 'caddyfile']).stdout)
        if inject_auth(adapted, c['vpnUser'], c['vpnPassword']) != 1:
            raise DeployError('Неожиданная структура конфигурации Caddy.')
        # Check once more after downloads, before making service changes.
        if status()['status'] != 'absent': raise DeployError('Состояние VPS изменилось во время подготовки. Повторите проверку.')
        try:
            run(['useradd', '--system', '--user-group', '--home-dir', str(STATE), '--no-create-home', '--shell', '/usr/sbin/nologin', SERVICE_USER])
            user_created = True
            account = pwd.getpwnam(SERVICE_USER)
            for path, mode in ((ETC, 0o750), (OPT, 0o755), (WEB, 0o755), (STATE, 0o700)):
                path.mkdir(mode=mode); created.append(path); path.chmod(mode)
            os.chown(ETC, 0, account.pw_gid); os.chown(STATE, account.pw_uid, account.pw_gid)
            shutil.copy2(binary, OPT / 'caddy')
            private_write(ETC / 'config.json', json.dumps(adapted), 0o640)
            os.chown(ETC / 'config.json', 0, account.pw_gid)
            private_write(WEB / 'index.html', '<!doctype html><meta charset="utf-8"><title>Welcome</title><h1>Welcome</h1><!-- LETHE server ready -->\n', 0o644)
            # Validate as the service user, using the service's HOME.
            run(['runuser', '-u', SERVICE_USER, '--', 'env', 'HOME=' + str(STATE),
                 str(OPT / 'caddy'), 'validate', '--config', str(ETC / 'config.json')])
            needs_snat = c['exitIp'] != c['vpsIp']
            if needs_snat:
                private_write(ETC / 'egress.nft', nft_config(account.pw_uid, c['exitIp']))
                run(['nft', '-c', '-f', str(ETC / 'egress.nft')])
                private_write(EGRESS_UNIT, '''[Unit]
Description=LETHE dedicated-user outbound IPv4
After=network-online.target
Wants=network-online.target
Before=lethe-caddy.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/lethe/egress.nft
ExecStop=/usr/sbin/nft delete table ip lethe_v060
[Install]
WantedBy=multi-user.target
''', 0o644); created.append(EGRESS_UNIT)
            unit = '''[Unit]
Description=LETHE Caddy with NaiveProxy
After=network-online.target %s
Wants=network-online.target
%s
[Service]
Type=simple
User=lethe-caddy
Group=lethe-caddy
Environment=HOME=/var/lib/lethe-caddy
WorkingDirectory=/var/lib/lethe-caddy
ExecStart=/opt/lethe/caddy run --config /etc/lethe/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/lethe-caddy
RestrictAddressFamilies=AF_INET AF_UNIX
[Install]
WantedBy=multi-user.target
''' % ('lethe-egress.service' if needs_snat else '', 'Requires=lethe-egress.service' if needs_snat else '')
            private_write(UNIT, unit, 0o644); created.append(UNIT)
            run(['systemctl', 'daemon-reload'])
            if needs_snat:
                egress_started = True
                run(['systemctl', 'enable', '--now', 'lethe-egress.service'])
            step('Запускаю службу и ожидаю публичный TLS-сертификат…')
            caddy_started = True
            run(['systemctl', 'enable', '--now', 'lethe-caddy.service'])
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                try:
                    if tls_check(c): break
                except (OSError, ssl.SSLError): pass
                time.sleep(3)
            else:
                raise DeployError('Сертификат/HTTPS не подтверждён. Проверьте DNS и входящие TCP 80/443 в firewall VPS и панели провайдера.')
            step('Проверяю авторизацию, выходной IP и запрет анонимного прокси…')
            code, address, connect_code = proxy_check(c, folder, True)
            if code != 0 or connect_code != '200' or address != c['exitIp']:
                raise DeployError('Прокси не подтвердил заданный выходной IP. Установка будет отменена.')
            code, _, connect_code = proxy_check(c, folder, False)
            if code == 0 or connect_code not in ('400', '403', '404', '405', '407'):
                raise DeployError('Запрет анонимного прокси не подтверждён ответом HTTP. Установка отменена.')
            private_write(ETC / 'manifest.json', json.dumps({'product': 'LETHE', 'version': VERSION,
                'domain': c['vpsDomain'], 'vpsIp': c['vpsIp'], 'exitIp': c['exitIp'], 'release': RELEASE,
                'verifiedUtc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}))
            success = True
            return status()
        finally:
            if not success:
                step('Откатываю файлы и службы этой попытки…')
                rollback_ok = True
                if caddy_started:
                    p = run(['systemctl', 'disable', '--now', 'lethe-caddy.service'], check=False)
                    rollback_ok = rollback_ok and not active('lethe-caddy.service')
                if egress_started:
                    run(['systemctl', 'disable', '--now', 'lethe-egress.service'], check=False)
                    rollback_ok = rollback_ok and run(['nft', 'list', 'table', 'ip', 'lethe_v060'], check=False).returncode != 0
                if rollback_ok:
                    for path in reversed(created):
                        if path.is_dir(): shutil.rmtree(path)
                        else: path.unlink(missing_ok=True)
                    if user_created:
                        run(['userdel', SERVICE_USER], check=False)
                        run(['groupdel', SERVICE_USER], check=False)
                    run(['systemctl', 'daemon-reload'], check=False)
                else:
                    step('Откат неполный: файлы сохранены для восстановления. Нужна проверка VPS.')

def removal_api():
    return types.SimpleNamespace(DeployError=DeployError, run=run, private_write=private_write, step=step)

def main():
    os.umask(0o077)
    if os.geteuid() != 0: raise DeployError('Нужен root или sudo без пароля.')
    action = sys.argv[1] if len(sys.argv) > 1 else 'status'
    # Shared lock protects two clients from installing concurrently. Read-only status also waits briefly.
    with contextlib.ExitStack() as stack:
        for name in ('/run/lock/lethe-deploy.lock', '/run/lock/https-tunnel-lab.lock'):
            lock = stack.enter_context(open(name, 'a'))
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: raise DeployError('На VPS уже выполняется операция с сервером. Дождитесь завершения.')
        if action == 'status': result = status()
        elif action == 'install':
            request = Path(sys.argv[2])
            try: c = json.loads(request.read_text())
            finally: request.unlink(missing_ok=True)
            result = install(c)
        elif action == 'remove-plan':
            _, result = removal.prepare(removal_api())
        elif action == 'remove':
            request = Path(sys.argv[2])
            try: c = json.loads(request.read_text())
            finally: request.unlink(missing_ok=True)
            result = removal.remove(removal_api(), c)
        else: raise DeployError('Неизвестное действие.')
        emit('result', **result)

if __name__ == '__main__':
    try: main()
    except DeployError as exc:
        emit('result', status='error', installed=False, message=str(exc)); sys.exit(1)
    except Exception as exc:
        emit('result', status='error', installed=False,
             message='Операция не завершена (%s). Проверьте VPS и повторите проверку состояния.' % type(exc).__name__)
        sys.exit(1)
