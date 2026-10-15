#!/bin/sh
set -eu
# All arguments are generated locally by the signed-in client, never user shell text.
action="$1"
stage="$2"
case "$stage" in /tmp/lethe-*) ;; *) exit 2;; esac
if command -v python3 >/dev/null 2>&1; then
    if [ "$action" = install ]; then exec python3 "$stage/deploy.py" install "$stage/request.json"; fi
    if [ "$action" = remove ]; then exec python3 "$stage/deploy.py" remove "$stage/request.json"; fi
    case "$action" in status|remove-plan) exec python3 "$stage/deploy.py" "$action";; *) exit 2;; esac
fi
case "$action" in remove|remove-plan)
    printf '%s\n' '{"event":"result","status":"error","installed":false,"message":"Для проверки и удаления сервера требуется python3 на VPS."}'
    exit 2;;
esac
if [ "$action" = status ]; then
    for path in /etc/lethe /opt/lethe /var/www/lethe /var/lib/lethe-caddy /var/lib/lethe-removal /opt/https-tunnel-lab /etc/https-tunnel-lab /etc/systemd/system/lethe-caddy.service /etc/systemd/system/lethe-egress.service; do
        if [ -e "$path" ]; then
            printf '%s\n' '{"event":"result","status":"conflict","installed":false,"message":"Есть файлы LETHE; для проверки установите python3 на VPS."}'
            exit 0
        fi
    done
    for unit in caddy.service caddy-naive.service naive.service; do
        if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" = loaded ]; then
            printf '%s\n' '{"event":"result","status":"conflict","installed":false,"message":"Обнаружен существующий сервер; нужна проверка VPS."}'
            exit 0
        fi
    done
    if awk 'NR>1 && $4=="0A" && $2 ~ /:(0050|01BB)$/ {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6; then
        printf '%s\n' '{"event":"result","status":"conflict","installed":false,"message":"Порт 80/443 занят. Установка заблокирована."}'
    else
        printf '%s\n' '{"event":"result","status":"absent","installed":false,"message":"Сервер не обнаружен. Python3 будет установлен автоматически."}'
    fi
    exit 0
fi
[ "$action" = install ] || exit 2
. /etc/os-release
case "$ID:$VERSION_ID" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;; *) exit 43;; esac
[ "$(uname -m)" = x86_64 ] || exit 44
printf '%s\n' '{"event":"progress","message":"Устанавливаю Python3 для развёртывания…"}'
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=120 update >/dev/null 2>&1
apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends python3 ca-certificates >/dev/null 2>&1
exec python3 "$stage/deploy.py" install "$stage/request.json"
