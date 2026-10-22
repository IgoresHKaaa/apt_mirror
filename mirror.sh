#!/bin/bash
# Управление зеркалом Ubuntu на aptly (только пакеты из packages.list).
#
#   ./mirror.sh init                 — первый запуск: ключ подписи, доверие к ключу Ubuntu, репозиторий своих пакетов
#   ./mirror.sh update               — скачать обновления по packages.list и опубликовать
#   ./mirror.sh status               — что опубликовано и какие версии (снапшоты) есть
#   ./mirror.sh rollback <версия>    — откатить зеркало на версию из status
#   ./mirror.sh add <файл.deb>...    — добавить свои пакеты в /internal
#   ./mirror.sh remove '<пакет>'     — убрать свой пакет, напр. 'myapp (= 1.0)'
#   ./mirror.sh cleanup              — удалить старые версии (делается и после update)
set -euo pipefail
SELF="$(readlink -f "$0")"
cd "$(dirname "$SELF")"

# ---------- Настройки ----------
CODENAME="${CODENAME:-noble}"                                   # Ubuntu 24.04
ARCH="${ARCH:-amd64}"                                           # amd64 или arm64
UPSTREAM="${UPSTREAM:-http://mirror.yandex.ru/ubuntu}"          # или http://archive.ubuntu.com/ubuntu; для arm64: http://ports.ubuntu.com/ubuntu-ports
COMPONENTS="${COMPONENTS:-main restricted universe multiverse}"
POCKETS="${POCKETS:-$CODENAME $CODENAME-updates $CODENAME-security}"
KEEP="${KEEP:-5}"                                               # сколько версий хранить
STALL_SEC="${STALL_SEC:-600}"                                   # нет новых загрузок столько секунд — считаем, что зависло
MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"                              # сколько раз докачивать после зависания
DL_THREADS="${DL_THREADS:-1}"                                   # потоков скачивания (1 — надёжнее на нестабильном канале)
KEY_UID="${KEY_UID:-Corp APT Repository <apt@corp.local>}"
PACKAGES_FILE="${PACKAGES_FILE:-./packages.list}"
# Пути: на хосте и внутри контейнера
PUBLIC_DIR="${PUBLIC_DIR:-./data/aptly/public}"
INCOMING_HOST="${INCOMING_HOST:-./incoming}"
INCOMING_CT="${INCOMING_CT:-/incoming}"
UBUNTU_KEYRING="${UBUNTU_KEYRING:-/usr/share/keyrings/ubuntu-archive-keyring.gpg}"
EXEC="${EXEC-docker compose exec -T aptly}"                     # как запускать команды в контейнере
# --------------------------------

# Конфиг aptly лежит в ./data/aptly (в томе), поэтому настройки переживают пересоздание контейнера
APTLY_CONF_HOST="${APTLY_CONF_HOST:-./data/aptly/aptly.conf}"
APTLY_CONF_CT="${APTLY_CONF_CT:-/root/.aptly/aptly.conf}"
write_conf() {
    [ -n "$EXEC" ] || return 0
    mkdir -p "$(dirname "$APTLY_CONF_HOST")"
    cat > "$APTLY_CONF_HOST" <<EOF
{
    "rootDir": "/root/.aptly",
    "downloadConcurrency": $DL_THREADS,
    "gpgProvider": "gpg",
    "architectures": []
}
EOF
}
if [ -n "$EXEC" ]; then
    A() { $EXEC aptly -config="$APTLY_CONF_CT" "$@"; }
else
    A() { aptly "$@"; }
fi
GPG() { $EXEC gpg --batch "$@"; }
log() { echo "$(date '+%F %T') $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

filter() {
    [ -f "$PACKAGES_FILE" ] || die "нет файла $PACKAGES_FILE"
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PACKAGES_FILE" \
        | grep -v '^$' | paste -sd'|' | sed 's/|/ | /g'
}
published() { A publish list -raw 2>/dev/null | grep -qx "$1 $2"; }   # prefix dist
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
    log "Сохраните секретный ключ в надёжное место:"
    log "  docker compose exec aptly gpg --armor --export-secret-keys > corp-secret.asc"
}

create_mirror() {   # $1=имя зеркала $2=карман $3=фильтр
    log "Создаю зеркало $1"
    # shellcheck disable=SC2086
    A mirror create -architectures="$ARCH" -filter="$3" -filter-with-deps \
        "$1" "$UPSTREAM" "$2" $COMPONENTS >/dev/null
}

sync_mirror() {   # $1=имя зеркала $2=карман $3=фильтр
    if A mirror show "$1" >/dev/null 2>&1; then
        local err
        if ! err="$(A mirror edit -filter="$3" -filter-with-deps "$1" 2>&1 >/dev/null)"; then
            if grep -q "locked" <<<"$err"; then
                # Блокировка осталась от убитого запуска (процесса уже нет — kill_stale это проверил).
                # Зеркало — только описание источника; снапшоты и опубликованные версии от него не зависят.
                log "$1: осталась блокировка от прерванного запуска — пересоздаю зеркало"
                A mirror drop -force "$1" >/dev/null
                create_mirror "$1" "$2" "$3"
            else
                die "$1: $err"
            fi
        fi
    else
        create_mirror "$1" "$2" "$3"
    fi
    update_with_watchdog "$1"
}

# Мягко остановить aptly (SIGINT): уже скачанные файлы сохраняются, следующий запуск докачает остаток.
# Убийство (SIGKILL, в т.ч. docker compose restart) выбрасывает весь прогресс — его избегаем.
stop_aptly() {   # $1 = шаблон командной строки
    pkill -INT -f "$1" 2>/dev/null || return 0
    for _ in $(seq 1 60); do pgrep -f "$1" >/dev/null || return 0; sleep 1; done
    log "aptly не остановился за минуту — принудительно"
    pkill -KILL -f "$1" 2>/dev/null || true
}

# aptly иногда бесконечно ждёт «замершее» соединение. Если STALL_SEC нет новых строк в выводе,
# прерываем мягко и запускаем докачку — до MAX_ATTEMPTS раз.
update_with_watchdog() {   # $1 = имя зеркала
    local m="$1" attempt=1 out pid rc size last_size last_change
    out="$(mktemp)"
    while :; do
        log "Скачиваю $m (попытка $attempt/$MAX_ATTEMPTS)"
        : > "$out"
        # -force: снять блокировку, оставшуюся от прерванного запуска (параллельные запуски исключает flock)
        A mirror update -force -max-tries=5 "$m" > "$out" 2>&1 &
        pid=$!
        tail -n +1 -f --pid="$pid" "$out" &
        last_size=0; last_change=$(date +%s)
        while kill -0 "$pid" 2>/dev/null; do
            sleep 5
            size=$(stat -c %s "$out")
            if [ "$size" != "$last_size" ]; then
                last_size=$size; last_change=$(date +%s)
            elif [ $(( $(date +%s) - last_change )) -ge "$STALL_SEC" ]; then
                log "Нет прогресса ${STALL_SEC} с — мягко прерываю и докачиваю заново"
                stop_aptly "^aptly .*mirror update -force -max-tries=5 $m\$"
                break
            fi
        done
        rc=0; wait "$pid" || rc=$?
        sleep 1
        if [ "$rc" -eq 0 ] && ! grep -q '^ERROR' "$out"; then
            rm -f "$out"; return 0
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
            rm -f "$out"; die "$m: не удалось скачать за $MAX_ATTEMPTS попыток"
        fi
        sleep 10
    done
}

# Если прошлый запуск был прерван, внутри контейнера мог остаться процесс aptly — мягко его останавливаем.
kill_stale() {
    if pgrep -f "^aptly .*(mirror|publish|snapshot|db) " >/dev/null 2>&1; then
        log "Найден процесс aptly от прошлого запуска — мягко останавливаю"
        stop_aptly "^aptly .*(mirror|publish|snapshot|db) "
    fi
}

cmd_update() {
    exec 9>"$(dirname "$SELF")/.update.lock"
    flock -n 9 || die "update уже выполняется"
    kill_stale
    local f; f="$(filter)"
    [ -n "$f" ] || die "packages.list пуст"
    log "Фильтр: $f"

    # 1) Обновляем все карманы. Если хоть один упал — ничего не публикуем.
    #    Сначала базовый (noble). Для -updates/-security к фильтру добавляем ВСЕ пакеты,
    #    попавшие в базовый вместе с зависимостями, — иначе обновления безопасности
    #    библиотек (зависимостей ваших пакетов) не попадут в зеркало.
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

    # 2) Снапшоты и публикация — все карманы с одной меткой версии
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

write_conf

case "${1:-}" in
    init|update|status|rollback|cleanup|add|remove) c="$1"; shift; "cmd_$c" "$@" ;;
    *) sed -n "2,10p" "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
