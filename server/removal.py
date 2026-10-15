"""Removal of positively identified LETHE installations; no user-supplied paths."""
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat

# HOST_ROOT is changed only by isolated tests, never by CLI arguments or environment.
HOST_ROOT = Path('/')
JOURNAL = '/var/lib/lethe-removal'
LAYOUTS = {
    'lethe': {
        'services': ['lethe-caddy.service', 'lethe-egress.service'],
        'accounts': ['lethe-caddy'],
        'paths': ['/etc/systemd/system/lethe-caddy.service', '/etc/systemd/system/lethe-egress.service',
                  '/etc/systemd/system/lethe-caddy.service.d', '/etc/systemd/system/lethe-egress.service.d',
                  '/var/www/lethe', '/var/lib/lethe-caddy', '/opt/lethe', '/etc/lethe'],
        'markers': ['/etc/lethe/manifest.json', '/etc/lethe/config.json'],
        'description': 'LETHE Caddy/NaiveProxy, сайт, сертификаты, настройки, выделенные правила выхода и учётная запись службы.'
    },
    'legacy': {
        'services': ['https-tunnel-caddy.service', 'https-tunnel-agent.service'],
        'accounts': ['https-tunnel-caddy', 'https-tunnel-agent'],
        'paths': ['/etc/systemd/system/https-tunnel-caddy.service', '/etc/systemd/system/https-tunnel-agent.service',
                  '/etc/systemd/system/https-tunnel-caddy.service.d', '/etc/systemd/system/https-tunnel-agent.service.d',
                  '/usr/local/bin/tunnelctl', '/var/lib/https-tunnel-caddy', '/var/lib/https-tunnel-agent',
                  '/var/lib/https-tunnel-devices', '/var/backups/https-tunnel-lab',
                  '/etc/https-tunnel-lab', '/opt/https-tunnel-lab'],
        'markers': ['/opt/https-tunnel-lab/PROJECT', '/etc/https-tunnel-lab/lab.json'],
        'description': 'HTTPS Tunnel Lab: Caddy, агент мониторинга, история эксперимента, доступы устройств, сертификаты, настройки, резервные копии и учётные записи служб.'
    }
}
for _layout in LAYOUTS.values():
    _layout['links'] = ['/etc/systemd/system/multi-user.target.wants/' + unit for unit in _layout['services']]
    _layout['paths'] = _layout['links'] + _layout['paths']

def path(name):
    return HOST_ROOT / name.lstrip('/')

def exists(p):
    return p.exists() or p.is_symlink()

def fail(d, message):
    raise d.DeployError(message)

def safe_path(d, name, allow_link=False):
    p = path(name)
    for parent in (p, *p.parents):
        if parent == HOST_ROOT: break
        if parent.is_symlink() and not (parent == p and allow_link):
            fail(d, 'Удаление заблокировано: символическая ссылка в служебном пути ' + name)
    if p.is_dir() and not p.is_symlink():
        for root, dirs, _ in os.walk(p, followlinks=False):
            if os.path.ismount(root): fail(d, 'В каталоге проекта обнаружена точка монтирования: ' + name)
    return p

def read_json(d, name):
    p = safe_path(d, name)
    if not p.is_file() or p.stat().st_size > 2 * 1024 * 1024:
        fail(d, 'Не удалось подтвердить принадлежность установки LETHE.')
    return json.loads(p.read_text())

def identity(p):
    s = p.lstat()
    item = {'dev': s.st_dev, 'ino': s.st_ino, 'type': stat.S_IFMT(s.st_mode)}
    if p.is_symlink(): item['link'] = os.readlink(p)
    elif p.is_file(): item['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
    return item

def identify(d):
    state = path(JOURNAL + '/state.json')
    if exists(path(JOURNAL)):
        saved = read_json(d, JOURNAL + '/state.json')
        if saved.get('product') != 'LETHE-removal' or saved.get('kind') not in LAYOUTS:
            fail(d, 'Неизвестный журнал удаления. Требуется проверка VPS.')
        if HOST_ROOT == Path('/') and (state.stat().st_uid != 0 or state.stat().st_mode & 0o077):
            fail(d, 'Неверные права журнала удаления.')
        return saved['kind'], saved['domain'], saved.get('entryIp', ''), saved
    matches = []
    if exists(path('/etc/lethe/manifest.json')):
        m = read_json(d, '/etc/lethe/manifest.json')
        if m.get('product') != 'LETHE': fail(d, 'Маркер установки LETHE не подтверждён.')
        matches.append(('lethe', m.get('domain', ''), m.get('vpsIp', ''), None))
    if exists(path('/opt/https-tunnel-lab/PROJECT')):
        marker = safe_path(d, '/opt/https-tunnel-lab/PROJECT')
        if marker.read_text().strip() != 'HTTPS Tunnel Lab': fail(d, 'Маркер HTTPS Tunnel Lab не подтверждён.')
        m = read_json(d, '/etc/https-tunnel-lab/lab.json')
        matches.append(('legacy', m.get('domain', ''), m.get('experiment_ip', ''), None))
    if len(matches) != 1:
        fail(d, 'Нужно однозначно распознать одну установку LETHE или HTTPS Tunnel Lab. Чужой Caddy автоматически не удаляется.')
    return matches[0]

def check_account(d, name):
    try: account = pwd.getpwnam(name)
    except KeyError: return None
    if account.pw_uid == 0 or account.pw_dir != '/var/lib/' + name or account.pw_shell not in ('/usr/sbin/nologin', '/sbin/nologin', '/bin/false'):
        fail(d, 'Учётная запись ' + name + ' не похожа на служебную учётную запись проекта.')
    if any(p.pw_gid == account.pw_gid and p.pw_name != name for p in pwd.getpwall()):
        fail(d, 'Группа службы используется другой учётной записью.')
    return {'uid': account.pw_uid, 'gid': account.pw_gid, 'home': account.pw_dir}

def prepare(d):
    kind, domain, entry_ip, saved = identify(d)
    if not isinstance(domain, str) or not re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]', domain):
        fail(d, 'В установленном проекте нет корректного домена для подтверждения удаления.')
    layout = LAYOUTS[kind]
    # A working service manager is required; an unavailable D-Bus is not "no services".
    d.run(['systemctl', 'list-units', '--no-legend', '--no-pager'])
    snapshot = {}
    for name in layout['paths'] + layout['markers']:
        p = safe_path(d, name, allow_link=(name == '/usr/local/bin/tunnelctl' or name in layout['links']))
        if exists(p):
            if name == '/usr/local/bin/tunnelctl':
                if not p.is_symlink() or not str(p.resolve()).startswith(str(path('/opt/https-tunnel-lab/devices')) + '/'):
                    fail(d, 'tunnelctl принадлежит другой установке. Удаление остановлено.')
            if name in layout['links']:
                expected = path('/etc/systemd/system/' + p.name)
                if not p.is_symlink() or p.resolve() != expected.resolve():
                    fail(d, 'Ссылка автозапуска принадлежит другой службе: ' + name)
            snapshot[name] = identity(p)
    if saved:
        original = saved.get('snapshot', {})
        if not isinstance(original, dict) or not set(original).issubset(set(layout['paths'] + layout['markers'])):
            fail(d, 'Некорректный состав журнала удаления.')
        for name, current in snapshot.items():
            if original.get(name) != current:
                fail(d, 'После незавершённого удаления изменён путь ' + name + '. Нужна проверка VPS.')
    # Refuse replaced units and any foreign services that use our dedicated accounts.
    for service in layout['services']:
        fragment = d.run(['systemctl', 'show', '-p', 'FragmentPath', '--value', service], check=False).stdout.decode().strip()
        expected = '/etc/systemd/system/' + service
        if fragment and fragment != expected: fail(d, 'Под именем ' + service + ' загружена другая служба.')
        unit = path(expected)
        if unit.is_file():
            text = unit.read_text()
            expected_binary = '/opt/lethe/' if kind == 'lethe' else '/opt/https-tunnel-lab/current/bin/'
            if service != 'lethe-egress.service' and ('ExecStart=' + expected_binary) not in text:
                fail(d, 'Изменён путь запуска службы ' + service + '. Удаление заблокировано.')
            if service == 'lethe-egress.service' and 'lethe_v060' not in text:
                fail(d, 'Не удалось подтвердить принадлежность правил выхода.')
        for drop in path(expected + '.d').glob('*.conf'):
            if re.search(r'^\s*(?:ExecStart|ExecStop|User|Group)\s*=', drop.read_text(), re.M):
                fail(d, 'В дополнительных настройках изменён запуск службы ' + service + '. Удаление требует проверки.')
    accounts = {name: check_account(d, name) for name in layout['accounts']}
    for name in layout['accounts']:
        try:
            group = grp.getgrnam(name)
            if group.gr_mem: fail(d, 'В служебной группе есть дополнительные пользователи: ' + name)
        except KeyError: pass
    for folder in ('/etc/systemd/system', '/usr/lib/systemd/system', '/lib/systemd/system'):
        for unit in path(folder).glob('*.service'):
            if unit.name in layout['services'] or not unit.is_file(): continue
            try: text = unit.read_text()
            except (OSError, UnicodeError): continue
            if any(re.search(r'^\s*(?:User|Group)\s*=\s*' + re.escape(user) + r'\s*$', text, re.M) for user in layout['accounts']):
                fail(d, 'Служебную учётную запись LETHE использует другая служба: ' + unit.name)
    nft = False
    if kind == 'lethe' and not shutil.which('nft'):
        fail(d, 'Для проверки и удаления правил выхода требуется nft на VPS. Удаление не начато.')
    if kind == 'lethe' and shutil.which('nft'):
        nft = d.run(['nft', 'list', 'table', 'ip', 'lethe_v060'], check=False).returncode == 0
        rules = path('/etc/lethe/egress.nft')
        if nft and not (saved and saved.get('nft')) and (not rules.is_file() or 'table ip lethe_v060' not in rules.read_text()):
            fail(d, 'Не удалось подтвердить принадлежность таблицы lethe_v060.')
    raw = {'kind': kind, 'domain': domain, 'entryIp': entry_ip, 'snapshot': snapshot, 'accounts': accounts, 'nft': nft}
    token = hashlib.sha256(json.dumps(raw, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return raw, {'status': 'removal_ready', 'installed': True, 'removable': True, 'kind': kind,
                 'domain': domain, 'entryIp': entry_ip, 'planToken': token, 'services': layout['services'],
                 'paths': [x for x in layout['paths'] if x in snapshot], 'accounts': layout['accounts'],
                 'includesMonitoring': kind == 'legacy', 'resuming': saved is not None,
                 'message': layout['description'],
                 'preserved': 'SSH, настройки сети VPS, другие программы и общие системные пакеты сохраняются. Общий журнал ОС не очищается.'}

def write_journal(d, raw):
    folder = safe_path(d, JOURNAL)
    if not folder.exists(): folder.mkdir(mode=0o700)
    folder.chmod(0o700)
    dest = folder / 'state.json'; temp = folder / 'state.tmp'
    if exists(temp): fail(d, 'Остался временный журнал удаления. Требуется проверка VPS.')
    data = dict(raw, product='LETHE-removal')
    d.private_write(temp, json.dumps(data), 0o600)
    os.replace(temp, dest)

def remove(d, request):
    raw, plan = prepare(d)
    if request.get('planToken') != plan['planToken'] or request.get('confirmDomain') != plan['domain']:
        fail(d, 'Подтверждение устарело или не совпало. Заново запросите план удаления сервера.')
    write_journal(d, raw)
    layout = LAYOUTS[raw['kind']]
    d.step('Останавливаю службы проекта и отключаю их автозапуск…')
    for service in layout['services']:
        d.run(['systemctl', 'disable', '--now', service], check=False)
        state = d.run(['systemctl', 'show', '-p', 'ActiveState', '--value', service], check=False).stdout.strip()
        if state not in (b'inactive', b'failed'):
            fail(d, 'Служба ' + service + ' не остановилась. Файлы сохранены; повторите проверку.')
    if raw['nft']:
        d.step('Удаляю выделенную таблицу правил выхода LETHE…')
        d.run(['nft', 'delete', 'table', 'ip', 'lethe_v060'], check=False)
        if d.run(['nft', 'list', 'table', 'ip', 'lethe_v060'], check=False).returncode == 0:
            fail(d, 'Таблица выхода не удалена. Удаление не завершено.')
    d.step('Удаляю файлы, сертификаты, доступы и данные проекта…')
    for name in layout['paths']:
        p = safe_path(d, name, allow_link=(name == '/usr/local/bin/tunnelctl' or name in layout['links']))
        if not exists(p): continue
        if p.is_symlink() or p.is_file(): p.unlink()
        elif p.is_dir(): shutil.rmtree(p)
        else: fail(d, 'Неожиданный тип служебного пути: ' + name)
    d.run(['systemctl', 'daemon-reload'])
    for service in layout['services']:
        d.run(['systemctl', 'reset-failed', service], check=False)
    d.step('Удаляю выделенные учётные записи служб…')
    for name in layout['accounts']:
        if check_account(d, name) is not None: d.run(['userdel', name])
        try: grp.getgrnam(name)
        except KeyError: continue
        d.run(['groupdel', name])
    # Success is reported only after independent postconditions, never just an rm exit code.
    for name in layout['paths']:
        if exists(path(name)): fail(d, 'Не удалён путь ' + name)
    for name in layout['accounts']:
        try: pwd.getpwnam(name)
        except KeyError: pass
        else: fail(d, 'Служебная учётная запись не удалена: ' + name)
        try: grp.getgrnam(name)
        except KeyError: pass
        else: fail(d, 'Служебная группа не удалена: ' + name)
    for service in layout['services']:
        state = d.run(['systemctl', 'show', '-p', 'LoadState', '--value', service], check=False).stdout.strip()
        if state != b'not-found': fail(d, 'Отсутствие службы не подтверждено: ' + service)
    if raw['kind'] == 'lethe' and shutil.which('nft') and d.run(['nft', 'list', 'table', 'ip', 'lethe_v060'], check=False).returncode == 0:
        fail(d, 'Правила выхода всё ещё существуют.')
    (path(JOURNAL) / 'state.json').unlink(); path(JOURNAL).rmdir()
    return {'status': 'removed', 'installed': False, 'removable': False, 'domain': raw['domain'],
            'message': 'Сервер удалён. Службы, файлы, сертификаты, доступы и данные проекта удалены; результат проверен.'}
