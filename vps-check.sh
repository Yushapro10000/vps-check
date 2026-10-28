#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки.
# 16 пунктов в пяти группах: machine (1-5), net (6-9), sec (10-11), ru (12-13), ip (14-16).
# Запуск:
#   bash vps-check.sh                      -> общий прогон: все 16 пунктов; всё нужное скрипт спросит перед стартом
#   bash vps-check.sh net                  -> только группа «Сеть» (6-9); группы: machine, net, sec, ru, ip
#   bash vps-check.sh sec,ru               -> несколько групп; можно смешивать с номерами: net,11
#   bash vps-check.sh 3                    -> только пункт 3
#   bash vps-check.sh 2,4,6-9              -> пункты 2, 4, 6, 7, 8, 9
#   bash vps-check.sh 11 example.com       -> SSL-проверка домена (без домена скрипт спросит его сам)
#   bash vps-check.sh -o report.txt        -> сохранить чистый TXT отчёт (без -o/-m скрипт спросит про отчёт)
#   bash vps-check.sh -m report.md         -> сгенерировать форматированный Markdown
#   bash vps-check.sh -y 10                -> без вопросов (tmux, cron)
#   bash vps-check.sh menu                 -> список пунктов и групп
# Без скачивания — аргументы после скобки:
#   bash <(curl -sL https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh) net
# Код возврата: 0 — все пункты прошли, 1 — хотя бы один пункт с ошибкой или неверные аргументы,
#               130 — прогон прерван по Ctrl+C (отчёты всё равно сохраняются)

MIN_ITEM=1
MAX_ITEM=16

# Общий прогон (без аргументов, 0, all, все) — все пункты по порядку групп
DEFAULT_ITEMS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16"

# Всё временное (скачанные скрипты, сырой лог, Ookla CLI, сводка) живёт в одной папке WORKDIR.
# Она создаётся до запуска проверок и удаляется целиком при выходе, в том числе по Ctrl+C.
WORKDIR=""
TEMP_RAW=""
SUMMARY_FILE=""
NO_PROMPT=0
INTERRUPTED=0
INTERRUPTED_ITEM=""
FAILED=0
STOP=0
SELECTED_ITEMS=""
# Пункты, которые пользователь отказался запускать (или для которых не хватило данных), и причина — для сводки
declare -A SKIP_REASON=()
# Ответы на вопросы про fail2ban, заданные перед стартом: y / n / пусто (тогда пункт 10 спросит сам)
F2B_INSTALL_ANS=""
F2B_START_ANS=""

# Версия официального Speedtest CLI от Ookla (пункты 6 и 7). Если ссылка на скачивание
# перестала работать — проверь актуальную версию на https://www.speedtest.net/apps/cli
# Переопределить без правки файла: OOKLA_VERSION=1.2.0 bash vps-check.sh 6
OOKLA_VERSION="${OOKLA_VERSION:-1.2.0}"

# Города для пункта 7 (Ookla до РФ): через запятую, по-английски, как в базе speedtest.net.
# Через | — запасные написания одного города: если по первому серверов не нашлось, ищется следующее.
# Свои города без правки файла: OOKLA_RU_CITIES="Moscow,Kazan" bash vps-check.sh 7
OOKLA_RU_CITIES="${OOKLA_RU_CITIES:-Moscow,Saint Petersburg|St Petersburg|Petersburg,Yekaterinburg|Ekaterinburg,Novosibirsk}"

# ---------- разбор флагов вывода (-o / -m) в любой позиции ----------
OUTPUT_TXT=""
OUTPUT_MD=""
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)
      if [ -z "${2:-}" ]; then
        echo "Флагу -o/--output нужно имя файла: bash vps-check.sh -o report.txt" >&2
        exit 1
      fi
      OUTPUT_TXT="$2"
      shift 2
      ;;
    -m|--md|--markdown)
      if [ -z "${2:-}" ]; then
        echo "Флагу -m/--markdown нужно имя файла: bash vps-check.sh -m report.md" >&2
        exit 1
      fi
      OUTPUT_MD="$2"
      shift 2
      ;;
    -y|--yes|--no-prompt)
      NO_PROMPT=1
      shift
      ;;
    vps-check|vps-check.sh)
      # bash <(curl ...) vps-check 3-5: слово vps-check перед пунктами — по привычке от установленной команды
      if [ "${#ARGS[@]}" -eq 0 ]; then
        shift
      else
        ARGS+=("$1")
        shift
      fi
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]}"

if [ -n "$OUTPUT_TXT" ] && [ "$OUTPUT_TXT" = "$OUTPUT_MD" ]; then
  echo "Флаги -o и -m указывают на один и тот же файл ($OUTPUT_TXT) — второй отчёт затёр бы первый. Укажи разные имена." >&2
  exit 1
fi

if [ "${#ARGS[@]}" -gt 2 ]; then
  echo "Слишком много аргументов. Несколько пунктов и групп задаются через запятую (3,5,net), второй аргумент — только домен для пункта 11." >&2
  exit 1
fi

ARG="${1:-}"
TARGET_DOMAIN="${2:-}"

# ---------- утилиты очистки и безопасной загрузки ----------
strip_ansi() {
  # printf вместо \x1b и \r: работает и в busybox/BSD sed. LC_ALL=C — побайтовая обработка:
  # шаблоны чисто ASCII, а кириллица проходит без изменений и не ломает диапазоны в [].
  # Вырезается: OSC (заголовок окна, гиперссылки \e]8;;) с концом BEL или ESC \, любые CSI —
  # и цвета, и приватные режимы вроде \e[?25l (спрятать курсор), смена кодировки \e(B, \e=, \e>, \e7/\e8, \r.
  local esc cr bel
  esc=$(printf '\033')
  cr=$(printf '\r')
  bel=$(printf '\007')
  LC_ALL=C sed \
    -e "s|${esc}][^${bel}${esc}]*${bel}||g" \
    -e "s|${esc}][^${bel}${esc}]*${esc}\\\\||g" \
    -e "s|${esc}\[[0-9;:?<=>]*[ -/]*[@-~]||g" \
    -e "s|${esc}[()][A-Za-z0-9]||g" \
    -e "s|${esc}[=>78]||g" \
    -e "s|${cr}||g"
}

fetch_run() {
  local label="$1"
  local url="$2"
  shift 2

  local tmp
  tmp=$(mktemp "${WORKDIR:-${TMPDIR:-/tmp}}/run-XXXXXX.sh") || {
    echo "[!] Не удалось создать временный файл для \"$label\"" >&2
    return 1
  }

  # Качаем сразу в файл (не через переменную bash): так скрипт сохраняется байт в байт.
  # Текст ошибки curl/wget сохраняем: голое «не удалось скачать» не объясняет, что именно сломалось
  local ok=0 err="" werr hint
  if command -v curl >/dev/null; then
    err=$(curl -fsSL --connect-timeout 5 --max-time 30 -o "$tmp" "$url" 2>&1) && ok=1
  fi
  # wget — запасной вариант на случай, когда curl нет или он не справился с HTTPS. Если curl не достучался
  # до сайта (DNS, соединение, таймаут) или сервер ответил ошибкой HTTP (404, 403 — код 22), wget получит
  # то же самое — не тратим на него время.
  # --tries=2: по умолчанию wget делает до 20 попыток, и на молчащем сайте пункт висел бы минутами
  local try_wget=1
  case "$err" in *"(6)"*|*"(7)"*|*"(22)"*|*"(28)"*) try_wget=0 ;; esac
  if [ "$ok" -eq 0 ] && [ "$try_wget" -eq 1 ] && command -v wget >/dev/null; then
    if werr=$(wget -nv --tries=2 -O "$tmp" --timeout=30 "$url" 2>&1); then
      ok=1
    elif [ -z "$err" ]; then
      err=$(printf '%s\n' "$werr" | tail -1)
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    [ -z "$err" ] && err="нет ни curl, ни wget"
    # Сначала коды curl, потом 404: в тексте таймаута бывает «after 5404 ms»
    case "$err" in
      *"(6)"*|*resolve*) hint="домен не находится в DNS — сайт, скорее всего, закрылся (или на VPS сломан DNS)" ;;
      *"(7)"*|*refused*) hint="сайт не принимает соединения — он выключен или не пускает этот сервер" ;;
      *"(28)"*|*"timed out"*) hint="сайт не ответил вовремя — он не работает или не пускает этот сервер (например, закрыт для зарубежных IP)" ;;
      *"(35)"*|*"(60)"*|*SSL*|*certificate*) hint="проблема с HTTPS-сертификатом сайта" ;;
      *404*) hint="по ссылке нет файла (404) — скрипт переехал или удалён" ;;
      *403*) hint="доступ к файлу закрыт (403) — автор удалил его или закрыл хранилище" ;;
      *"(22)"*|*"ERROR "[0-9]*) hint="сервер ответил ошибкой HTTP" ;;
      *) hint="сайт недоступен" ;;
    esac
    echo "[!] Не удалось скачать скрипт для \"$label\" ($url): $hint."
    echo "    Ошибка: $err"
    rm -f "$tmp"
    [ -n "${WORKDIR:-}" ] && : > "$WORKDIR/fetch_failed"   # причина уже названа — run() не добавит общую фразу
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    echo "[!] Скрипт для \"$label\" ($url) скачался пустым: сервер ответил пустой страницей — похоже, скрипта там больше нет."
    rm -f "$tmp"
    [ -n "${WORKDIR:-}" ] && : > "$WORKDIR/fetch_failed"   # причина уже названа — run() не добавит общую фразу
    return 1
  fi

  # Вместо скрипта мог прийти HTML/XML (лендинг, страница ошибки, ответ S3-хранилища) — не передаём его в bash
  # (скрипт не может начинаться с "<", а HTML/XML — всегда)
  if [ "$(head -c 200 "$tmp" | LC_ALL=C tr -d ' \t\r\n' | head -c 1)" = "<" ]; then
    # Ошибка S3-хранилища выглядит как <Error><Code>AccessDenied</Code>...: достаём код
    local s3code
    s3code=$(head -c 4000 "$tmp" | tr -d '\r\n' | sed -n 's/.*<Code>\([^<]*\)<\/Code>.*/\1/p')
    case "$s3code" in
      "") echo "[!] По ссылке вернулась веб-страница (HTML/XML), а не скрипт ($url) — проверь, что это прямая ссылка на скрипт." ;;
      AccessDenied) echo "[!] Хранилище ответило AccessDenied ($url) — автор удалил файл или закрыл к нему доступ. Это не проблема твоего VPS." ;;
      NoSuchKey) echo "[!] Хранилище ответило NoSuchKey ($url) — файла по этой ссылке больше нет." ;;
      NoSuchBucket) echo "[!] Хранилище ответило NoSuchBucket ($url) — самого хранилища больше нет." ;;
      *) echo "[!] Хранилище ответило ошибкой $s3code ($url) — скрипт по ссылке недоступен." ;;
    esac
    rm -f "$tmp"
    [ -n "${WORKDIR:-}" ] && : > "$WORKDIR/fetch_failed"   # причина уже названа — run() не добавит общую фразу
    return 1
  fi

  bash "$tmp" "$@"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

# $1 — заголовок, $2 — команда; дальше (необязательно) — утилиты, без которых сторонний скрипт не стартует.
# Недостающие ставятся заранее, а если поставить не вышло — пункт пропускается с понятным сообщением.
run() {
  local title="$1" cmd="$2"
  shift 2
  echo -e "\n########## $title ##########\n"
  if [ $# -gt 0 ] && ! ensure_cmds "$@"; then
    mark_skipped
    return 0
  fi
  [ -n "${WORKDIR:-}" ] && rm -f "$WORKDIR/fetch_failed"
  bash -c "set -o pipefail; $cmd"
  local rc=$? explained=0
  if [ -n "${WORKDIR:-}" ] && [ -e "$WORKDIR/fetch_failed" ]; then
    explained=1
    rm -f "$WORKDIR/fetch_failed"
  fi
  if [ "$rc" -ne 0 ] && [ "$explained" -eq 0 ]; then
    echo "[!] Пункт \"$title\" завершился с ошибкой (код $rc) — сеть моргнула, источник недоступен, или что-то ещё пошло не так. Часть данных выше может отсутствовать."
  fi
  return "$rc"
}

pkg_install() {
  local pkgs=("$@")
  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null; then
      sudo_cmd="sudo"
    else
      echo "[!] Нет root и нет sudo — установить '${pkgs[*]}' невозможно." >&2
      return 1
    fi
  fi

  if command -v apt-get >/dev/null; then
    # На свежем VPS в первые минуты apt занят unattended-upgrades (или cloud-init):
    # ждём освобождения блокировки, а не падаем с "Could not get lock".
    # apt-get, а не apt: у apt нестабильный CLI, и в скриптах он пишет WARNING в вывод.
    local try out updated=0
    for try in 1 2 3 4 5 6; do
      if out=$($sudo_cmd apt-get -o DPkg::Lock::Timeout=120 update -qq 2>&1); then
        updated=1
        break
      fi
      if printf '%s\n' "$out" | grep -qi "lock"; then
        [ "$try" -eq 1 ] && echo "[i] apt занят другим процессом (на свежем VPS это обычно автообновления) — жду до минуты..."
        sleep 10
        continue
      fi
      break
    done
    [ "$updated" -eq 0 ] && echo "[i] apt-get update не удался (нет сети до зеркал или apt всё ещё занят) — пробую установить без обновления индексов."
    # env внутри sudo: так DEBIAN_FRONTEND доходит до apt, даже если sudo сбрасывает окружение
    $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -q "${pkgs[@]}"
  elif command -v dnf >/dev/null; then
    $sudo_cmd dnf makecache -q 2>/dev/null
    $sudo_cmd dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null; then
    $sudo_cmd yum makecache -q 2>/dev/null
    $sudo_cmd yum install -y "${pkgs[@]}"
  elif command -v apk >/dev/null; then
    $sudo_cmd apk add --no-cache "${pkgs[@]}"
  elif command -v pacman >/dev/null; then
    $sudo_cmd pacman -S --noconfirm "${pkgs[@]}"
  else
    echo "Не нашёл apt/dnf/yum/apk/pacman — поставь '${pkgs[*]}' вручную для своего дистрибутива."
    return 1
  fi
}

# timeout, который не ломает Ctrl+C. Обычный coreutils timeout уводит команду в отдельную группу
# процессов: Ctrl+C до неё не доходит, и прогон продолжается. --foreground оставляет её в группе терминала.
run_with_timeout() {
  local secs="$1"
  shift
  if timeout --foreground 1 true >/dev/null 2>&1; then
    timeout --foreground "$secs" "$@"
  elif command -v timeout >/dev/null; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# Установка без простыни лога пакетного менеджера в отчёте: при успехе — одна строка, при сбое — хвост лога
pkg_install_quiet() {
  local out rc
  echo "Устанавливаю $* (может занять пару минут)..."
  out=$(pkg_install "$@" </dev/null 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -15
    echo "[!] Не удалось установить $*."
    return "$rc"
  fi
  if [ $# -eq 1 ]; then
    echo "Пакет $1 установлен."
  else
    echo "Пакеты установлены: $*."
  fi
}

# Пакет, в котором лежит команда: у ping имя пакета разное в разных дистрибутивах
pkg_for_cmd() {
  case "$1" in
    ping) if command -v apt-get >/dev/null; then echo "iputils-ping"; else echo "iputils"; fi ;;
    *) echo "$1" ;;
  esac
}

# Ставит недостающие команды одной установкой. 0 — всё на месте, 1 — чего-то так и нет
ensure_cmds() {
  local cmd pkgs=() still=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || pkgs+=("$(pkg_for_cmd "$cmd")")
  done
  [ ${#pkgs[@]} -eq 0 ] && return 0
  echo "Для этого пункта нужны: $* — недостающее ставлю."
  pkg_install_quiet "${pkgs[@]}"
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || still+=("$cmd")
  done
  if [ ${#still[@]} -gt 0 ]; then
    echo "[!] Так и нет: ${still[*]} — без них сторонний скрипт не запустится, пункт пропущен."
    return 1
  fi
}

# Экспорт нужен только функциям, которые вызываются внутри `bash -c` из run()
export -f fetch_run
export -f strip_ansi

menu() {
  cat <<'EOF'
Машина (machine): CPU, память, диск
  1)  YABS             - диск (fio), сеть (iperf3, зарубеж) и Geekbench; если в запуске есть 4, Geekbench идёт там
  2)  Bench.sh         - CPU/диск, компактный вывод (teddysun)
  3)  sysbench CPU     - CPU в 1 поток и во все vCPU, сравнение (признак оверселлинга)
  4)  Geekbench        - только Geekbench, для сравнения CPU между хостерами (5-10 минут)
  5)  Disk & FS        - свободное место, inode, swap, ошибки файловой системы
Сеть (net): скорость и исходящие порты
  6)  Ookla Speedtest  - скорость и пинг до ближайшего сервера Speedtest.net
  7)  Ookla до РФ      - Ookla до серверов в Москве, Петербурге, Екатеринбурге, Новосибирске
  8)  iperf3 до РФ     - iperf3 до городов РФ (itdoginfo)
  9)  Nmap outbound    - не режет ли хостер исходящие порты (SMTP, DNS/DoT)
Безопасность (sec)
  10) Security Audit   - SSH, firewall, Docker, fail2ban/CrowdSec, автообновления, опасные порты + оценка
  11) SSL Check        - сертификат домена: срок, цепочка доверия (домен спросит, если не указан)
Доступность из РФ (ru)
  12) Globalping       - доступен ли ЭТОТ сервер с проверочных нод в РФ (ping + mtr)
  13) Censorcheck DPI  - DNS-резолверы (DoH/DoT) и доступность сайтов, DPI-блокировки
IP и сервисы (ip)
  14) IP Quality       - ASN, risk score, доступность сервисов, блэклисты (check.place)
  15) Geolocation      - в какой стране тебя видят сервисы (ipregion)
  16) Censorcheck geo  - не банит ли зарубежный сервис сам IP по гео (в отличие от 13 — DPI РФ)
0)  Общий прогон — все пункты по порядку (то же без аргументов, all или все)

Запуск:
  bash vps-check.sh net               -> группа целиком; несколько групп: sec,ru; вместе с номерами: net,11
  bash vps-check.sh 2,4,6-9           -> отдельные пункты и диапазоны
  bash vps-check.sh 11 example.com    -> SSL-проверка домена
Без скачивания — аргументы после скобки:
  bash <(curl -sL https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh) net
Перед стартом скрипт сразу спрашивает всё нужное (домен для SSL, согласие на Ookla, fail2ban, отчёт) —
дальше проверки идут без остановок, можно отойти.
Отчёты пишутся после всех проверок (без флагов скрипт спросит сам):
  -o report.txt  -> чистый текст        -m report.md  -> Markdown с таблицей-сводкой; можно оба
Без вопросов (tmux, cron): -y — домен для 11 тогда передавай аргументом, fail2ban не ставится
Ookla (6): конкретный сервер — OOKLA_SERVER_ID=<id> bash vps-check.sh 6 (список ближайших: speedtest -L)
Ookla до РФ (7): свои города — OOKLA_RU_CITIES="Moscow,Kazan" bash vps-check.sh 7
Вручную, без установки: Telegram-боты @dpi_checker_robot (DPI-блокировки) и @bschekbot (доступность и баны) —
проверяют доступность с территории РФ
EOF
}

# ---------- пункты: номер → группа, функция, имя ----------
# Группы: machine — сама машина, net — сеть, sec — безопасность, ru — доступность из РФ, ip — IP и сервисы
item_group() {
  case "$1" in
    1|2|3|4|5) echo "machine" ;;
    6|7|8|9) echo "net" ;;
    10|11) echo "sec" ;;
    12|13) echo "ru" ;;
    14|15|16) echo "ip" ;;
  esac
}

group_items() {
  case "$1" in
    machine) echo "1 2 3 4 5" ;;
    net) echo "6 7 8 9" ;;
    sec) echo "10 11" ;;
    ru) echo "12 13" ;;
    ip) echo "14 15 16" ;;
  esac
}

group_title() {
  case "$1" in
    machine) echo "Машина: CPU, память, диск (пункты 1-5)" ;;
    net) echo "Сеть: скорость и исходящие порты (пункты 6-9)" ;;
    sec) echo "Безопасность (пункты 10-11)" ;;
    ru) echo "Доступность из РФ (пункты 12-13)" ;;
    ip) echo "IP и сервисы (пункты 14-16)" ;;
  esac
}

# Имя группы из аргумента — по-английски или по-русски; пусто, если это не группа
group_by_name() {
  case "$1" in
    machine|hw|hardware|машина|Машина|железо) echo "machine" ;;
    net|network|сеть|Сеть) echo "net" ;;
    sec|security|безопасность|Безопасность) echo "sec" ;;
    ru|rf|рф|РФ|россия|Россия) echo "ru" ;;
    ip|IP|services|сервисы|Сервисы) echo "ip" ;;
  esac
}

item_func() {
  case "$1" in
    1) echo "cmd_yabs" ;;
    2) echo "cmd_bench" ;;
    3) echo "cmd_sysbench" ;;
    4) echo "cmd_geekbench" ;;
    5) echo "cmd_disk" ;;
    6) echo "cmd_ookla" ;;
    7) echo "cmd_ookla_ru" ;;
    8) echo "cmd_iperf_ru" ;;
    9) echo "cmd_nmap" ;;
    10) echo "cmd_audit" ;;
    11) echo "cmd_ssl" ;;
    12) echo "cmd_globalping" ;;
    13) echo "cmd_censor_dpi" ;;
    14) echo "cmd_ipquality" ;;
    15) echo "cmd_geo" ;;
    16) echo "cmd_geoblock" ;;
  esac
}

# Короткие имена пунктов для итоговой сводки
item_name() {
  case "$1" in
    1) echo "YABS" ;;
    2) echo "Bench.sh" ;;
    3) echo "sysbench CPU" ;;
    4) echo "Geekbench" ;;
    5) echo "Disk & FS" ;;
    6) echo "Ookla Speedtest" ;;
    7) echo "Ookla до РФ" ;;
    8) echo "iperf3 до РФ" ;;
    9) echo "Nmap outbound" ;;
    10) echo "Security Audit" ;;
    11) echo "SSL Check" ;;
    12) echo "Globalping" ;;
    13) echo "Censorcheck (DPI)" ;;
    14) echo "IP Quality" ;;
    15) echo "Geolocation" ;;
    16) echo "Censorcheck (geoblock)" ;;
    *) echo "Пункт $1" ;;
  esac
}

# Подсказка про Telegram-ботов: независимая проверка с территории РФ, без установки чего-либо на сервер
tg_bots_hint() {
  echo
  echo "[i] Сверить доступность с территории РФ вручную, без установки чего-либо на сервер, можно Telegram-ботами:"
  echo "    @dpi_checker_robot — проверка на DPI-блокировки, @bschekbot — проверка доступности и банов."
}

# YABS: диск (fio), сеть (iperf3) и Geekbench. Если в этом же запуске есть пункт 4, Geekbench отдаётся ему (-g),
# чтобы не гонять один и тот же долгий тест дважды
cmd_yabs() {
  local yabs_args=""
  case " $SELECTED_ITEMS " in
    *" 4 "*) yabs_args="-g" ;;
  esac
  if [ -n "$yabs_args" ]; then
    run "YABS" "echo '(Geekbench в этом запуске идёт отдельным пунктом 4, поэтому здесь YABS запускается без него)'; echo; fetch_run 'YABS' 'https://yabs.sh' $yabs_args"
  else
    run "YABS" "fetch_run 'YABS' 'https://yabs.sh'"
  fi
}
cmd_geekbench() { run "Geekbench (только CPU)" "fetch_run 'Geekbench' 'https://yabs.sh' -f -i"; }
# Скрипт itdoginfo без iperf3, jq, awk и ping сразу выходит с ошибкой — ставим их заранее
cmd_iperf_ru() { run "iperf3 до городов РФ (itdoginfo)" "fetch_run 'iperf3 до РФ' 'https://raw.githubusercontent.com/itdoginfo/russian-iperf3-servers/main/speedtest.sh'" iperf3 jq awk ping; }
cmd_ipquality() { run "IP Quality" "fetch_run 'IP Quality' 'https://ip.check.place' -l en"; }
cmd_geo() { run "Geolocation Check" "fetch_run 'Geolocation' 'https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh'"; }
cmd_censor_dpi() { run "Censorcheck (DPI mode)" "fetch_run 'Censorcheck' 'https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh' --mode dpi"; }
cmd_geoblock() { run "Censorcheck (geoblock mode)" "fetch_run 'Censorcheck geoblock' 'https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh' --mode geoblock --no-dns"; }
cmd_bench() { run "Bench.sh (Teddysun)" "fetch_run 'Bench.sh' 'https://bench.sh'"; }
cmd_sysbench() {
  echo -e "\n########## sysbench CPU ##########\n"
  command -v sysbench >/dev/null || pkg_install_quiet sysbench
  if ! command -v sysbench >/dev/null; then
    echo "[i] sysbench не установлен, тест пропущен (на RHEL-совместимых системах пакет лежит в EPEL)"
    mark_skipped
    return
  fi

  local cores single multi s m ratio
  cores=$(nproc 2>/dev/null || echo 1)

  echo "--- 1 поток ---"
  single=$(sysbench cpu run --threads=1 2>&1)
  echo "$single"
  s=$(echo "$single" | awk '/events per second:/ {print $4}')
  if [ -z "$s" ]; then
    echo
    echo "[!] Не удалось разобрать результат sysbench (1 поток) — многопоточный прогон пропускаю."
    return 1
  fi

  if [ "$cores" -le 1 ]; then
    echo
    echo "vCPU всего один — многопоточный тест не нужен."
    return
  fi

  echo
  echo "--- $cores потоков (по числу vCPU) ---"
  multi=$(sysbench cpu run --threads="$cores" 2>&1)
  echo "$multi"
  m=$(echo "$multi" | awk '/events per second:/ {print $4}')

  echo
  echo "--- Масштабирование ---"
  ratio=""
  if [ -n "$s" ] && [ -n "$m" ]; then
    ratio=$(awk -v s="$s" -v m="$m" 'BEGIN { if (s > 0) printf "%.2f", m / s }')
  fi
  if [ -z "$ratio" ]; then
    echo "[!] Не удалось разобрать events per second из вывода sysbench — сравнить результаты не получилось."
    return 1
  fi
  echo "events/sec: 1 поток = $s, $cores потоков = $m, прирост ×$ratio (идеал ≈ ×$cores)"
  awk -v r="$ratio" -v c="$cores" 'BEGIN {
    e = r / c
    if (e >= 0.85)     print "Масштабирование хорошее: ядра отдают почти полную мощность."
    else if (e >= 0.5) print "Масштабирование ниже идеала: возможно, vCPU — это потоки (SMT) одного ядра или процессор делится с соседями."
    else               print "Масштабирование плохое: похоже на оверселлинг или жёсткий лимит CPU. Повтори тест в другое время суток."
  }'
  echo "(ориентир, а не приговор: результат зависит от SMT и нагрузки соседей по хосту)"
}


cmd_globalping() {
  echo -e "\n########## Globalping (доступность этого сервера из РФ) ##########\n"
  local sudo_cmd="" MY_IP
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo_cmd="sudo"

  if ! command -v globalping >/dev/null; then
    if [ "$(id -u)" -ne 0 ] && [ -z "$sudo_cmd" ]; then
      echo "[i] Запущено не от root и утилита sudo не найдена — автоматическая установка globalping невозможна. Пропускаю пункт."
      mark_skipped
      return
    fi

    # Скрипт packagecloud только подключает репозиторий; сам пакет ставим через pkg_install —
    # там есть ожидание блокировки apt на свежем VPS и понятная ошибка при сбое
    local repo_script=""
    if command -v apt-get >/dev/null; then
      repo_script="script.deb.sh"
    elif command -v dnf >/dev/null; then
      repo_script="script.rpm.sh"
    fi
    if [ -n "$repo_script" ]; then
      if ( set -o pipefail
           curl -fsSL --connect-timeout 5 --max-time 30 \
             "https://packagecloud.io/install/repositories/jsdelivr/globalping/$repo_script" 2>/dev/null \
             | $sudo_cmd bash >/dev/null 2>&1 ); then
        pkg_install_quiet globalping
      else
        echo "[!] Не удалось подключить репозиторий globalping (packagecloud.io недоступен или его скрипт завершился с ошибкой)."
      fi
    elif command -v brew >/dev/null; then
      brew tap jsdelivr/globalping >/dev/null 2>&1
      brew install globalping >/dev/null 2>&1
    else
      echo "Официальных пакетов globalping для этого дистрибутива нет (apt/dnf/brew поддерживаются): https://github.com/jsdelivr/globalping-cli"
    fi
  fi
  if ! command -v globalping >/dev/null; then
    echo "globalping не установлен, пропускаю проверку."
    mark_skipped
    return
  fi

  MY_IP=$(curl -fsSL --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null \
       || curl -fsSL --connect-timeout 4 --max-time 6 https://ifconfig.me 2>/dev/null \
       || curl -fsSL --connect-timeout 4 --max-time 6 https://icanhazip.com 2>/dev/null)

  if [ -z "$MY_IP" ]; then
    echo "[!] Не удалось определить внешний IP этого сервера (проблема с сетью/DNS)."
    return 1
  fi

  echo "Проверяемый IP этого сервера: ${MY_IP}"
  echo
  echo "--- ping с 5 нод в РФ ---"
  globalping ping "$MY_IP" from Russia --limit 5
  echo
  echo "--- mtr с 3 нод в РФ (видно, на каком хопе рвётся) ---"
  globalping mtr "$MY_IP" from Russia --limit 3
}

# ---------- 9. Security Audit: разбор правил firewall ----------
# Реальная фильтрация входящих в выводе `iptables -S INPUT` (stdin): policy DROP или правило DROP/REJECT.
# Смотрим только INPUT: Docker пишет свои ACCEPT в FORWARD/DOCKER, и раньше это выглядело как «firewall есть».
# Правила fail2ban/CrowdSec не считаются: они банят отдельные IP, а не закрывают порты.
fw_iptables_input_active() {
  grep -vE 'f2b-|fail2ban|crowdsec' | grep -qE '^-P INPUT DROP|^-A INPUT .*-j (DROP|REJECT)'
}

# То же для `nft list ruleset` (stdin): цепочка с hook input, где есть policy drop или правило drop/reject.
# Таблицы fail2ban и CrowdSec пропускаются, цепочки Docker висят на hook forward и сюда не попадают.
fw_nft_input_active() {
  awk '
    /^[[:space:]]*table[[:space:]]/ { skip_table = ($0 ~ /f2b|fail2ban|crowdsec/) }
    /^[[:space:]]*chain[[:space:]]/ { in_chain = 1; is_input = 0; next }
    in_chain && /^[[:space:]]*}[[:space:]]*$/ { in_chain = 0; is_input = 0; next }
    in_chain && /hook[[:space:]]+input/ {
      is_input = !skip_table
      if (is_input && /policy[[:space:]]+drop/) found = 1
      next
    }
    in_chain && is_input && /(^|[[:space:]])(drop|reject)([[:space:]]|;|$)/ { found = 1 }
    END { exit !found }
  '
}

# Опасные службы, которые слушают не только на localhost (stdin: вывод `ss -tln`)
risky_listeners() {
  awk 'NR > 1 {
    addr = $4
    port = addr; sub(/.*:/, "", port)
    host = addr; sub(/:[^:]*$/, "", host)
    if (host ~ /(^|\[|:)127\./ || host ~ /^\[?::1\]?$/ || host ~ /%lo$/) next
    name = ""
    if (port == "2375") name = "Docker API без TLS — полный root на сервере"
    else if (port == "3306") name = "MySQL/MariaDB"
    else if (port == "5432") name = "PostgreSQL"
    else if (port == "6379") name = "Redis"
    else if (port == "9200") name = "Elasticsearch"
    else if (port == "11211") name = "Memcached"
    else if (port == "27017") name = "MongoDB"
    if (name != "") print port " — " name " (слушает на " host ")"
  }' | sort -u
}

# ---------- 9. Security Audit ----------
cmd_audit() {
  echo -e "\n########## Security Audit (чтение; установка fail2ban — только по согласию) ##########\n"
  local is_root=0
  [ "$(id -u)" -eq 0 ] && is_root=1
  [ "$is_root" -eq 0 ] && echo "[!] Запущено не от root — ss/dmesg/iptables/nft/fail2ban-client могут отдать урезанный или пустой вывод. Для полной картины: sudo bash vps-check.sh 10"
  echo

  # Все переменные пункта — local. Сейчас run_item и так запускает пункт в отдельном подшелле,
  # но пункт не должен от этого зависеть: если подшелл когда-нибудь уберут, ничего не протечёт.
  # Вложенные функции ниже (deduct, get_ssh, f2b_*) видят эти переменные — в bash область видимости динамическая.
  local SCORE=100 FW_UNVERIFIED=0 FW_ACTIVE=0 BF_OK=0 UPD_OK=0 VERDICT KSTA
  local SSHD_T="" ROOT_LOGIN PASS_AUTH KBD_AUTH USE_PAM AUTH_METHODS SSH_PORT PUBKEY_AUTH EMPTY_PASS
  local EMPTY_PW_USERS RULES NFT_RULES F2B_SUDO="" F2B_HINT=""
  local -a READ_SUDO=() SSHD_FILES=()
  deduct() {
    SCORE=$((SCORE - $1))
    echo "  [-$1] $2"
  }

  # Команды только на чтение без root пробуем через `sudo -n`: без пароля сработает,
  # а с паролем тихо откажет, но не повесит проверку на вопросе
  READ_SUDO=()
  [ "$is_root" -eq 0 ] && command -v sudo >/dev/null && READ_SUDO=(sudo -n)

  echo "=== SSH-конфигурация ==="
  SSHD_FILES=()
  shopt -s nullglob
  [ -d /etc/ssh/sshd_config.d ] && SSHD_FILES+=(/etc/ssh/sshd_config.d/*.conf)
  shopt -u nullglob
  [ -r /etc/ssh/sshd_config ] && SSHD_FILES+=(/etc/ssh/sshd_config)

  # Эффективный конфиг: sshd -T (нужен root). sshd лежит в /usr/sbin — если его нет в PATH, берём полный путь
  local sshd_bin
  SSHD_T=""
  sshd_bin=$(command -v sshd 2>/dev/null)
  [ -z "$sshd_bin" ] && [ -x /usr/sbin/sshd ] && sshd_bin=/usr/sbin/sshd
  [ -n "$sshd_bin" ] && SSHD_T=$("$sshd_bin" -T 2>/dev/null)

  # Значение параметра (в нижнем регистре): из sshd -T, иначе из файлов (до первого Match-блока
  # в каждом файле, первое найденное значение — как у самого sshd). Пусто — параметр не задан.
  # Port бывает несколько — тогда значения через запятую.
  get_ssh() {
    local key="$1"
    if [ -n "$SSHD_T" ]; then
      printf '%s\n' "$SSHD_T" | awk -v k="$key" '
        tolower($1) == tolower(k) { $1 = ""; sub(/^ +/, ""); v = (v == "" ? $0 : v "," $0) }
        END { print tolower(v) }'
    elif [ ${#SSHD_FILES[@]} -gt 0 ]; then
      awk -v k="$key" '
        FNR == 1 { inmatch = 0 }
        tolower($1) == "match" { inmatch = (tolower($2) != "all"); next }
        inmatch { next }
        tolower($1) == tolower(k) {
          $1 = ""; sub(/^ +/, "")
          if (tolower(k) == "port") { v = (v == "" ? $0 : v "," $0); next }
          print tolower($0); found = 1; exit
        }
        END { if (!found && v != "") print v }' "${SSHD_FILES[@]}" 2>/dev/null
    fi
  }

  ROOT_LOGIN=$(get_ssh PermitRootLogin)
  PASS_AUTH=$(get_ssh PasswordAuthentication)
  KBD_AUTH=$(get_ssh KbdInteractiveAuthentication)
  # до OpenSSH 8.7 этот параметр назывался ChallengeResponseAuthentication
  [ -z "$KBD_AUTH" ] && KBD_AUTH=$(get_ssh ChallengeResponseAuthentication)
  USE_PAM=$(get_ssh UsePAM)
  AUTH_METHODS=$(get_ssh AuthenticationMethods)
  SSH_PORT=$(get_ssh Port)
  PUBKEY_AUTH=$(get_ssh PubkeyAuthentication)
  EMPTY_PASS=$(get_ssh PermitEmptyPasswords)

  local ssh_found=1 pw_needs_key=0 list
  if [ -n "$SSHD_T" ]; then
    echo "(эффективные значения из sshd -T)"
  elif [ ${#SSHD_FILES[@]} -gt 0 ]; then
    echo "(sshd -T недоступен — значения из sshd_config и sshd_config.d/*.conf, без учёта Match-блоков)"
  else
    ssh_found=0
    echo "OpenSSH-сервер не найден (нет sshd_config и sshd -T) — SSH-пункты не оцениваются."
  fi
  if [ "$ssh_found" -eq 1 ]; then
    echo "PermitRootLogin:              ${ROOT_LOGIN:-не задано (по умолчанию prohibit-password)}"
    echo "PasswordAuthentication:       ${PASS_AUTH:-не задано (по умолчанию yes)}"
    echo "KbdInteractiveAuthentication: ${KBD_AUTH:-не задано (по умолчанию yes)}"
    echo "UsePAM:                       ${USE_PAM:-не задано (по умолчанию no)}"
    echo "Port:                         ${SSH_PORT:-22 (по умолчанию)}"
    echo "PubkeyAuthentication:         ${PUBKEY_AUTH:-не задано (по умолчанию yes)}"
    echo "PermitEmptyPasswords:         ${EMPTY_PASS:-не задано (по умолчанию no)}"
    if [ -n "$AUTH_METHODS" ] && [ "$AUTH_METHODS" != "any" ]; then
      echo "AuthenticationMethods:        $AUTH_METHODS"
    fi

    case "$ROOT_LOGIN" in
      yes) deduct 20 "root может логиниться по SSH напрямую (PermitRootLogin yes)" ;;
    esac

    # Если AuthenticationMethods в каждом варианте входа требует ключ — один пароль никого не пустит
    if [ -n "$AUTH_METHODS" ] && [ "$AUTH_METHODS" != "any" ]; then
      pw_needs_key=1
      for list in $AUTH_METHODS; do
        case ",$list," in
          *,publickey,*) ;;
          *) pw_needs_key=0 ;;
        esac
      done
    fi
    # Пароль по SSH принимается двумя путями: PasswordAuthentication и keyboard-interactive через PAM
    if [ "$pw_needs_key" -eq 1 ]; then
      echo "  (AuthenticationMethods требует ключ при любом входе — один пароль не пустит)"
    else
      case "$PASS_AUTH" in
        yes|"")
          deduct 20 "разрешён вход по паролю (PasswordAuthentication ${PASS_AUTH:-не задано — по умолчанию yes})"
          ;;
        *)
          if [ "$USE_PAM" = "yes" ] && { [ "$KBD_AUTH" = "yes" ] || [ -z "$KBD_AUTH" ]; }; then
            deduct 20 "пароль всё равно принимается через keyboard-interactive + PAM (KbdInteractiveAuthentication ${KBD_AUTH:-не задано — по умолчанию yes}, UsePAM yes). Поставь KbdInteractiveAuthentication no"
          fi
          ;;
      esac
    fi
    case "$EMPTY_PASS" in
      yes) deduct 20 "разрешён вход по SSH с пустым паролем (PermitEmptyPasswords yes)" ;;
    esac
  fi

  echo
  echo "=== Учётные записи без пароля ==="
  if [ "$is_root" -eq 0 ]; then
    echo "недоступно без root (нужно читать /etc/shadow)"
  elif [ -r /etc/shadow ]; then
    EMPTY_PW_USERS=$(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null)
    if [ -n "$EMPTY_PW_USERS" ]; then
      echo "Найдены учётные записи с пустым паролем (вход без пароля):"
      echo "$EMPTY_PW_USERS" | sed 's/^/  [!] /'
      echo "Закрыть: passwd -l <имя> (заблокировать пароль) или задать пароль через passwd <имя>"
      deduct 20 "есть учётные записи с пустым паролем (вход без пароля с консоли и через su, а при PermitEmptyPasswords yes — и по SSH)"
    else
      echo "Записей с пустым паролем нет."
    fi
  else
    echo "/etc/shadow недоступен для чтения."
  fi

  echo
  echo "=== Firewall ==="
  FW_ACTIVE=0
  if command -v ufw >/dev/null; then
    echo "--- ufw ---"
    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw status verbose 2>/dev/null
      FW_ACTIVE=1
    else
      if [ "$is_root" -eq 0 ]; then
        echo "статус недоступен без root"
      else
        echo "ufw установлен, но неактивен"
      fi
    fi
  fi
  if command -v firewall-cmd >/dev/null; then
    echo "--- firewalld ---"
    if firewall-cmd --state 2>/dev/null | grep -q running; then
      firewall-cmd --list-all 2>/dev/null
      FW_ACTIVE=1
    else
      echo "firewalld установлен, но не запущен"
    fi
  fi
  if command -v iptables >/dev/null && [ "$FW_ACTIVE" -eq 0 ]; then
    echo "--- iptables: цепочка INPUT ---"
    if [ "$is_root" -eq 0 ]; then
      echo "правила недоступны без root"
    else
      RULES=$(iptables -S INPUT 2>/dev/null)
      if [ -n "$RULES" ]; then
        echo "$RULES" | head -40
        if [ "$(echo "$RULES" | wc -l)" -gt 40 ]; then
          echo "... (показаны первые 40 правил)"
        fi
      else
        echo "iptables не отдал правила."
      fi
      if printf '%s\n' "$RULES" | fw_iptables_input_active; then
        FW_ACTIVE=1
      fi
    fi
  fi
  if command -v nft >/dev/null && [ "$FW_ACTIVE" -eq 0 ]; then
    echo "--- nftables ---"
    NFT_RULES=""
    if [ "$is_root" -eq 1 ]; then
      NFT_RULES=$(nft list ruleset 2>/dev/null)
    fi
    if [ "$is_root" -eq 0 ]; then
      echo "ruleset недоступен без root"
    elif [ -n "$NFT_RULES" ]; then
      echo "$NFT_RULES" | head -40
      if [ "$(echo "$NFT_RULES" | wc -l)" -gt 40 ]; then
        echo "... (показаны первые 40 строк ruleset)"
      fi
      if printf '%s\n' "$NFT_RULES" | fw_nft_input_active; then
        FW_ACTIVE=1
      fi
    else
      echo "ruleset пуст (правил нет)."
    fi
  fi
  if [ "$FW_ACTIVE" -eq 0 ]; then
    if [ "$is_root" -eq 0 ]; then
      echo "Состояние firewall не удалось проверить без root (ufw, iptables и nft требуют права) — минус не засчитан. Для точной оценки: sudo bash vps-check.sh 10"
      FW_UNVERIFIED=1
    else
      echo "Активный firewall не обнаружен: ufw/firewalld неактивны, а в INPUT нет ни policy DROP, ни правил DROP/REJECT (правила Docker, fail2ban и CrowdSec firewall'ом не считаются)."
      deduct 25 "нет активного firewall"
    fi
  fi

  # Docker публикует порты через свои правила iptables (NAT + цепочка DOCKER) — в обход INPUT,
  # а значит и в обход ufw/firewalld: «закрытый» в ufw порт контейнера на деле открыт всему интернету
  if command -v docker >/dev/null; then
    echo
    echo "=== Docker и firewall ==="
    local dk_out dk_public
    if ! dk_out=$(docker ps --format '{{.Names}}: {{.Ports}}' 2>/dev/null); then
      if [ "$is_root" -eq 1 ]; then
        echo "Docker установлен, но демон не отвечает (не запущен?) — проверка пропущена."
      else
        echo "docker ps недоступен (нужен root или группа docker) — проверка пропущена."
      fi
    elif [ -z "$dk_out" ]; then
      echo "Запущенных контейнеров нет."
    else
      dk_public=$(printf '%s\n' "$dk_out" | grep -E '0\.0\.0\.0:|\[::\]:|:::[0-9]')
      if [ -z "$dk_public" ]; then
        echo "Контейнеры не публикуют порты на все интерфейсы."
      else
        echo "Порты контейнеров, открытые на все интерфейсы:"
        printf '%s\n' "$dk_public" | sed 's/^/  /'
        if [ "$FW_ACTIVE" -eq 1 ]; then
          echo "[!] Эти порты доступны из интернета, даже если firewall их «закрывает»: Docker обходит ufw/firewalld."
        fi
        echo "Если порт нужен только локально (за nginx/caddy или панелью) — публикуй его как 127.0.0.1:ПОРТ:ПОРТ в docker-compose."
        echo "Если фильтровать нужно именно внешние подключения — правила в цепочке DOCKER-USER (для ufw — утилита ufw-docker)."
      fi
    fi
  fi

  echo
  echo "=== Защита от брутфорса ==="
  BF_OK=0
  local f2b_installed=0 f2b_running=0 cs_installed=0 cs_running=0
  command -v fail2ban-client >/dev/null && f2b_installed=1
  { systemctl is-active --quiet fail2ban 2>/dev/null || pgrep -f fail2ban-server >/dev/null 2>&1; } && f2b_running=1
  command -v cscli >/dev/null && cs_installed=1
  { systemctl is-active --quiet crowdsec 2>/dev/null || pgrep -x crowdsec >/dev/null 2>&1; } && cs_running=1

  F2B_SUDO=""    # префикс для команд установки (с согласия пользователя)
  F2B_HINT=""    # префикс для подсказок пользователю
  if [ "$is_root" -eq 0 ]; then
    if command -v sudo >/dev/null; then
      F2B_SUDO="sudo "
      F2B_HINT="sudo "
    else
      F2B_HINT="(от root) "
    fi
  fi

  # Команда установки для подсказки (сама установка — через pkg_install)
  f2b_install_hint() {
    if command -v apt-get >/dev/null; then echo "${F2B_HINT}apt-get install -y fail2ban"
    elif command -v dnf >/dev/null; then echo "${F2B_HINT}dnf install -y fail2ban (на RHEL-совместимых системах сначала epel-release)"
    elif command -v yum >/dev/null; then echo "${F2B_HINT}yum install -y fail2ban (на RHEL-совместимых системах сначала epel-release)"
    elif command -v apk >/dev/null; then echo "${F2B_HINT}apk add fail2ban"
    elif command -v pacman >/dev/null; then echo "${F2B_HINT}pacman -S fail2ban"
    else echo "установи пакет fail2ban средствами своего дистрибутива"
    fi
  }

  # Есть ли SSH среди jail'ов в выводе `fail2ban-client status` (stdin)
  f2b_has_ssh_jail() {
    sed -nE 's/.*Jail list:[[:space:]]*//p' | grep -qi 'ssh'
  }

  f2b_jail_hint() {
    echo "Добавь в /etc/fail2ban/jail.local:"
    echo "  [sshd]"
    echo "  enabled = true"
    echo "и перезапусти службу: ${F2B_HINT}systemctl restart fail2ban"
  }

  # Вопрос «да/нет» с согласия пользователя. 0 — согласился, 1 — отказался,
  # 2 — нет терминала, 3 — вопросы отключены флагом -y
  # $1 — вопрос, $2 — ответ, данный перед стартом (y/n); если он есть, второй раз не спрашиваем
  f2b_ask() {
    local ans
    case "${2:-}" in
      y) return 0 ;;
      n) return 1 ;;
    esac
    [ -t 0 ] || return 2
    [ "$NO_PROMPT" -eq 1 ] && return 3
    read -rp "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy] ]]
  }

  # Почему ничего не сделано + команда для ручного запуска ($1 — код f2b_ask, $2 — «установка пропущена» и т.п., $3 — команда)
  f2b_skip_msg() {
    case "$1" in
      2) echo "Нет терминала — $2. Вручную: $3" ;;
      3) echo "Флаг -y отключает вопросы — $2. Вручную: $3" ;;
      *) echo "Ок, $2. Вручную: $3" ;;
    esac
  }

  # Запуск службы fail2ban и проверка jail'а для SSH — после установки или для установленной, но остановленной
  f2b_start_and_check() {
    if ! command -v systemctl >/dev/null; then
      echo "systemd не найден — запусти службу fail2ban вручную средствами своей init-системы."
      return
    fi

    # Debian 12+ по умолчанию без rsyslog: /var/log/auth.log нет, и sshd-jail с backend=auto
    # не находит лог — служба не стартует. Тогда читаем журнал systemd.
    if [ ! -e /var/log/auth.log ] && [ ! -e /var/log/secure ] && command -v journalctl >/dev/null \
       && [ -d /etc/fail2ban/jail.d ] && [ ! -e /etc/fail2ban/jail.d/vps-check-sshd.local ]; then
      echo "Файлового журнала SSH нет (система пишет только в journald) — включаю для sshd backend = systemd."
      if command -v dpkg >/dev/null && ! dpkg -s python3-systemd >/dev/null 2>&1; then
        pkg_install_quiet python3-systemd
      fi
      printf '[sshd]\nenabled = true\nbackend = systemd\n' \
        | ${F2B_SUDO}tee /etc/fail2ban/jail.d/vps-check-sshd.local >/dev/null \
        && echo "Создан /etc/fail2ban/jail.d/vps-check-sshd.local"
    fi

    ${F2B_SUDO}systemctl enable fail2ban >/dev/null 2>&1
    # restart, а не start: служба могла уже упасть при установке пакета или раньше, до правки конфига
    ${F2B_SUDO}systemctl restart fail2ban >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
      local st
      echo "fail2ban запущен."
      st=$(${F2B_SUDO}fail2ban-client status 2>/dev/null)
      echo "$st"
      if printf '%s\n' "$st" | f2b_has_ssh_jail; then
        echo "jail для SSH включён — защита работает."
        BF_OK=1
      else
        echo "Jail'а для SSH нет — защита ещё не включена."
        f2b_jail_hint
      fi
    else
      echo "[!] Служба fail2ban не запустилась. Смотри: ${F2B_HINT}systemctl status fail2ban и ${F2B_HINT}journalctl -u fail2ban -n 30"
    fi
  }

  # Предложение установить fail2ban: только в интерактивном режиме и только с согласия
  f2b_offer_install() {
    local hint rc
    hint=$(f2b_install_hint)
    f2b_ask "Установить fail2ban сейчас? Будет поставлен пакет и запущена служба (изменение системы, нужен root или sudo)" "$F2B_INSTALL_ANS"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      f2b_skip_msg "$rc" "установка пропущена" "$hint"
      return
    fi
    if ! pkg_install_quiet fail2ban; then
      echo "На RHEL-совместимых системах пакет лежит в EPEL (сначала epel-release)."
      return
    fi
    f2b_start_and_check
  }

  # fail2ban стоит, но остановлен (часто — из-за той же проблемы с логом на Debian 12): предлагаем запустить
  f2b_offer_start() {
    local hint="${F2B_HINT}systemctl enable --now fail2ban" rc
    if [ "$is_root" -eq 0 ] && [ -z "$F2B_SUDO" ]; then
      echo "Запустить без root и sudo нельзя. Вручную (от root): systemctl enable --now fail2ban"
      return
    fi
    f2b_ask "Запустить fail2ban сейчас? Служба будет включена в автозагрузку и запущена (изменение системы, нужен root или sudo)" "$F2B_START_ANS"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      f2b_skip_msg "$rc" "запуск пропущен" "$hint"
      return
    fi
    f2b_start_and_check
  }

  # Сначала тихо выясняем, блокирует ли что-то CrowdSec: от этого зависит, предлагать ли запуск fail2ban.
  # Bouncer'ы считаем по табличному выводу (-o raw, CSV с заголовком): одна строка — один bouncer.
  # Новые поля в будущих версиях cscli добавят колонки, но не строки — в отличие от подсчёта "name" в JSON.
  # Если формат не узнали — защиту не засчитываем и просим проверить вручную.
  local cs_state="" cs_out n_bouncers=0
  if [ "$cs_running" -eq 1 ]; then
    if [ "$cs_installed" -eq 0 ]; then
      # процесс crowdsec есть, а cscli на хосте нет — обычно CrowdSec работает в Docker
      cs_state="nocli"
    elif ! cs_out=$("${READ_SUDO[@]}" cscli bouncers list -o raw 2>/dev/null); then
      # без root — нет прав (засчитываем на доверии); от root — cscli реально сломан (LAPI не отвечает?)
      if [ "$is_root" -eq 1 ]; then cs_state="error"; else cs_state="unreadable"; fi
    elif [ -z "$cs_out" ]; then
      cs_state="none"
    elif printf '%s\n' "$cs_out" | head -1 | grep -qiE '^"?name"?,'; then
      n_bouncers=$(printf '%s\n' "$cs_out" | tail -n +2 | grep -c .)
      if [ "$n_bouncers" -gt 0 ]; then cs_state="ok"; else cs_state="none"; fi
    else
      cs_state="unknown"
    fi
  fi

  if [ "$f2b_running" -eq 1 ]; then
    local st
    st=$("${READ_SUDO[@]}" fail2ban-client status 2>/dev/null)
    if [ -z "$st" ]; then
      echo "fail2ban запущен (список jail'ов без root не прочитать — засчитываю на доверии)."
      BF_OK=1
    else
      echo "fail2ban запущен:"
      echo "$st"
      if printf '%s\n' "$st" | f2b_has_ssh_jail; then
        echo "jail для SSH включён."
        BF_OK=1
      else
        echo "[!] fail2ban работает, но jail'а для SSH нет — SSH он не охраняет."
        f2b_jail_hint
      fi
    fi
  elif [ "$f2b_installed" -eq 1 ]; then
    echo "fail2ban установлен, но НЕ запущен."
    case "$cs_state" in
      ok)
        echo "(SSH уже защищает CrowdSec с bouncer'ом — fail2ban можно не запускать)"
        ;;
      unreadable|nocli)
        echo "(работает CrowdSec — если у него есть bouncer, fail2ban можно не запускать, см. ниже)"
        ;;
      *)
        # CrowdSec нет, он остановлен или ничего не блокирует — fail2ban как раз нужен
        case "$cs_state" in
          none) echo "(CrowdSec запущен, но атаки не блокирует — см. ниже)" ;;
          unknown|error) echo "(CrowdSec запущен, но проверить, блокирует ли он атаки, не удалось — см. ниже)" ;;
        esac
        f2b_offer_start
        ;;
    esac
  fi

  case "$cs_state" in
    ok)
      echo "CrowdSec запущен, bouncer'ов: $n_bouncers — атаки не только видны, но и блокируются."
      BF_OK=1
      ;;
    unreadable)
      echo "CrowdSec запущен (список bouncer'ов без root не прочитать — засчитываю на доверии)."
      BF_OK=1
      ;;
    # Если SSH уже защищает fail2ban (работал или только что запущен), проблема CrowdSec — справочная, а не «[!]»
    none)
      if [ "$BF_OK" -eq 1 ]; then
        echo "[i] CrowdSec запущен без bouncer'а и сам ничего не блокирует, но SSH уже защищает fail2ban."
        echo "Bouncer нужен, только если хочешь блокировать и через CrowdSec: ${F2B_HINT}apt-get install -y crowdsec-firewall-bouncer-iptables (или -nftables)"
      else
        echo "[!] CrowdSec запущен, но bouncer'ов нет: он только находит атаки и ничего не блокирует."
        echo "Поставь bouncer: ${F2B_HINT}apt-get install -y crowdsec-firewall-bouncer-iptables (или -nftables)"
      fi
      ;;
    nocli)
      echo "CrowdSec запущен, но cscli на этом хосте нет (обычно это значит, что CrowdSec в Docker) — bouncer'ы не проверить, засчитываю на доверии."
      echo "Проверь сам: docker exec <контейнер crowdsec> cscli bouncers list"
      BF_OK=1
      ;;
    error)
      if [ "$BF_OK" -eq 1 ]; then
        echo "[i] «cscli bouncers list» завершился с ошибкой, но это не важно: SSH уже защищает fail2ban."
      else
        echo "[!] CrowdSec запущен, но «cscli bouncers list» завершился с ошибкой (LAPI CrowdSec не отвечает?) — защиту не засчитываю."
        echo "Проверь: systemctl status crowdsec и cscli bouncers list"
      fi
      ;;
    unknown)
      if [ "$BF_OK" -eq 1 ]; then
        echo "[i] Вывод «cscli bouncers list» не удалось разобрать, но это не важно: SSH уже защищает fail2ban."
      else
        echo "[!] CrowdSec запущен, но вывод «cscli bouncers list» не удалось разобрать — защиту не засчитываю."
        echo "Проверь вручную: ${F2B_HINT}cscli bouncers list (нужен хотя бы один bouncer)"
      fi
      ;;
    *)
      [ "$cs_installed" -eq 1 ] && echo "CrowdSec установлен, но сервис не запущен."
      ;;
  esac

  # cs_running тоже проверяем: CrowdSec в Docker работает без cscli на хосте (cs_installed=0), и он «найден».
  # Одного пустого cs_state мало: он пуст и у установленного, но остановленного CrowdSec.
  if [ "$f2b_installed" -eq 0 ] && [ "$cs_installed" -eq 0 ] && [ "$cs_running" -eq 0 ]; then
    echo "fail2ban и CrowdSec не найдены."
    f2b_offer_install
  fi
  if [ "$BF_OK" -eq 0 ]; then
    deduct 15 "нет рабочей защиты SSH от брутфорса (fail2ban с jail'ом sshd или CrowdSec с bouncer'ом)"
  fi

  echo
  echo "=== Автообновления безопасности ==="
  UPD_OK=0
  if command -v dpkg >/dev/null && dpkg -s unattended-upgrades >/dev/null 2>&1; then
    # Сам пакет и apt-daily-upgrade.timer ещё ничего не значат: ставить обновления разрешает
    # только APT::Periodic::Unattended-Upgrade (обычно в /etc/apt/apt.conf.d/20auto-upgrades)
    local uu_val
    uu_val=$(apt-config dump 2>/dev/null | sed -nE 's/^APT::Periodic::Unattended-Upgrade "([^"]*)";$/\1/p' | tail -1)
    echo "unattended-upgrades установлен; APT::Periodic::Unattended-Upgrade = \"${uu_val:-не задано}\""
    if [ -n "$uu_val" ] && [ "$uu_val" != "0" ]; then
      if ! command -v systemctl >/dev/null \
         || systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null \
         || systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
        echo "Автоустановка обновлений включена."
        UPD_OK=1
      else
        echo "В конфиге включено, но таймер apt-daily-upgrade.timer выключен — обновления не запускаются."
      fi
    else
      echo "Пакет стоит, но автоустановка выключена в конфиге. Включить: dpkg-reconfigure -plow unattended-upgrades"
    fi
  elif command -v rpm >/dev/null && { rpm -q dnf-automatic >/dev/null 2>&1 || rpm -q dnf5-plugin-automatic >/dev/null 2>&1; }; then
    echo "dnf-automatic установлен."
    if systemctl is-enabled --quiet dnf-automatic-install.timer 2>/dev/null \
       || systemctl is-active --quiet dnf-automatic-install.timer 2>/dev/null; then
      echo "Включён dnf-automatic-install.timer — обновления скачиваются и ставятся."
      UPD_OK=1
    elif systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null \
         || systemctl is-active --quiet dnf-automatic.timer 2>/dev/null \
         || systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null \
         || systemctl is-active --quiet dnf5-automatic.timer 2>/dev/null; then
      if grep -qiE '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*(yes|true|1)' \
           /etc/dnf/automatic.conf /etc/dnf/dnf5-plugins/automatic.conf 2>/dev/null; then
        echo "Таймер включён, apply_updates = yes — обновления ставятся."
        UPD_OK=1
      else
        echo "Таймер включён, но apply_updates = no: обновления только скачиваются. Поставь apply_updates = yes в /etc/dnf/automatic.conf"
      fi
    else
      echo "Таймеры dnf-automatic не включены."
    fi
  else
    echo "Автообновления безопасности не настроены."
  fi
  if [ "$UPD_OK" -eq 0 ]; then
    deduct 10 "автообновления безопасности не настроены/не включены"
  fi

  echo
  echo "=== Нужна ли перезагрузка (обновления ядра/библиотек) ==="
  if [ -f /var/run/reboot-required ]; then
    echo "Нужна перезагрузка: установлены обновления, которые применятся только после неё (/var/run/reboot-required)."
    if [ -r /var/run/reboot-required.pkgs ]; then
      sed 's/^/  - /' /var/run/reboot-required.pkgs | head -10
    fi
  elif command -v needs-restarting >/dev/null && [ "$is_root" -eq 1 ]; then
    needs-restarting -r >/dev/null 2>&1
    case $? in
      0) echo "Перезагрузка не требуется (needs-restarting -r)." ;;
      1) echo "Нужна перезагрузка (needs-restarting -r сообщает об обновлениях ядра/системных библиотек)." ;;
      *) echo "needs-restarting -r завершился с неожиданным кодом — состояние перезагрузки определить не удалось." ;;
    esac
  elif command -v needrestart >/dev/null && [ "$is_root" -eq 1 ]; then
    KSTA=$(needrestart -b 2>/dev/null | awk -F': ' '/^NEEDRESTART-KSTA:/ {print $2}')
    case "$KSTA" in
      3) echo "Нужна перезагрузка: установлено более новое ядро, чем запущено (needrestart)." ;;
      2) echo "Ядро обновлено ABI-совместимо, перезагрузка желательна (needrestart)." ;;
      1) echo "Работает актуальное ядро (needrestart)." ;;
      *) echo "needrestart не смог определить состояние ядра." ;;
    esac
  else
    echo "Признаков необходимости перезагрузки не найдено (нет /var/run/reboot-required; needs-restarting и needrestart недоступны или для них нужен root)."
  fi

  echo
  echo "=== Открытые порты (слушающие службы) ==="
  if command -v ss >/dev/null; then
    ss -tulpn 2>/dev/null || ss -tuln
  elif command -v netstat >/dev/null; then
    netstat -tulpn 2>/dev/null || netstat -tuln
  else
    echo "Нет ни ss, ни netstat — установи iproute2 (apt-get install -y iproute2), чтобы увидеть список портов."
  fi

  if command -v ss >/dev/null; then
    local risky
    risky=$(ss -tln 2>/dev/null | risky_listeners)
    echo
    if [ -n "$risky" ]; then
      echo "[!] Базы данных, кэши или Docker API слушают не только localhost:"
      printf '%s\n' "$risky" | sed 's/^/  /'
      echo "Если firewall их не режет — к ним можно подключиться из интернета. Надёжнее привязать службу к 127.0.0.1 (bind-address / bind / -p 127.0.0.1:...)."
      deduct 10 "наружу слушают БД/кэши/Docker API"
    else
      echo "Базы данных, кэши и Docker API наружу не слушают (проверены порты 2375, 3306, 5432, 6379, 9200, 11211, 27017)."
    fi
  fi

  echo
  echo "=== Итог ==="
  [ "$SCORE" -lt 0 ] && SCORE=0
  if [ "$SCORE" -ge 80 ]; then VERDICT="хорошо — базовая защита на месте"
  elif [ "$SCORE" -ge 50 ]; then VERDICT="средне — есть незакрытые дыры, стоит поправить"
  else VERDICT="плохо — сервер в дефолтном состоянии, легко ломается автоматическим сканированием"
  fi
  if [ "$FW_UNVERIFIED" -eq 1 ]; then
    VERDICT="${VERDICT} (firewall без root не проверен — оценка может быть завышена)"
  fi
  echo "Оценка: ${SCORE}/100 — ${VERDICT}"
}

# ---------- 10. Disk & Filesystem ----------
cmd_disk() {
  echo -e "\n########## Disk & Filesystem ##########\n"
  local SWAP_TOTAL RO_MOUNTS FS_ERRORS dev
  [ "$(id -u)" -ne 0 ] && echo "[!] Запущено не от root — dmesg может вернуть пусто из-за kernel.dmesg_restrict. Для полной картины: sudo bash vps-check.sh 5"
  echo

  echo "=== Свободное место (df) ==="
  df -hT 2>/dev/null || df -h

  echo
  echo "=== Использование inode ==="
  df -i 2>/dev/null

  echo
  echo "=== Swap ==="
  SWAP_TOTAL=$(LC_ALL=C free -m 2>/dev/null | awk '/^Swap:/ {print $2}')
  if [ -z "$SWAP_TOTAL" ]; then
    echo "Не удалось определить swap (команда free недоступна)."
  else
    LC_ALL=C free -h 2>/dev/null | awk 'NR==1 || /^Mem:|^Swap:/'
    if [ "$SWAP_TOTAL" -eq 0 ]; then
      echo "Swap не настроен — при нехватке RAM (сборки, пики нагрузки) процессы убивает OOM killer."
    else
      swapon --show 2>/dev/null
      echo "vm.swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo н/д)"
    fi
  fi

  echo
  echo "=== Read-only разделы (реальные файловые системы) ==="
  if command -v findmnt >/dev/null; then
    RO_MOUNTS=$(findmnt -rn -t ext2,ext3,ext4,xfs,btrfs,f2fs -o TARGET,FSTYPE,OPTIONS 2>/dev/null | awk '$3 ~ /(^|,)ro(,|$)/')
    if [ -n "$RO_MOUNTS" ]; then
      echo "[!] Смонтированы только для чтения (бывает намеренно, но может быть аварийным remount-ro после ошибки ФС):"
      echo "$RO_MOUNTS"
    else
      echo "Все реальные файловые системы смонтированы для записи."
    fi
  else
    echo "findmnt недоступен (util-linux), проверка пропущена."
  fi

  echo
  echo "=== Ошибки файловой системы в dmesg (последние 20 строк) ==="
  if command -v dmesg >/dev/null; then
    FS_ERRORS=$(dmesg 2>/dev/null | grep -iE "EXT4-fs error|XFS.*error|I/O error|read-only file system|corrupt|buffer I/O error" | tail -20)
    if [ -n "$FS_ERRORS" ]; then
      echo "$FS_ERRORS"
    else
      echo "Ошибок не найдено (или dmesg пуст/недоступен без root)."
    fi
  else
    echo "dmesg недоступен."
  fi

  echo
  echo "=== SMART-статус диска (если доступен) ==="
  if command -v smartctl >/dev/null; then
    for dev in /dev/sd? /dev/vd? /dev/nvme?n1; do
      [ -e "$dev" ] || continue
      echo "--- $dev ---"
      smartctl -H "$dev" 2>/dev/null || echo "недоступно (для VPS это норма — диск виртуальный)"
    done
  else
    echo "smartctl не установлен (apt-get install -y smartmontools) — для VPS часто бесполезно, диск виртуальный."
  fi
}

# ---------- 11. SSL Check ----------
cmd_ssl() {
  local domain="${1:-$TARGET_DOMAIN}"
  echo -e "\n########## SSL Check ##########\n"
  if [ -z "$domain" ]; then
    echo "Домен не указан — пункт пропущен. Проверить потом: bash vps-check.sh 11 example.com"
    mark_skipped
    return 0
  fi

  domain="${domain#*://}"
  domain="${domain%%/*}"

  local port=443 is_ipv6=0 rest
  if [[ "$domain" == \[*\]* ]]; then
    # IPv6 в скобках: [2001:db8::1] или [2001:db8::1]:8443
    is_ipv6=1
    rest="${domain#*]}"
    domain="${domain%%]*}"
    domain="${domain#[}"
    [[ "$rest" == :* ]] && port="${rest#:}"
  elif [[ "$domain" == *:*:* ]]; then
    # голый IPv6 без скобок: порта в нём нет, берём 443
    is_ipv6=1
  elif [[ "$domain" == *:* ]]; then
    port="${domain##*:}"
    domain="${domain%%:*}"
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Некорректный порт в адресе: $port"
    return 1
  fi

  local target="$domain:$port"
  if [ "$is_ipv6" -eq 1 ]; then
    target="[$domain]:$port"
  fi

  if ! command -v openssl >/dev/null; then
    echo "openssl не установлен — проверка невозможна (apt-get install -y openssl)."
    mark_skipped
    return 1
  fi

  # Для IP-адреса SNI не отправляем, а имя в сертификате сверяем с самим IP
  local is_ip=0
  [ "$is_ipv6" -eq 1 ] && is_ip=1
  [[ "$domain" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && is_ip=1
  local conn_args=(-connect "$target") verify_args=()
  if [ "$is_ip" -eq 1 ]; then
    verify_args=(-verify_ip "$domain")
  else
    conn_args+=(-servername "$domain")
    verify_args=(-verify_hostname "$domain")
  fi

  # Таймаут: без него s_client на порту, который дропает файрвол, висит около двух минут
  echo "Проверяю сертификат для: $target"
  local out rc
  out=$(run_with_timeout 10 openssl s_client "${conn_args[@]}" "${verify_args[@]}" </dev/null 2>&1)
  rc=$?
  # Старый openssl может не знать -verify_hostname/-verify_ip — тогда повторяем без проверки имени
  if printf '%s\n' "$out" | grep -qiE 'unknown option|usage:'; then
    out=$(run_with_timeout 10 openssl s_client "${conn_args[@]}" </dev/null 2>&1)
    rc=$?
  fi

  local pem
  pem=$(printf '%s\n' "$out" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')
  if [ -z "$pem" ]; then
    if [ "$rc" -eq 124 ]; then
      echo "Сервер не ответил за 10 секунд ($target) — порт закрыт файрволом или хост недоступен."
    else
      echo "Не удалось получить сертификат ($target) — сервер не отвечает, на порту нет TLS или неверное имя."
    fi
    return 1
  fi

  printf '%s\n' "$pem" | openssl x509 -noout -subject -issuer -dates 2>/dev/null

  local end end_ts days=""
  end=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  end_ts=$(date -d "$end" +%s 2>/dev/null)
  [ -n "$end_ts" ] && days=$(( (end_ts - $(date +%s)) / 86400 ))

  echo
  if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    echo "[!] Сертификат ИСТЁК ($end)."
  elif ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 1209600 >/dev/null 2>&1; then
    echo "[!] Сертификат истекает меньше чем через 14 дней${days:+ (осталось дней: $days)} — проверь автопродление (например, certbot renew --dry-run)."
  else
    echo "До истечения: ${days:-больше 14} дн. — запас есть."
  fi

  local vline
  vline=$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*Verify return code: //p' | tail -1)
  case "$vline" in
    "0 (ok)") echo "Цепочка доверия и имя в сертификате: OK" ;;
    "") echo "Результат проверки цепочки не получен." ;;
    *) echo "[!] Проверка цепочки/имени не прошла: $vline (самоподписанный сертификат, нет промежуточного или сертификат выдан на другое имя)" ;;
  esac
}

# ---------- 14. Nmap outbound ----------
cmd_nmap() {
  echo -e "\n########## Nmap outbound (не режет ли хостер исходящие порты) ##########\n"
  local MX_IP RELAY_IP
  command -v nmap >/dev/null || pkg_install_quiet nmap
  if ! command -v nmap >/dev/null; then
    echo "nmap не установлен, пропускаю проверку."
    mark_skipped
    return
  fi

  echo "=== Общая проверка (45.33.32.156 = scanme.nmap.org, официальная тестовая цель Nmap) ==="
  nmap -Pn -n --host-timeout 20s -p 22,80,443,9929,31337 45.33.32.156

  echo
  echo "=== Исходящий SMTP (часто режут хостеры для борьбы со спамом) ==="
  MX_IP=$(getent ahostsv4 gmail-smtp-in.l.google.com 2>/dev/null | awk '{print $1; exit}')
  if [ -n "$MX_IP" ]; then
    echo "--- Порт 25 (MX-сервер Google gmail-smtp-in.l.google.com: $MX_IP, получен через DNS) ---"
  else
    MX_IP="142.250.27.27"
    echo "--- Порт 25 (MX-сервер Google, DNS недоступен — резервный IP $MX_IP) ---"
  fi
  nmap -Pn -n --host-timeout 20s -p 25 "$MX_IP"

  echo "--- Порты 465, 587 (клиентский релей Google smtp.gmail.com) ---"
  RELAY_IP=$(getent ahostsv4 smtp.gmail.com 2>/dev/null | awk '{print $1; exit}')
  if [ -n "$RELAY_IP" ]; then
    echo "IP релея: $RELAY_IP (получен через DNS)"
  else
    RELAY_IP="64.233.184.108"
    echo "DNS недоступен, используется резервный IP: $RELAY_IP"
  fi
  nmap -Pn -n --host-timeout 20s -p 465,587 "$RELAY_IP"

  echo
  echo "=== DNS/DoT наружу (Cloudflare 1.1.1.1, Google 8.8.8.8) ==="
  nmap -Pn -n --host-timeout 20s -p 53,443,853 1.1.1.1
  nmap -Pn -n --host-timeout 20s -p 53 8.8.8.8

  echo
  echo "Как читать результат:"
  echo "  open     — порт доступен, хостер не режет"
  echo "  filtered — пакет ушёл, но ответа нет: хостер (или фаервол по пути) дропает пакеты"
  echo "  closed   — пакет дошёл до хоста, тот ответил RST: служба не слушает, но блокировки нет"
  echo
  echo "Filtered на 25/465/587 обычно значит, что хостер режет исходящую почту."
}

# Эталонные SHA-256 архивов Ookla Speedtest CLI (для версии из OOKLA_VERSION).
# Пока значения пусты — проверка пропускается, а в выводе показывается сам хеш скачанного архива. Как заполнить — в README.
# Для другой версии можно передать хеш напрямую: OOKLA_SHA256=<хеш> OOKLA_VERSION=<версия> bash vps-check.sh 6
ookla_expected_sha256() {   # $1 = архитектура (x86_64 | aarch64 | armhf | i386)
  if [ -n "${OOKLA_SHA256:-}" ]; then
    echo "$OOKLA_SHA256"
    return
  fi
  case "${OOKLA_VERSION}:$1" in
    "1.2.0:x86_64")  echo "" ;;
    "1.2.0:aarch64") echo "" ;;
    "1.2.0:armhf")   echo "" ;;
    "1.2.0:i386")    echo "" ;;
  esac
}

# ---------- Ookla Speedtest CLI: общий загрузчик для пунктов 6 и 7 ----------
# Официальный CLI от Ookla. Если в системе уже есть speedtest от Ookla — берётся он, иначе архив скачивается
# во временную папку внутри WORKDIR (её удалит общая очистка, в том числе по Ctrl+C) — в систему ничего не ставится.
# Путь к бинарю — в OOKLA_BIN (вызывающий пункт объявляет её local).
# Код возврата: 0 — готово, 2 — архитектура не поддерживается, 1 — ошибка
ookla_get_cli() {
  local st tmpdir arch url
  OOKLA_BIN=""
  st=$(command -v speedtest 2>/dev/null) || st=""
  # у python-speedtest-cli бинарь тоже называется speedtest, поэтому проверяем, что он от Ookla
  if [ -n "$st" ] && "$st" --version 2>&1 | grep -qi ookla; then
    OOKLA_BIN="$st"
    return 0
  fi

  case "$(uname -m)" in
    x86_64)        arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l)        arch="armhf" ;;
    i386|i686)     arch="i386" ;;
    *)
      echo "[i] Для архитектуры $(uname -m) у Ookla нет официального CLI (есть x86_64, i386, armhf, aarch64) — пропускаю пункт."
      return 2
      ;;
  esac

  # Папка внутри WORKDIR: если тест прервут по Ctrl+C, её удалит общая очистка.
  # Она общая для пунктов 6 и 7: CLI скачивается за прогон один раз, второй пункт берёт готовый
  if [ -n "${WORKDIR:-}" ]; then
    tmpdir="$WORKDIR/ookla-cli"
    if [ -x "$tmpdir/speedtest" ]; then
      OOKLA_BIN="$tmpdir/speedtest"
      return 0
    fi
    mkdir -p "$tmpdir" || {
      echo "[!] Не удалось создать временную папку для Ookla CLI" >&2
      return 1
    }
  else
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/ookla-XXXXXX") || {
      echo "[!] Не удалось создать временную папку для Ookla CLI" >&2
      return 1
    }
  fi

  url="https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-${arch}.tgz"
  local tgz="$tmpdir/ookla.tgz"
  if ! { curl -fsSL --connect-timeout 5 --max-time 30 -o "$tgz" "$url" 2>/dev/null \
         || wget -q --tries=2 -O "$tgz" --timeout=30 "$url" 2>/dev/null; } \
     || [ ! -s "$tgz" ]; then
    echo "[!] Не удалось скачать Ookla Speedtest CLI ($url) — сеть недоступна или версия в ссылке устарела (поменяй OOKLA_VERSION в начале скрипта)."
    rm -rf "$tmpdir"
    return 1
  fi

  # Проверка SHA-256 архива (если эталон известен); хеш считаем всегда, чтобы показать его при пустом эталоне
  local want got
  want=$(ookla_expected_sha256 "$arch" | tr 'A-F' 'a-f' | tr -d '[:space:]')
  if command -v sha256sum >/dev/null; then
    got=$(sha256sum "$tgz" | awk '{print $1}')
  elif command -v shasum >/dev/null; then
    got=$(shasum -a 256 "$tgz" | awk '{print $1}')
  else
    got=""
  fi
  if [ -n "$want" ]; then
    if [ -z "$got" ]; then
      echo "[i] sha256sum/shasum не найдены — проверка SHA-256 архива пропущена."
    elif [ "$got" != "$want" ]; then
      echo "[!] SHA-256 архива Ookla CLI не совпал (ожидался $want, получен $got) — запускать не буду."
      rm -rf "$tmpdir"
      return 1
    else
      echo "SHA-256 архива Ookla CLI совпал."
    fi
  elif [ -n "$got" ]; then
    echo "[i] Для Ookla CLI $OOKLA_VERSION ($arch) эталонный SHA-256 не задан — проверка пропущена. Полученный хеш: $got (впиши его в ookla_expected_sha256, если доверяешь этому скачиванию)."
  else
    echo "[i] Для Ookla CLI $OOKLA_VERSION ($arch) эталонный SHA-256 не задан, а sha256sum/shasum не найдены — проверка целостности архива пропущена."
  fi

  if ! tar xzf "$tgz" -C "$tmpdir" 2>/dev/null || [ ! -x "$tmpdir/speedtest" ]; then
    echo "[!] Не удалось распаковать архив Ookla CLI."
    rm -rf "$tmpdir"
    return 1
  fi
  OOKLA_BIN="$tmpdir/speedtest"
}

# Понятное сообщение по коду возврата Ookla CLI ($1 — код, $2 — лимит в секундах, $3 — номер пункта)
ookla_explain_rc() {
  case "$1" in
    126) echo "[!] Бинарь Ookla не запустился (код 126): похоже, временная папка лежит на разделе с noexec. Запусти так: mkdir -p ~/tmp && TMPDIR=~/tmp bash vps-check.sh $3" ;;
    124) echo "[!] Тест Ookla не уложился в $2 секунд — сервер Speedtest перегружен или канал очень медленный." ;;
    *) echo "[!] Ookla Speedtest завершился с ошибкой (код $1) — сеть моргнула или сервер Speedtest недоступен." ;;
  esac
}

# ---------- 6. Ookla Speedtest (ближайший сервер) ----------
# Ookla сам выбирает ближайший к VPS сервер. Конкретный: OOKLA_SERVER_ID=<id> bash vps-check.sh 6  (список: speedtest -L)
cmd_ookla() {
  echo -e "\n########## Ookla Speedtest ##########\n"
  local OOKLA_BIN rc
  ookla_get_cli
  rc=$?
  if [ "$rc" -eq 2 ]; then
    mark_skipped
    return 0
  fi
  [ "$rc" -ne 0 ] && return "$rc"

  local st_args=(--accept-license --accept-gdpr --progress=no)
  [ -n "${OOKLA_SERVER_ID:-}" ] && st_args+=(-s "$OOKLA_SERVER_ID")
  run_with_timeout 180 "$OOKLA_BIN" "${st_args[@]}"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ookla_explain_rc "$rc" 180 6
    return "$rc"
  fi
}

# ---------- 7. Ookla Speedtest до серверов в России ----------
# Для зарубежного VPS ближайший сервер Ookla — не российский, поэтому серверы в нужных городах ищем поиском
# speedtest.net (тем же, что в «Сменить сервер» на сайте) и тестируем каждый явно через -s <id>.
# На город — до двух серверов: популярные бывают перегружены и отказывают. Города — в OOKLA_RU_CITIES (начало файла)
cmd_ookla_ru() {
  echo -e "\n########## Ookla Speedtest до РФ ##########\n"
  if ! ensure_cmds jq; then
    mark_skipped
    return 0
  fi
  local OOKLA_BIN rc
  ookla_get_cli
  rc=$?
  if [ "$rc" -eq 2 ]; then
    mark_skipped
    return 0
  fi
  [ "$rc" -ne 0 ] && return "$rc"

  local -a cities variants
  local entry variant list cands sid sponsor sname out res row msg ok line
  local good=0 total=0 summary="" api_err=""
  IFS=',' read -ra cities <<< "$OOKLA_RU_CITIES"
  for entry in "${cities[@]}"; do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$entry" ] && continue
    total=$((total + 1))

    # Ищем серверы по каждому написанию города, пока не найдутся российские.
    # Фильтр по стране обязателен: «Moscow» есть и в США (Айдахо)
    cands=""
    api_err=""
    IFS='|' read -ra variants <<< "$entry"
    for variant in "${variants[@]}"; do
      if ! list=$(curl -fsS --connect-timeout 5 --max-time 15 -G "https://www.speedtest.net/api/js/servers" \
            --data-urlencode "engine=js" --data-urlencode "https_functional=true" \
            --data-urlencode "limit=20" --data-urlencode "search=$variant" 2>&1); then
        api_err="$list"
        continue
      fi
      cands=$(printf '%s' "$list" | jq -r '
        [ .[]? | select((.cc // "") == "RU" or (.country // "") == "Russia" or (.country // "") == "Russian Federation") ]
        | .[:2][] | "\(.id)\t\(.sponsor // "?")\t\(.name // "?")"' 2>/dev/null)
      [ -n "$cands" ] && break
    done
    if [ -z "$cands" ]; then
      if [ -n "$api_err" ]; then
        echo "[!] ${variants[0]}: не удалось получить список серверов speedtest.net — $api_err"
      else
        echo "[!] ${variants[0]}: на speedtest.net не нашлось российских серверов с таким городом (написание — по-английски)."
      fi
      summary="${summary:+$summary; }${variants[0]} — нет серверов"
      continue
    fi

    ok=0
    while IFS=$'\t' read -r sid sponsor sname; do
      echo "Тестирую $sname — $sponsor (сервер $sid), до 90 секунд..."
      out=$(run_with_timeout 90 "$OOKLA_BIN" --accept-license --accept-gdpr --format=json -s "$sid" </dev/null 2>&1)
      rc=$?
      if [ "$rc" -eq 126 ]; then
        ookla_explain_rc 126 90 7
        return 126
      fi
      res=$(printf '%s\n' "$out" | grep -F '"type":"result"' | tail -1)
      row=""
      if [ -n "$res" ]; then
        row=$(printf '%s' "$res" | jq -r '[
            (.download.bandwidth * 8 / 1000000), (.upload.bandwidth * 8 / 1000000),
            (.ping.latency // 0), (.ping.jitter // 0), (.packetLoss // -1)
          ] | @tsv' 2>/dev/null)
      fi
      if [ -n "$row" ]; then
        # LC_ALL=C: точка в дробях при любой локали. Первая строка — подробно, вторая — для итога
        line=$(printf '%s\t%s\t%s\n' "$sname" "$sponsor" "$row" | LC_ALL=C awk -F'\t' '{
          loss = ($7 < 0) ? "н/д" : sprintf("%.1f%%", $7)
          printf "%s — %s: ↓ %.1f Мбит/с, ↑ %.1f Мбит/с, пинг %.1f мс (джиттер %.1f мс), потери %s\n", $1, $2, $3, $4, $5, $6, loss
          printf "%s ↓%.0f/↑%.0f Мбит/с, %.0f мс\n", $1, $3, $4, $5
        }')
        echo "  $(printf '%s\n' "$line" | head -1)"
        summary="${summary:+$summary; }$(printf '%s\n' "$line" | tail -1)"
        good=$((good + 1))
        ok=1
        break
      fi
      msg=$(printf '%s\n' "$out" | jq -rR 'fromjson? | select(.type? == "log") | .message? // empty' 2>/dev/null | tail -1)
      [ -z "$msg" ] && [ "$rc" -eq 124 ] && msg="не уложился в 90 секунд"
      [ -z "$msg" ] && msg=$(printf '%s\n' "$out" | tail -1)
      echo "  не вышло: ${msg:-сервер не ответил}"
    done <<< "$cands"
    [ "$ok" -eq 0 ] && summary="${summary:+$summary; }${variants[0]} — не вышло"
  done

  echo
  if [ "$total" -eq 0 ]; then
    echo "[!] Список городов OOKLA_RU_CITIES пуст."
    return 1
  fi
  echo "Итог Ookla до РФ: $summary"
  if [ "$good" -eq 0 ]; then
    echo "[!] Ни один город проверить не удалось."
    return 1
  fi
  [ "$good" -lt "$total" ] && echo "[i] Проверено городов: $good из $total — для остальных серверы не нашлись или не ответили."
  echo "(↓ — загрузка на VPS, ↑ — отдача с VPS; Ookla сохраняет результаты тестов у себя на speedtest.net)"
  return 0
}

# ---------- итоговая сводка ----------
# Формат строки SUMMARY_FILE: номер<TAB>имя<TAB>статус<TAB>секунды; статус: ok | skip | int | fail:<код>
# Текст сводки сначала собирается целиком и только потом печатается одним куском:
# если Ctrl+C убьёт awk на середине, в лог не попадёт обрезанная сводка, а функция вернёт ошибку.
print_summary() {
  [ -s "$SUMMARY_FILE" ] || return 0
  local text
  text=$(awk -F'\t' '
    function mmss(t) { return sprintf("%d:%02d", int(t / 60), t % 60) }
    {
      t = $4 + 0; total += t
      if ($3 == "ok")        { st = "✓"; ok++ }
      else if ($3 == "skip") { st = "пропущен"; sk++ }
      else if ($3 == "int")  { st = "прерван (Ctrl+C)"; it++ }
      else                   { c = $3; sub(/^fail:/, "", c); st = "✗ ошибка (код " c ")"; fl++ }
      printf "%3s) %6s  %s — %s\n", $1, mmss(t), $2, st
    }
    END {
      printf "\nУспешно: %d, с ошибкой: %d, пропущено: %d", ok, fl, sk
      if (it) printf ", прервано: %d", it
      printf ". Общее время: %s\n", mmss(total)
    }' "$SUMMARY_FILE") || return 1
  printf '\n########## Итог прогона ##########\n\n%s\n' "$text"
}

# ---------- генератор Markdown-отчёта ----------
generate_markdown_report() {
  local raw_file="$1"
  local md_file="$2"

  local clean_file="${WORKDIR:-${TMPDIR:-/tmp}}/clean.log"
  strip_ansi < "$raw_file" > "$clean_file" || {
    echo "[!] Не удалось подготовить очищенный лог для отчёта" >&2
    return 1
  }

  local os_info="Не определено"
  [ -f /etc/os-release ] && os_info=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')

  local cpu_info
  cpu_info=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/Model name/ {print $2}' | xargs)
  [ -z "$cpu_info" ] && cpu_info=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
  [ -z "$cpu_info" ] && cpu_info="Не определено"

  local cpu_cores
  cpu_cores=$(nproc 2>/dev/null || echo "1")

  local ram_info
  ram_info=$(LC_ALL=C free -h 2>/dev/null | awk '/^Mem:/ {print $2}')
  [ -z "$ram_info" ] && ram_info="Не определено"

  local kernel_info
  kernel_info=$(uname -r)

  local report_date
  report_date=$(date "+%Y-%m-%d %H:%M:%S")

  local sec_score
  sec_score=$(grep -E "Оценка: [0-9]+/100" "$clean_file" | tail -1 | sed -E 's/.*Оценка: ([0-9]+\/100.*)/\1/')

  # Geekbench — из YABS (пункт 1) или пункта 4
  local gb_ver gb_single gb_multi
  gb_ver=$(sed -nE 's/^Geekbench ([0-9]+) Benchmark Test:.*/\1/p' "$clean_file" | head -1)
  gb_single=$(sed -nE 's/^[[:space:]]*Single Core[[:space:]]*\|[[:space:]]*([0-9]+).*/\1/p' "$clean_file" | head -1)
  gb_multi=$(sed -nE 's/^[[:space:]]*Multi Core[[:space:]]*\|[[:space:]]*([0-9]+).*/\1/p' "$clean_file" | head -1)

  # Масштабирование sysbench (пункт 3)
  local sb_scale
  sb_scale=$(sed -nE 's/.*прирост ×([0-9.]+) \(идеал ≈ ×([0-9]+)\).*/×\1 при идеале ×\2/p' "$clean_file" | head -1)

  # Итог Ookla Speedtest (если запускался пункт 6): берём только текст его раздела
  local ookla_block ookla_dl ookla_ul ookla_lat
  ookla_block=$(awk '/^########## Ookla Speedtest ##########$/ {f=1; next} /^########## / {f=0} f' "$clean_file")
  ookla_dl=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Download:[[:space:]]*([0-9.]+ [KMG]bps).*/\1/p' | head -1)
  ookla_ul=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Upload:[[:space:]]*([0-9.]+ [KMG]bps).*/\1/p' | head -1)
  ookla_lat=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Latency:[[:space:]]*([0-9.]+ ms).*/\1/p' | head -1)

  # Итог Ookla до РФ (пункт 7) — он сам печатает готовую строку «Итог Ookla до РФ: ...»
  local ookla_ru
  ookla_ru=$(sed -n 's/^Итог Ookla до РФ: //p' "$clean_file" | tail -1)

  {
    cat <<EOF
# Отчёт проверки VPS

| Параметр | Значение |
| :--- | :--- |
| **Дата проверки** | $report_date |
| **ОС** | $os_info |
| **Ядро Linux** | $kernel_info |
| **Процессор** | $cpu_info ($cpu_cores vCPU) |
| **Оперативная память** | $ram_info |
EOF

    if [ "$INTERRUPTED" -eq 1 ]; then
      if [ -n "$INTERRUPTED_ITEM" ]; then
        echo "| **Статус прогона** | ⚠️ прерван на пункте $INTERRUPTED_ITEM ($(item_name "$INTERRUPTED_ITEM")) — отчёт неполный |"
      else
        echo "| **Статус прогона** | ⚠️ прерван — отчёт неполный |"
      fi
    fi

    [ -n "$sec_score" ] && echo "| **Аудит безопасности** | $sec_score |"

    if [ -n "$gb_single" ] && [ -n "$gb_multi" ]; then
      echo "| **Geekbench${gb_ver:+ $gb_ver}** | single $gb_single / multi $gb_multi |"
    fi

    [ -n "$sb_scale" ] && echo "| **sysbench: масштабирование** | $sb_scale |"

    if [ -n "$ookla_dl" ] && [ -n "$ookla_ul" ]; then
      if [ -n "$ookla_lat" ]; then
        echo "| **Ookla Speedtest** | ↓ $ookla_dl / ↑ $ookla_ul, задержка $ookla_lat |"
      else
        echo "| **Ookla Speedtest** | ↓ $ookla_dl / ↑ $ookla_ul |"
      fi
    fi

    [ -n "$ookla_ru" ] && echo "| **Ookla до РФ** | $ookla_ru |"

    # Сводка по пунктам — таблицей (в терминале и TXT она идёт отдельным разделом в конце)
    if [ -s "$SUMMARY_FILE" ]; then
      echo
      echo "## Итог прогона"
      echo
      echo "| № | Проверка | Статус | Время |"
      echo "| ---: | :--- | :--- | ---: |"
      awk -F'\t' '
        {
          t = $4 + 0
          if ($3 == "ok")        st = "✓"
          else if ($3 == "skip") st = "пропущен"
          else if ($3 == "int")  st = "⚠️ прерван"
          else                   { c = $3; sub(/^fail:/, "", c); st = "✗ ошибка (код " c ")" }
          printf "| %s | %s | %s | %d:%02d |\n", $1, $2, st, int(t / 60), t % 60
        }' "$SUMMARY_FILE"
    fi

    echo -e "\n---\n"
    # Если пункты из нескольких групп — разделы идут по группам, общий заголовок не нужен
    grep -q '^>>>>>>>>>> .* <<<<<<<<<<$' "$clean_file" || echo "## Результаты проверок"

    # Литерал ########## вместо #{10}: старый mawk (Debian 12, Ubuntu 22.04) не понимает {n} в регулярках.
    # Раздел «Итог прогона» пропускаем — он уже выведен таблицей выше.
    awk '
      BEGIN { in_block = 0 }
      /^>>>>>>>>>> .+ <<<<<<<<<<$/ {
        if (in_block) {
          print "```\n"
        }
        g = $0
        sub(/^>>>>>>>>>> /, "", g)
        sub(/ <<<<<<<<<<$/, "", g)
        print "\n## " g "\n"
        in_block = 0
        next
      }
      /^########## .+ ##########$/ {
        if (in_block) {
          print "```\n"
        }
        title = $0
        sub(/^########## /, "", title)
        sub(/ ##########$/, "", title)
        if (title == "Итог прогона") {
          in_block = 0
          next
        }
        print "\n### " title "\n"
        print "```text"
        in_block = 1
        next
      }
      {
        if (in_block) {
          print $0
        }
      }
      END {
        if (in_block) {
          print "```"
        }
      }
    ' "$clean_file"
  } > "$md_file"
  local rc=$?

  rm -f "$clean_file"
  return "$rc"
}

# ---------- разбор выборки: номера, диапазоны, группы ----------
# Части через запятую: 3, 6-9, 0/all/все (всё), имя группы (net, сеть, ...). Повторы схлопываются
expand_selection() {
  local input="$1"
  local result="" part i g start end
  local -a parts
  add_item() {
    case " $result " in *" $1 "*) return ;; esac
    result="$result $1"
  }
  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [ -z "$part" ] && continue
    g=$(group_by_name "$part")
    if [ -n "$g" ]; then
      for i in $(group_items "$g"); do add_item "$i"; done
    elif [ "$part" = "0" ] || [ "$part" = "all" ] || [ "$part" = "все" ]; then
      for i in $DEFAULT_ITEMS; do add_item "$i"; done
    elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if [ "$start" -gt "$end" ]; then
        echo "Пропускаю некорректный диапазон $part (начало больше конца)" >&2
        continue
      fi
      [ "$start" -lt "$MIN_ITEM" ] && { echo "Диапазон $part выходит за $MIN_ITEM-$MAX_ITEM, обрезаю до $MIN_ITEM" >&2; start=$MIN_ITEM; }
      [ "$end" -gt "$MAX_ITEM" ] && { echo "Диапазон $part выходит за $MIN_ITEM-$MAX_ITEM, обрезаю до $MAX_ITEM" >&2; end=$MAX_ITEM; }
      for ((i=start; i<=end; i++)); do add_item "$i"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      if [ "$part" -lt "$MIN_ITEM" ] || [ "$part" -gt "$MAX_ITEM" ]; then
        echo "Пункта $part не существует (доступны $MIN_ITEM-$MAX_ITEM), пропускаю" >&2
        continue
      fi
      add_item "$part"
    fi
  done
  echo "$result"
}

# Части выборки, которые не похожи ни на номер, ни на диапазон, ни на группу (для понятной ошибки)
bad_selection_parts() {
  local part bad=""
  local -a parts
  IFS=',' read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [ -z "$part" ] && continue
    [ -n "$(group_by_name "$part")" ] && continue
    case "$part" in 0|all|все) continue ;; esac
    [[ "$part" =~ ^[0-9]+(-[0-9]+)?$ ]] && continue
    bad="${bad:+$bad, }$part"
  done
  echo "$bad"
}

# ---------- диспетчер запусков ----------
# Пункт сообщает «пропущен» файлом-меткой: каждый пункт идёт в своём подшелле, и переменная наружу не дойдёт
mark_skipped() {
  : > "$WORKDIR/skip"
}

# Один пункт: замер времени, код возврата и запись строки в сводку.
# Пункт запускается в отдельном подшелле: его переменные и shopt не протекают в следующие пункты,
# а Ctrl+C гарантированно обрывает весь пункт, даже если в нём ещё несколько команд.
# Файл current нужен, чтобы после Ctrl+C знать, на каком пункте остановились.
run_item() {
  local n="$1" extra="$2" start rc status
  start=$(date +%s)
  rm -f "$WORKDIR/skip"
  printf '%s %s\n' "$n" "$start" > "$WORKDIR/current"
  # trap внутри подшелла: если команда пункта (nmap, YABS) сама поймала Ctrl+C и вышла «нормально»,
  # bash без трапа пошёл бы к следующей команде этого же пункта
  local fn
  fn=$(item_func "$n")
  if [ -n "${SKIP_REASON[$n]:-}" ]; then
    # Пропуск, о котором договорились перед стартом: заголовок всё равно печатаем — так пункт виден и в отчёте
    echo -e "\n########## $(item_name "$n") ##########\n"
    echo "Пропущен: ${SKIP_REASON[$n]}"
    : > "$WORKDIR/skip"
  elif [ "$n" = "11" ]; then
    ( trap 'exit 130' INT; "$fn" "$extra" )
  else
    ( trap 'exit 130' INT; "$fn" )
  fi
  rc=$?
  if [ "$STOP" -eq 1 ]; then
    status="int"
    echo "$n" > "$WORKDIR/interrupted"
  elif [ -e "$WORKDIR/skip" ]; then
    status="skip"
  elif [ "$rc" -eq 0 ]; then
    status="ok"
  else
    status="fail:$rc"
    FAILED=$((FAILED + 1))
  fi
  printf '%s\t%s\t%s\t%s\n' "$n" "$(item_name "$n")" "$status" "$(( $(date +%s) - start ))" >> "$SUMMARY_FILE"
  rm -f "$WORKDIR/current" "$WORKDIR/skip"
}

dispatch() {
  local mode="$1"
  local extra="$2"
  local items n g prev_group="" groups="" count=0
  FAILED=0
  # Флаг вместо смерти по сигналу: некоторые сторонние скрипты (например, YABS) сами ловят Ctrl+C
  # и выходят с кодом 0 — без флага прогон после этого просто шёл бы к следующему пункту
  STOP=0
  trap 'STOP=1' INT
  items=$(expand_selection "${mode:-0}")   # предупреждения («пункта 99 нет») видны пользователю и попадают в лог
  SELECTED_ITEMS="$items"

  # Заголовки групп — только если в запуске пункты из разных групп
  for n in $items; do
    g=$(item_group "$n")
    case " $groups " in *" $g "*) ;; *) groups="$groups $g" ;; esac
  done
  set -- $groups

  for n in $items; do
    [ "$STOP" -eq 1 ] && break
    g=$(item_group "$n")
    if [ $# -gt 1 ] && [ "$g" != "$prev_group" ]; then
      printf '\n>>>>>>>>>> %s <<<<<<<<<<\n' "$(group_title "$g")"
      prev_group="$g"
    fi
    run_item "$n" "$extra"
    count=$((count + 1))
  done

  # Прервано: сводку и пометку допишет основной скрипт
  if [ "$STOP" -eq 1 ]; then
    return 130
  fi

  # Сводка нужна, когда пунктов несколько: в длинном выводе упавший пункт легко пролистать
  if [ "$count" -gt 1 ]; then
    # Маркер — только если сводка допечаталась (awk не убит Ctrl+C на середине);
    # иначе основной скрипт выведет её заново целиком
    if print_summary; then
      : > "$WORKDIR/summary_printed"
    fi
  fi
  # Ctrl+C пришёл во время сводки — дальше не печатаем, остальное допишет основной скрипт
  if [ "$STOP" -eq 1 ]; then
    return 130
  fi
  # Проверяли доступность из РФ — подсказываем, чем сверить результат снаружи
  case " $items " in
    *" 12 "*|*" 13 "*) tg_bots_hint ;;
  esac
  [ "$FAILED" -eq 0 ]
}

# ---------- валидация аргументов и ранний выход ----------
case "$ARG" in
  menu|-h|--help|help|меню)
    menu
    exit 0
    ;;
esac

BAD_PARTS=$(bad_selection_parts "${ARG:-0}")
if [ -n "$BAD_PARTS" ]; then
  echo "Неизвестный аргумент: $BAD_PARTS. Пункты — номера 1-$MAX_ITEM и диапазоны (6-9), группы — machine, net, sec, ru, ip." >&2
  echo >&2
  menu
  exit 1
fi
SEL=$(expand_selection "${ARG:-0}" 2>/dev/null)
if [ -z "$SEL" ]; then
  echo "В выборке «$ARG» нет ни одного существующего пункта (доступны $MIN_ITEM-$MAX_ITEM)." >&2
  echo >&2
  menu
  exit 1
fi

# Второй позиционный аргумент нужен только пункту 11
if [ -n "$TARGET_DOMAIN" ]; then
  case " $SEL " in
    *" 11 "*) : ;;
    *) echo "[i] Второй аргумент «$TARGET_DOMAIN» используется только пунктом 11 (SSL) и будет проигнорирован. Несколько пунктов задаются через запятую: 3,5" >&2 ;;
  esac
fi

# Ctrl+C во время вопросов — просто выходим
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

in_sel() {
  case " $SEL " in *" $1 "*) return 0 ;; esac
  return 1
}

# Вопрос «да/нет» с ответом по умолчанию ($2 — y или n). 0 — да
ask_yn() {
  local ans hint="[y/N]"
  [ "$2" = "y" ] && hint="[Y/n]"
  read -rp "$1 $hint: " ans
  [ -z "$ans" ] && ans="$2"
  [[ "$ans" =~ ^[YyДд] ]]
}

# ---------- вопросы перед стартом (только в настоящем терминале и без -y) ----------
# Всё, что нужно от пользователя, спрашиваем сразу: дальше проверки идут без остановок, и можно отойти
CACHE_AND_SHOW=false
ASKED=0
if [ -t 0 ] && [ "$NO_PROMPT" -eq 0 ]; then
  echo "Перед стартом — несколько вопросов, дальше проверки пойдут без остановок (можно отойти от терминала)."

  # 1. Домен для SSL-проверки
  if in_sel 11 && [ -z "$TARGET_DOMAIN" ]; then
    echo
    echo "Пункт 11 проверяет HTTPS-сертификат домена: сколько дней он ещё действует и доверяют ли ему браузеры."
    echo "Нужен, если на этом сервере есть сайт, панель или подписка по домену. Домена нет — просто нажми Enter."
    read -rp "Домен (например example.com) или Enter, чтобы пропустить: " TARGET_DOMAIN
    TARGET_DOMAIN="${TARGET_DOMAIN// /}"
  fi

  # 2. Согласие на Ookla: CLI принимает лицензию и сохраняет результаты у Ookla
  OOKLA_SEL=""
  if in_sel 6 && in_sel 7; then
    OOKLA_SEL="Пункты 6 и 7 меряют"
  elif in_sel 6; then
    OOKLA_SEL="Пункт 6 меряет"
  elif in_sel 7; then
    OOKLA_SEL="Пункт 7 меряет"
  fi
  if [ -n "$OOKLA_SEL" ]; then
    echo
    echo "$OOKLA_SEL скорость официальным Speedtest от Ookla. При запуске принимается его лицензия,"
    echo "а результаты сохраняются у Ookla на speedtest.net — как при обычном тесте на сайте."
    if ! ask_yn "Запускать Speedtest от Ookla?" y; then
      in_sel 6 && SKIP_REASON[6]="ты отказался от Speedtest от Ookla перед стартом"
      in_sel 7 && SKIP_REASON[7]="ты отказался от Speedtest от Ookla перед стартом"
    fi
  fi

  # 3. fail2ban: если защиты от подбора паролей явно нет — спрашиваем сейчас, а не посреди прогона.
  #    Неочевидные случаи (например, CrowdSec без bouncer'а) пункт 10 разберёт и спросит сам
  if in_sel 10 && { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null; }; then
    PRE_F2B_INST=0 PRE_F2B_RUN=0 PRE_CS=0
    command -v fail2ban-client >/dev/null && PRE_F2B_INST=1
    { systemctl is-active --quiet fail2ban 2>/dev/null || pgrep -f fail2ban-server >/dev/null 2>&1; } && PRE_F2B_RUN=1
    # Здесь проверка CrowdSec намеренно шире, чем в пункте 10 (там отдельно «установлен» и «запущен»):
    # если от CrowdSec есть любой след — cscli, служба или процесс (например, в Docker), — fail2ban заранее
    # не предлагаем. Блокирует ли CrowdSec атаки на самом деле, пункт 10 разберёт сам и при нужде спросит
    { command -v cscli >/dev/null || systemctl is-active --quiet crowdsec 2>/dev/null || pgrep -x crowdsec >/dev/null 2>&1; } && PRE_CS=1
    if [ "$PRE_F2B_INST" -eq 0 ] && [ "$PRE_CS" -eq 0 ]; then
      echo
      echo "Пункт 10 проверяет защиту SSH от подбора паролей: на сервере нет ни fail2ban, ни CrowdSec."
      echo "fail2ban банит IP, с которых подбирают пароль. Его можно поставить прямо во время проверки (меняет систему)."
      if ask_yn "Поставить fail2ban во время проверки?" n; then F2B_INSTALL_ANS="y"; else F2B_INSTALL_ANS="n"; fi
    elif [ "$PRE_F2B_INST" -eq 1 ] && [ "$PRE_F2B_RUN" -eq 0 ] && [ "$PRE_CS" -eq 0 ]; then
      echo
      echo "fail2ban установлен, но не запущен — SSH сейчас не защищён от подбора паролей."
      if ask_yn "Запустить fail2ban во время проверки?" n; then F2B_START_ANS="y"; else F2B_START_ANS="n"; fi
    fi
  fi

  # 4. Отчёт в файл, если не передан флагами
  if [ -z "$OUTPUT_TXT" ] && [ -z "$OUTPUT_MD" ]; then
    echo
    echo "Отчёт сохраняется в текущую папку после всех проверок. TXT — весь вывод простым текстом;"
    echo "Markdown — то же плюс таблица-сводка сверху (ОС, CPU, оценки, скорости), удобно сравнивать VPS."
    read -rp "Сохранить отчёт? [1: нет (Enter), 2: TXT, 3: Markdown, 4: оба]: " REP_ANS
    DATE_TAG=$(date +%Y%m%d-%H%M)
    case "$REP_ANS" in
      2) OUTPUT_TXT="vps-report-${DATE_TAG}.txt" ;;
      3) OUTPUT_MD="vps-report-${DATE_TAG}.md" ;;
      4)
        OUTPUT_TXT="vps-report-${DATE_TAG}.txt"
        OUTPUT_MD="vps-report-${DATE_TAG}.md"
        ;;
    esac
  fi

  # 5. Повтор лога — имеет смысл, только если пунктов несколько
  set -- $SEL
  if [ $# -gt 1 ]; then
    echo
    echo "Вывод длинный, и начало может уехать за пределы экрана."
    ask_yn "Показать в конце весь вывод ещё раз одним куском?" n && CACHE_AND_SHOW=true
  fi
  ASKED=1
  echo
fi

# Без домена пункт 11 пропускается (в -y, cron, curl | bash спросить некому)
if in_sel 11 && [ -z "$TARGET_DOMAIN" ]; then
  if [ "$ASKED" -eq 1 ]; then
    SKIP_REASON[11]="домен не указан. Проверить потом: bash vps-check.sh 11 example.com"
  else
    SKIP_REASON[11]="домен не передан, а спросить некому (нет терминала или флаг -y). Проверить: bash vps-check.sh 11 example.com"
  fi
fi

# ---------- рабочая папка и очистка ----------
# Учитывает TMPDIR: если /tmp смонтирован с noexec (пункты 6 и 7 запускают бинарь Ookla), можно указать другую папку
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-check-XXXXXX") || {
  echo "Не удалось создать временную папку в ${TMPDIR:-/tmp} (диск переполнен или смонтирован в read-only)" >&2
  exit 1
}
export WORKDIR
TEMP_RAW="$WORKDIR/raw.log"
SUMMARY_FILE="$WORKDIR/summary.tsv"
: > "$TEMP_RAW"
cleanup() {
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ---------- выполнение и запись в сырой лог ----------
# Ctrl+C прерывает проверки, но не сам скрипт: он допишет сводку и сохранит отчёты по тому, что успело выполниться.
# tee -i игнорирует Ctrl+C, чтобы дописать в лог всё, что уже вывели проверки.
trap 'INTERRUPTED=1' INT
if [ -t 0 ]; then
  dispatch "$ARG" "$TARGET_DOMAIN" 2>&1 | tee -i "$TEMP_RAW"
  PIPE_RC=("${PIPESTATUS[@]}")   # оба кода сразу: PIPESTATUS сбрасывается следующей же командой
else
  # stdin — не терминал (cron, curl | bash). При curl | bash в stdin лежит остаток ЭТОГО скрипта: если сторонний
  # скрипт или утилита прочитают stdin, они его «съедят», и сводка с отчётами молча не выполнятся. Отдаём им /dev/null
  dispatch "$ARG" "$TARGET_DOMAIN" </dev/null 2>&1 | tee -i "$TEMP_RAW"
  PIPE_RC=("${PIPESTATUS[@]}")
fi
DISPATCH_RC=${PIPE_RC[0]}
TEE_RC=${PIPE_RC[1]:-0}
trap 'exit 130' INT

if [ "$TEE_RC" -ne 0 ]; then
  echo "[!] Лог прогона записан не полностью (tee завершился с кодом $TEE_RC — нет места в ${TMPDIR:-/tmp}?). Отчёты могут быть неполными." >&2
fi

if [ "$INTERRUPTED" -eq 1 ]; then
  if [ -s "$WORKDIR/interrupted" ]; then
    # пункт отметил себя как прерванный сам (обычный случай)
    read -r INTERRUPTED_ITEM < "$WORKDIR/interrupted"
  elif [ -s "$WORKDIR/current" ]; then
    # диспетчер не успел записать итог пункта — дописываем строку за него (если её там ещё нет)
    read -r INTERRUPTED_ITEM ITEM_START < "$WORKDIR/current"
    if ! awk -F'\t' -v n="$INTERRUPTED_ITEM" '$1 == n { f = 1 } END { exit !f }' "$SUMMARY_FILE" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\n' "$INTERRUPTED_ITEM" "$(item_name "$INTERRUPTED_ITEM")" "int" \
        "$(( $(date +%s) - ${ITEM_START:-$(date +%s)} ))" >> "$SUMMARY_FILE"
    fi
  fi
  {
    [ -e "$WORKDIR/summary_printed" ] || print_summary
    echo
    echo "[!] Прогон прерван (Ctrl+C)${INTERRUPTED_ITEM:+ на пункте $INTERRUPTED_ITEM} — отчёты содержат только то, что успело выполниться."
  } 2>&1 | tee -a "$TEMP_RAW"
fi

# 1. Повторный вывод лога (если запрошен кэш)
if [ "$CACHE_AND_SHOW" = true ]; then
  echo
  echo "=========================================================="
  echo "ПОЛНЫЙ ЛОГ ЭТОГО ЗАПУСКА"
  echo "=========================================================="
  cat "$TEMP_RAW"
fi

# 2. Сохранение чистого TXT-отчёта без управляющих ANSI-последовательностей
if [ -n "$OUTPUT_TXT" ]; then
  if strip_ansi < "$TEMP_RAW" > "$OUTPUT_TXT"; then
    echo -e "\n[✓] Текстовый отчёт сохранён в: $OUTPUT_TXT"
  else
    echo -e "\n[!] Не удалось сохранить TXT-отчёт в: $OUTPUT_TXT (проверь путь и права доступа)" >&2
  fi
fi

# 3. Сохранение структурированного Markdown-отчёта
if [ -n "$OUTPUT_MD" ]; then
  if generate_markdown_report "$TEMP_RAW" "$OUTPUT_MD"; then
    echo -e "[✓] Markdown-отчёт сохранён в: $OUTPUT_MD"
  else
    echo -e "[!] Не удалось создать Markdown-отчёт в: $OUTPUT_MD" >&2
  fi
fi

# Код возврата: 130 — прервано, 1 — хотя бы один пункт с ошибкой, 0 — всё прошло
if [ "$INTERRUPTED" -eq 1 ]; then
  exit 130
fi
if [ "$DISPATCH_RC" -ne 0 ] || [ "$TEE_RC" -ne 0 ]; then
  exit 1
fi
exit 0
