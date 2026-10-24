#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки
# Запуск:
#   bash vps-check.sh                      -> интерактивный запуск (пункты 1-10, 13-15, 17, 18)
#   bash vps-check.sh -o report.txt        -> сохранить чистый TXT отчёт
#   bash vps-check.sh -m report.md         -> сгенерировать форматированный Markdown
#   bash vps-check.sh -o rep.txt -m rep.md -> сохранить оба отчёта сразу
#   bash vps-check.sh -y 9                 -> без интерактивных вопросов (tmux, cron)
#   bash vps-check.sh 3                    -> только пункт 3
#   bash vps-check.sh 2,4,5-7              -> пункты 2, 4, 5, 6, 7
#   bash vps-check.sh menu                 -> список пунктов
# Код возврата: 0 — все пункты прошли, 1 — хотя бы один пункт с ошибкой или неверные аргументы,
#               130 — прогон прерван по Ctrl+C (отчёты всё равно сохраняются)

MIN_ITEM=1
MAX_ITEM=19

# Пункты общего прогона (аргумент 0 / all / без аргументов). 11, 12, 16 и 19 — только вручную.
DEFAULT_ITEMS="1 2 3 4 5 6 7 8 9 10 13 14 15 17 18"

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

# Версия официального Speedtest CLI от Ookla (пункт 19). Если ссылка на скачивание
# перестала работать — проверь актуальную версию на https://www.speedtest.net/apps/cli
# Переопределить без правки файла: OOKLA_VERSION=1.2.0 bash vps-check.sh 19
OOKLA_VERSION="${OOKLA_VERSION:-1.2.0}"

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
  echo "Слишком много аргументов. Несколько пунктов задаются через запятую (3,5,7), второй аргумент — только домен для пункта 11." >&2
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

  # Качаем сразу в файл (не через переменную bash): так скрипт сохраняется байт в байт
  if ! { curl -fsSL --connect-timeout 5 --max-time 30 -o "$tmp" "$url" 2>/dev/null \
         || wget -qO "$tmp" --timeout=30 "$url" 2>/dev/null; } \
     || [ ! -s "$tmp" ]; then
    echo "[!] Не удалось скачать скрипт для \"$label\" ($url) — таймаут или зеркало недоступно."
    rm -f "$tmp"
    return 1
  fi

  # Вместо скрипта мог прийти HTML (лендинг, страница ошибки) — не передаём его в bash
  # (скрипт не может начинаться с "<", а HTML/XML — всегда)
  if [ "$(head -c 200 "$tmp" | LC_ALL=C tr -d ' \t\r\n' | head -c 1)" = "<" ]; then
    echo "[!] По ссылке вернулась HTML-страница, а не скрипт ($url) — проверь, что это прямая ссылка на скрипт."
    rm -f "$tmp"
    return 1
  fi

  bash "$tmp" "$@"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

run() {
  echo -e "\n########## $1 ##########\n"
  bash -c "set -o pipefail; $2"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[!] Пункт \"$1\" завершился с ошибкой (код $rc) — сеть моргнула, источник недоступен, или что-то ещё пошло не так. Часть данных выше может отсутствовать."
  fi
  return "$rc"
}

pkg_install() {
  local pkg="$1"
  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null; then
      sudo_cmd="sudo"
    else
      echo "[!] Нет root и нет sudo — установить '$pkg' невозможно." >&2
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
    $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -q "$pkg"
  elif command -v dnf >/dev/null; then
    $sudo_cmd dnf makecache -q 2>/dev/null
    $sudo_cmd dnf install -y "$pkg"
  elif command -v yum >/dev/null; then
    $sudo_cmd yum makecache -q 2>/dev/null
    $sudo_cmd yum install -y "$pkg"
  elif command -v apk >/dev/null; then
    $sudo_cmd apk add --no-cache "$pkg"
  elif command -v pacman >/dev/null; then
    $sudo_cmd pacman -S --noconfirm "$pkg"
  else
    echo "Не нашёл apt/dnf/yum/apk/pacman — поставь '$pkg' вручную для своего дистрибутива."
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
  local pkg="$1" out rc
  echo "Устанавливаю $pkg (может занять пару минут)..."
  out=$(pkg_install "$pkg" </dev/null 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -15
    echo "[!] Не удалось установить $pkg."
    return "$rc"
  fi
  echo "Пакет $pkg установлен."
}

# Экспорт нужен только функциям, которые вызываются внутри `bash -c` из run()
export -f fetch_run
export -f strip_ansi

menu() {
  cat <<'EOF'
1)  YABS            - CPU/RAM/диск (fio)/сеть (iperf3, зарубеж), включая Geekbench
2)  RU Speedtest    - iperf3 до городов РФ (itdoginfo)
3)  IP Quality      - ASN, risk score, доступность сервисов, блэклисты (check.place)
4)  Geolocation     - в какой стране тебя видят сервисы (ipregion)
5)  Censorcheck     - DNS resolvers (DoH/DoT) + доступность сайтов, DPI
6)  Bench.sh        - CPU/диск (teddysun)
7)  sysbench CPU    - CPU в 1 поток и во все vCPU, сравнение (признак оверселлинга)
8)  Globalping      - доступность ЭТОГО сервера с проверочных нод в РФ (ping+mtr)
9)  Security Audit  - SSH, firewall, Docker в обход firewall, fail2ban/CrowdSec, автообновления, опасные порты + оценка
10) Disk & FS       - свободное место, inode, ошибки файловой системы
11) SSL Check       - срок сертификата, сколько дней осталось, цепочка доверия (нужен аргумент-домен)
12) Geekbench       - только Geekbench (без fio/iperf3), для сравнения CPU между хостерами
13) Censorcheck (geoblock) - не банит ли зарубежный сервис сам IP по гео (в отличие от 5 — DPI РФ)
14) Nmap outbound   - не режет ли хостер исходящие порты (SMTP, DNS/DoT) — scanme.nmap.org, Google, 1.1.1.1, 8.8.8.8
15) Speedtest до РФ - Speedtest-CLI до российских серверов (speedtest.artydev.ru)
16) Speedtest СКФО  - Speedtest-CLI до серверов Северного Кавказа (storage.umager.ru)
17) Instagram       - региональные ограничения Instagram по IP (storage.umager.ru)
18) YouTube кластер - определение кластера YouTube (storage.umager.ru)
19) Ookla Speedtest - скорость и пинг до ближайшего сервера Speedtest.net (бывший пункт 15)
0)  Все по очереди (пункты 1-10, 13-15, 17, 18; 11, 12, 16 и 19 пропускаются — см. ниже)

Запуск без аргументов, all и все — то же, что 0. В списке 0 тоже означает общий прогон: 0,11 example.com
Диапазоны: bash vps-check.sh 2,4,5-7
Вывод в файл (пишется после завершения всех проверок, а при Ctrl+C — по тому, что успело выполниться):
  bash vps-check.sh -o report.txt 9          -> чистый текстовый файл
  bash vps-check.sh -m report.md 9           -> форматированный Markdown
  bash vps-check.sh -o rep.txt -m rep.md 0   -> оба формата сразу
Без вопросов (tmux, cron): bash vps-check.sh -y 9
Пункт 9 может предложить установить fail2ban, если его нет (только с твоего согласия; -y вопрос отключает)
11 (SSL) нужен домен и не входит в общий прогон: bash vps-check.sh 11 example.com
12 (Geekbench) не входит в общий прогон: bash vps-check.sh 12
16 (Speedtest СКФО) не входит в общий прогон: bash vps-check.sh 16
19 (Ookla): конкретный сервер — OOKLA_SERVER_ID=<id> bash vps-check.sh 19 (список: speedtest -L)
EOF
}

# Короткие имена пунктов для итоговой сводки
item_name() {
  case "$1" in
    1) echo "YABS" ;;
    2) echo "RU Speedtest" ;;
    3) echo "IP Quality" ;;
    4) echo "Geolocation" ;;
    5) echo "Censorcheck (DPI)" ;;
    6) echo "Bench.sh" ;;
    7) echo "sysbench CPU" ;;
    8) echo "Globalping" ;;
    9) echo "Security Audit" ;;
    10) echo "Disk & FS" ;;
    11) echo "SSL Check" ;;
    12) echo "Geekbench" ;;
    13) echo "Censorcheck (geoblock)" ;;
    14) echo "Nmap outbound" ;;
    15) echo "Speedtest до РФ" ;;
    16) echo "Speedtest СКФО" ;;
    17) echo "Instagram" ;;
    18) echo "YouTube кластер" ;;
    19) echo "Ookla Speedtest" ;;
    *) echo "Пункт $1" ;;
  esac
}

cmd_1() { run "YABS" "fetch_run 'YABS' 'https://yabs.sh'"; }
cmd_12() { run "Geekbench (только CPU)" "fetch_run 'Geekbench' 'https://yabs.sh' -f -i"; }
cmd_2() { run "RU Speedtest (itdoginfo)" "fetch_run 'RU Speedtest' 'https://raw.githubusercontent.com/itdoginfo/russian-iperf3-servers/main/speedtest.sh'"; }
cmd_3() { run "IP Quality" "fetch_run 'IP Quality' 'https://ip.check.place' -l en"; }
cmd_4() { run "Geolocation Check" "fetch_run 'Geolocation' 'https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh'"; }
cmd_5() { run "Censorcheck (DPI mode)" "fetch_run 'Censorcheck' 'https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh' --mode dpi"; }
cmd_13() { run "Censorcheck (geoblock mode)" "fetch_run 'Censorcheck geoblock' 'https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh' --mode geoblock --no-dns"; }
cmd_6() { run "Bench.sh (Teddysun)" "fetch_run 'Bench.sh' 'https://bench.sh'"; }
cmd_7() {
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

# Сторонние тесты: скачиваются во временный файл и запускаются через fetch_run
cmd_15() { run "Speedtest до РФ (artydev)" "fetch_run 'Speedtest до РФ' 'https://speedtest.artydev.ru'"; }
cmd_16() { run "Speedtest СКФО (umager)" "fetch_run 'Speedtest СКФО' 'https://storage.umager.ru/caucasus.sh'"; }
cmd_17() { run "Instagram: региональные ограничения (umager)" "fetch_run 'Instagram' 'https://storage.umager.ru/checker_inst_ru.sh'"; }
cmd_18() { run "YouTube: кластер (umager)" "fetch_run 'YouTube кластер' 'https://storage.umager.ru/yt.sh'"; }

cmd_8() {
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
cmd_9() {
  echo -e "\n########## Security Audit (чтение; установка fail2ban — только по согласию) ##########\n"
  local is_root=0
  [ "$(id -u)" -eq 0 ] && is_root=1
  [ "$is_root" -eq 0 ] && echo "[!] Запущено не от root — ss/dmesg/iptables/nft/fail2ban-client могут отдать урезанный или пустой вывод. Для полной картины: sudo bash vps-check.sh 9"
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
      echo "Состояние firewall не удалось проверить без root (ufw, iptables и nft требуют права) — минус не засчитан. Для точной оценки: sudo bash vps-check.sh 9"
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
  f2b_ask() {
    local ans
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
    f2b_ask "Установить fail2ban сейчас? Будет поставлен пакет и запущена служба (изменение системы, нужен root или sudo)"
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
    f2b_ask "Запустить fail2ban сейчас? Служба будет включена в автозагрузку и запущена (изменение системы, нужен root или sudo)"
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
cmd_10() {
  echo -e "\n########## Disk & Filesystem ##########\n"
  local SWAP_TOTAL RO_MOUNTS FS_ERRORS dev
  [ "$(id -u)" -ne 0 ] && echo "[!] Запущено не от root — dmesg может вернуть пусто из-за kernel.dmesg_restrict. Для полной картины: sudo bash vps-check.sh 10"
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
cmd_11() {
  local domain="${1:-$TARGET_DOMAIN}"
  echo -e "\n########## SSL Check ##########\n"
  if [ -z "$domain" ]; then
    echo "Нужен домен: bash vps-check.sh 11 example.com"
    mark_skipped
    return 1
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
cmd_14() {
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
# Для другой версии можно передать хеш напрямую: OOKLA_SHA256=<хеш> OOKLA_VERSION=<версия> bash vps-check.sh 19
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

# ---------- 19. Ookla Speedtest (ближайший сервер) ----------
# Официальный Speedtest CLI от Ookla. Бинарь скачивается архивом во временную
# папку и удаляется после теста — в систему ничего не ставится.
# Необязательно: OOKLA_SERVER_ID=<id> bash vps-check.sh 19  (список серверов: speedtest -L)
cmd_19() {
  echo -e "\n########## Ookla Speedtest ##########\n"
  local st tmpdir="" arch url rc
  st=$(command -v speedtest 2>/dev/null) || st=""

  # у python-speedtest-cli бинарь тоже называется speedtest, поэтому проверяем, что он от Ookla
  if [ -z "$st" ] || ! "$st" --version 2>&1 | grep -qi ookla; then
    case "$(uname -m)" in
      x86_64)        arch="x86_64" ;;
      aarch64|arm64) arch="aarch64" ;;
      armv7l)        arch="armhf" ;;
      i386|i686)     arch="i386" ;;
      *)
        echo "[i] Для архитектуры $(uname -m) у Ookla нет официального CLI (есть x86_64, i386, armhf, aarch64) — пропускаю пункт."
        mark_skipped
        return
        ;;
    esac

    # Папка внутри WORKDIR: если тест прервут по Ctrl+C, её удалит общая очистка
    tmpdir=$(mktemp -d "${WORKDIR:-${TMPDIR:-/tmp}}/ookla-XXXXXX") || {
      echo "[!] Не удалось создать временную папку для Ookla CLI" >&2
      return 1
    }

    url="https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-${arch}.tgz"
    local tgz="$tmpdir/ookla.tgz"
    if ! { curl -fsSL --connect-timeout 5 --max-time 30 -o "$tgz" "$url" 2>/dev/null \
           || wget -qO "$tgz" --timeout=30 "$url" 2>/dev/null; } \
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
    st="$tmpdir/speedtest"
  fi

  local st_args=(--accept-license --accept-gdpr --progress=no)
  [ -n "${OOKLA_SERVER_ID:-}" ] && st_args+=(-s "$OOKLA_SERVER_ID")

  run_with_timeout 180 "$st" "${st_args[@]}"
  rc=$?

  [ -n "$tmpdir" ] && rm -rf "$tmpdir"

  if [ "$rc" -eq 126 ]; then
    echo "[!] Бинарь Ookla не запустился (код 126): похоже, временная папка лежит на разделе с noexec. Запусти так: mkdir -p ~/tmp && TMPDIR=~/tmp bash vps-check.sh 19"
    return "$rc"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[!] Пункт \"Ookla Speedtest\" завершился с ошибкой (код $rc) — сеть моргнула, сервер Speedtest недоступен или тест не уложился в 180 секунд."
    return "$rc"
  fi
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

  # Geekbench — из YABS (пункт 1) или пункта 12
  local gb_ver gb_single gb_multi
  gb_ver=$(sed -nE 's/^Geekbench ([0-9]+) Benchmark Test:.*/\1/p' "$clean_file" | head -1)
  gb_single=$(sed -nE 's/^[[:space:]]*Single Core[[:space:]]*\|[[:space:]]*([0-9]+).*/\1/p' "$clean_file" | head -1)
  gb_multi=$(sed -nE 's/^[[:space:]]*Multi Core[[:space:]]*\|[[:space:]]*([0-9]+).*/\1/p' "$clean_file" | head -1)

  # Масштабирование sysbench (пункт 7)
  local sb_scale
  sb_scale=$(sed -nE 's/.*прирост ×([0-9.]+) \(идеал ≈ ×([0-9]+)\).*/×\1 при идеале ×\2/p' "$clean_file" | head -1)

  # Итог Ookla Speedtest (если запускался пункт 19): берём только текст его раздела
  local ookla_block ookla_dl ookla_ul ookla_lat
  ookla_block=$(awk '/^########## Ookla Speedtest ##########$/ {f=1; next} /^########## / {f=0} f' "$clean_file")
  ookla_dl=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Download:[[:space:]]*([0-9.]+ [KMG]bps).*/\1/p' | head -1)
  ookla_ul=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Upload:[[:space:]]*([0-9.]+ [KMG]bps).*/\1/p' | head -1)
  ookla_lat=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Latency:[[:space:]]*([0-9.]+ ms).*/\1/p' | head -1)

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
    echo "## Результаты проверок"

    # Литерал ########## вместо #{10}: старый mawk (Debian 12, Ubuntu 22.04) не понимает {n} в регулярках.
    # Раздел «Итог прогона» пропускаем — он уже выведен таблицей выше.
    awk '
      BEGIN { in_block = 0 }
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

# ---------- разбор аргументов 2,4,5-7 ----------
expand_selection() {
  local input="$1"
  local result=""
  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    part="${part// /}"
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local start="${BASH_REMATCH[1]}"
      local end="${BASH_REMATCH[2]}"
      if [ "$start" -gt "$end" ]; then
        echo "Пропускаю некорректный диапазон $part (начало больше конца)" >&2
        continue
      fi
      [ "$start" -lt "$MIN_ITEM" ] && { echo "Диапазон $part выходит за $MIN_ITEM-$MAX_ITEM, обрезаю до $MIN_ITEM" >&2; start=$MIN_ITEM; }
      [ "$end" -gt "$MAX_ITEM" ] && { echo "Диапазон $part выходит за $MIN_ITEM-$MAX_ITEM, обрезаю до $MAX_ITEM" >&2; end=$MAX_ITEM; }
      if [ "$start" -le 11 ] && [ "$end" -ge 11 ]; then
        echo "Внимание: диапазон $part включает пункт 11 (SSL Check) — нужен домен вторым аргументом" >&2
      fi
      if [ "$start" -le 12 ] && [ "$end" -ge 12 ]; then
        echo "Внимание: диапазон $part включает пункт 12 (Geekbench) — это долгий тест (5-10 минут)" >&2
      fi
      for ((i=start; i<=end; i++)); do
        case " $result " in *" $i "*) continue ;; esac
        result="$result $i"
      done
    elif [ "$part" = "0" ]; then
      # 0 внутри списка — общий прогон (например, 0,11 example.com)
      for i in $DEFAULT_ITEMS; do
        case " $result " in *" $i "*) continue ;; esac
        result="$result $i"
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      if [ "$part" -lt "$MIN_ITEM" ] || [ "$part" -gt "$MAX_ITEM" ]; then
        echo "Пункта $part не существует (доступны $MIN_ITEM-$MAX_ITEM), пропускаю" >&2
        continue
      fi
      case " $result " in *" $part "*) continue ;; esac
      result="$result $part"
    fi
  done
  echo "$result"
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
  if [ "$n" = "11" ]; then
    ( trap 'exit 130' INT; cmd_11 "$extra" )
  else
    ( trap 'exit 130' INT; "cmd_$n" )
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
  local items n count=0 general=0
  FAILED=0
  # Флаг вместо смерти по сигналу: некоторые сторонние скрипты (например, YABS) сами ловят Ctrl+C
  # и выходят с кодом 0 — без флага прогон после этого просто шёл бы к следующему пункту
  STOP=0
  trap 'STOP=1' INT
  case "$mode" in
    ""|все|all|0) items="$DEFAULT_ITEMS"; general=1 ;;
    11) items="11" ;;
    *) items=$(expand_selection "$mode") ;;   # предупреждения («пункта 99 нет») видны пользователю
  esac

  for n in $items; do
    [ "$STOP" -eq 1 ] && break
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
  if [ "$general" -eq 1 ]; then
    echo
    echo "(пункт 11 — SSL Check — пропущен, нужен домен: bash vps-check.sh 11 example.com)"
    echo "(пункт 12 — Geekbench отдельно — пропущен, CPU уже покрыт пунктом 1 (YABS))"
    echo "(пункты 16 — Speedtest СКФО — и 19 — Ookla — пропущены: запускай вручную)"
  fi
  [ "$FAILED" -eq 0 ]
}

# ---------- валидация аргументов и ранний выход ----------
case "$ARG" in
  menu|-h|--help)
    menu
    exit 0
    ;;
  ""|все|all|0|11)
    : ;;
  *[0-9]*)
    if [[ ! "$ARG" =~ ^[0-9,-]+$ ]] || [ -z "$(expand_selection "$ARG" 2>/dev/null)" ]; then
      echo "Неизвестный или некорректный аргумент: $ARG" >&2
      menu
      exit 1
    fi
    ;;
  *)
    echo "Неизвестный аргумент: $ARG" >&2
    menu
    exit 1
    ;;
esac

# Второй позиционный аргумент нужен только пункту 11
if [ -n "$TARGET_DOMAIN" ]; then
  case " $(expand_selection "$ARG" 2>/dev/null) " in
    *" 11 "*) : ;;
    *) echo "[i] Второй аргумент «$TARGET_DOMAIN» используется только пунктом 11 (SSL) и будет проигнорирован. Несколько пунктов задаются через запятую: 3,5" >&2 ;;
  esac
fi

# Ctrl+C во время вопросов — просто выходим
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------- интерактивные вопросы (только если запуск в реальном TTY) ----------
CACHE_AND_SHOW=false
if [ -t 0 ] && [ "$NO_PROMPT" -eq 0 ]; then
  read -rp "Кэшировать вывод и показать его ещё раз одним куском в конце? [y/N]: " CACHE_ANS
  [[ "$CACHE_ANS" =~ ^[Yy] ]] && CACHE_AND_SHOW=true

  # Если пути к файлам отчетов не были переданы через флаги CLI — спрашиваем интерактивно
  if [ -z "$OUTPUT_TXT" ] && [ -z "$OUTPUT_MD" ]; then
    read -rp "Сохранить отчёт в файл? [1: Нет (Enter), 2: TXT, 3: Markdown, 4: Оба]: " REP_ANS
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
  echo
fi

# ---------- рабочая папка и очистка ----------
# Учитывает TMPDIR: если /tmp смонтирован с noexec (пункт 19 запускает бинарь), можно указать другую папку
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
dispatch "$ARG" "$TARGET_DOMAIN" 2>&1 | tee -i "$TEMP_RAW"
PIPE_RC=("${PIPESTATUS[@]}")   # оба кода сразу: PIPESTATUS сбрасывается следующей же командой
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
