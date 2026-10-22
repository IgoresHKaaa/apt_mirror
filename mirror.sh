#!/bin/bash
set -euo pipefail
SELF="$(readlink -f "$0")"
cd "$(dirname "$SELF")"

#Настройки
CODENAME="${CODENAME:-noble}"                                   
ARCH="${ARCH:-amd64}"                                           
UPSTREAM="${UPSTREAM:-http://archive.ubuntu.com/ubuntu}"        
COMPONENTS="${COMPONENTS:-main restricted universe multiverse}"
POCKETS="${POCKETS:-$CODENAME $CODENAME-updates $CODENAME-security}"
KEEP="${KEEP:-5}"                                               
KEY_UID="${KEY_UID:-Corp APT Repository <apt@corp.local>}"
PACKAGES_FILE="${PACKAGES_FILE:-./packages.list}"
PUBLIC_DIR="${PUBLIC_DIR:-./data/aptly/public}"
INCOMING_HOST="${INCOMING_HOST:-./incoming}"
INCOMING_CT="${INCOMING_CT:-/incoming}"
UBUNTU_KEYRING="${UBUNTU_KEYRING:-/usr/share/keyrings/ubuntu-archive-keyring.gpg}"
EXEC="${EXEC-docker compose exec -T aptly}"                     

A()   { $EXEC aptly "$@"; }
GPG() { $EXEC gpg --batch "$@"; }
log() { echo "$(date '+%F %T') $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

filter() {
    [ -f "$PACKAGES_FILE" ] || die "нет файла $PACKAGES_FILE"
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PACKAGES_FILE" \
        | grep -v '^$' | paste -sd'|' | sed 's/|/ | /g'
}
published() { A publish list -raw 2>/dev/null | grep -qx "$1 $2"; }   
stamps()    { A snapshot list -raw -sort=time | sed -n 's/^ubuntu-.*-\([0-9]\{8\}-[0-9]\{6\}\)$/\1/p' | sort -u; }
current()   { A publish show "$1" ubuntu 2>/dev/null | awk '/\[snapshot\]/{print $2; exit}'; }

cmd_init() {
    $EXEC sh -c 'mkdir -p /root/.gnupg && chmod 700 /root/.gnupg'
    if ! GPG --list-secret-keys 2>/dev/null | grep -q '^sec'; then
        log "Создаю ключ подписи: $KEY_UID"
        GPG --pinentry-mode loopback --passphrase '' --quick-gen-key "$KEY_UID" rsa4096 sign never
    fi
    log "Доверяю ключу архива Ubuntu"
    GPG --no-default-keyring --keyring trustedkeys.gpg --import "$UBUNTU_KEYRING"

    if ! A repo show internal >/dev/null 2>&1; then
        A repo create -distribution="$CODENAME" -component=main internal
    fi
    if ! published internal "$CODENAME"; then
        A publish repo -batch -architectures="$ARCH" internal internal
    fi
    mkdir -p "$PUBLIC_DIR"
    GPG --export > "$PUBLIC_DIR/corp.gpg"
    log "Готово. Ключ для клиентов: http://<сервер>/corp.gpg"
    log "  docker compose exec aptly gpg --armor --export-secret-keys > corp-secret.asc"
}

sync_mirror() {
    if A mirror show "$1" >/dev/null 2>&1; then
        A mirror edit -filter="$3" -filter-with-deps "$1" >/dev/null
    else
        log "Создаю зеркало $1"
        A mirror create -architectures="$ARCH" -filter="$3" -filter-with-deps \
            "$1" "$UPSTREAM" "$2" $COMPONENTS >/dev/null
    fi
    log "Скачиваю $1"
    A mirror update "$1" >/dev/null
}

cmd_update() {
    local f; f="$(filter)"
    [ -n "$f" ] || die "packages.list пуст"
    log "Фильтр: $f"
    local pf p names=""
    for p in $CODENAME $(echo "$POCKETS" | tr ' ' '\n' | grep -vx "$CODENAME"); do
        pf="$f"
        [ -z "$names" ] || pf="$f | $names"
        sync_mirror "ubuntu-$p" "$p" "$pf"
        if [ "$p" = "$CODENAME" ]; then
            names="$(A mirror show -with-packages "ubuntu-$p" \
                | sed -n '/^Packages:/,$ s/^  \([^_]*\)_.*/\1/p' | sort -u | paste -sd'|' | sed 's/|/ | /g')"
        fi
    done

    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    for p in $POCKETS; do
        local s="ubuntu-$p-$stamp"
        A snapshot create "$s" from mirror "ubuntu-$p" >/dev/null
        if published ubuntu "$p"; then
            A publish switch -batch "$p" ubuntu "$s" >/dev/null
        else
            A publish snapshot -batch -architectures="$ARCH" -component=main -distribution="$p" "$s" ubuntu >/dev/null
        fi
        log "Опубликовано: ubuntu/$p -> $s"
    done
    log "Версия $stamp опубликована"
    cmd_cleanup
}

cmd_status() {
    echo "Опубликовано:"
    for p in $POCKETS; do printf '  ubuntu/%-22s %s\n' "$p" "$(current "$p" || true)"; done
    echo "  internal/$CODENAME"
    echo "Доступные версии (для rollback):"
    stamps | sed 's/^/  /'
    echo "Занято на диске: $(du -sh ./data 2>/dev/null | cut -f1)"
}

cmd_rollback() {
    local stamp="${1:-}"; [ -n "$stamp" ] || die "укажите версию, см. ./mirror.sh status"
    for p in $POCKETS; do
        A snapshot show "ubuntu-$p-$stamp" >/dev/null 2>&1 || die "нет снапшота ubuntu-$p-$stamp"
    done
    for p in $POCKETS; do
        A publish switch -batch "$p" ubuntu "ubuntu-$p-$stamp" >/dev/null
        log "ubuntu/$p -> ubuntu-$p-$stamp"
    done
}

cmd_cleanup() {
    local all n
    all="$(stamps)"; n="$(echo "$all" | grep -c . || true)"
    if [ "$n" -gt "$KEEP" ]; then
        echo "$all" | head -n $((n - KEEP)) | while read -r st; do
            for p in $POCKETS; do A snapshot drop "ubuntu-$p-$st" >/dev/null 2>&1 || true; done
            log "Удалена старая версия $st"
        done
    fi
    A db cleanup >/dev/null
}

cmd_add() {
    [ $# -ge 1 ] || die "укажите .deb файлы"
    mkdir -p "$INCOMING_HOST"
    local f files=()
    for f in "$@"; do
        [ -f "$f" ] || die "нет файла $f"
        [ "$(dirname "$(readlink -f "$f")")" = "$(readlink -f "$INCOMING_HOST")" ] || cp "$f" "$INCOMING_HOST/"
        files+=("$INCOMING_CT/$(basename "$f")")
    done
    A repo add -force-replace internal "${files[@]}"
    A publish update -batch "$CODENAME" internal >/dev/null
    log "internal/$CODENAME обновлён"
}

cmd_remove() {
    [ $# -ge 1 ] || die "укажите пакет, напр. 'myapp (= 1.0)'"
    A repo remove internal "$1"
    A publish update -batch "$CODENAME" internal >/dev/null
    log "internal/$CODENAME обновлён"
}

case "${1:-}" in
    init|update|status|rollback|cleanup|add|remove) c="$1"; shift; "cmd_$c" "$@" ;;
    *) sed -n "2,10p" "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
