#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки
# Запуск:
#   bash vps-check.sh                      -> интерактивный запуск (пункты 1-10, 13-15)
#   bash vps-check.sh -o report.txt        -> сохранить чистый TXT отчёт
#   bash vps-check.sh -m report.md         -> сгенерировать форматированный Markdown
#   bash vps-check.sh -o rep.txt -m rep.md -> сохранить оба отчёта сразу
#   bash vps-check.sh -y 9                 -> без интерактивных вопросов (tmux, cron)
#   bash vps-check.sh 3                    -> только пункт 3
#   bash vps-check.sh 2,4,5-7              -> пункты 2, 4, 5, 6, 7
#   bash vps-check.sh menu                 -> список пунктов

MIN_ITEM=1
MAX_ITEM=15

# Пункты общего прогона (аргумент 0 / all / без аргументов). 11 и 12 — только вручную.
DEFAULT_ITEMS="1 2 3 4 5 6 7 8 9 10 13 14 15"

# Глобальные переменные для очистки временных файлов при выходе (в том числе по Ctrl+C)
TEMP_RAW=""
CLEAN_FILE=""
OOKLA_TMPDIR=""
NO_PROMPT=0

# Версия официального Speedtest CLI от Ookla (пункт 15). Если ссылка на скачивание
# перестала работать — проверь актуальную версию на https://www.speedtest.net/apps/cli
# Переопределить без правки файла: OOKLA_VERSION=1.2.0 bash vps-check.sh 15
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
  # printf вместо \x1b и \r: работает и в busybox/BSD sed
  local esc cr
  esc=$(printf '\033')
  cr=$(printf '\r')
  sed -e "s/${esc}\[[0-9;]*[a-zA-Z]//g" -e "s/${esc}([B0]//g" -e "s/${cr}//g"
}

fetch_run() {
  local label="$1"
  local url="$2"
  shift 2
  local content=""

  content=$(curl -fsSL --connect-timeout 5 --max-time 30 "$url" 2>/dev/null) || \
  content=$(wget -qO- --timeout=30 "$url" 2>/dev/null)

  if [ -z "$content" ]; then
    echo "[!] Не удалось скачать скрипт для \"$label\" ($url) — таймаут или зеркало недоступно."
    return 1
  fi

  local tmp
  tmp=$(mktemp /tmp/vps-run-XXXXXX.sh) || {
    echo "[!] Не удалось создать временный файл в /tmp для \"$label\"" >&2
    return 1
  }
  printf '%s\n' "$content" > "$tmp"
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

  if command -v apt >/dev/null; then
    if ! $sudo_cmd apt update -qq 2>/dev/null; then
      echo "[i] apt update не удался — возможно, нет сети до зеркал репозитория."
    fi
    # env внутри sudo: так DEBIAN_FRONTEND доходит до apt, даже если sudo сбрасывает окружение
    $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt install -y "$pkg"
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

export -f fetch_run
export -f strip_ansi
export -f pkg_install

menu() {
  cat <<'EOF'
1)  YABS            - CPU/RAM/диск (fio)/сеть (iperf3, зарубеж), включая Geekbench
2)  RU Speedtest    - iperf3 до городов РФ (itdoginfo)
3)  IP Quality      - ASN, risk score, доступность сервисов, блэклисты (check.place)
4)  Geolocation     - в какой стране тебя видят сервисы (ipregion)
5)  Censorcheck     - DNS resolvers (DoH/DoT) + доступность сайтов, DPI
6)  Bench.sh        - CPU/диск (teddysun)
7)  sysbench CPU    - однопоточный CPU-тест
8)  Globalping      - доступность ЭТОГО сервера с проверочных нод в РФ (ping+mtr)
9)  Security Audit  - SSH-конфиг, firewall (ufw/iptables/nft), fail2ban/crowdsec, автообновления, открытые порты + оценка
10) Disk & FS       - свободное место, inode, ошибки файловой системы
11) SSL Check       - срок действия сертификата домена (нужен аргумент-домен)
12) Geekbench       - только Geekbench (без fio/iperf3), для сравнения CPU между хостерами
13) Censorcheck (geoblock) - не банит ли зарубежный сервис сам IP по гео (в отличие от 5 — DPI РФ)
14) Nmap outbound   - не режет ли хостер исходящие порты (SMTP, DNS/DoT) — scanme.nmap.org, smtp.gmail.com, 1.1.1.1, 8.8.8.8
15) Ookla Speedtest - скорость и пинг до ближайшего сервера Speedtest.net (официальный CLI)
0)  Все по очереди (пункты 1-10, 13-15; 11 и 12 пропускаются — см. ниже)

Запуск без аргументов, all и все — то же, что 0. В списке 0 тоже означает общий прогон: 0,11 example.com
Диапазоны: bash vps-check.sh 2,4,5-7
Вывод в файл (пишется после завершения всех проверок):
  bash vps-check.sh -o report.txt 9          -> чистый текстовый файл
  bash vps-check.sh -m report.md 9           -> форматированный Markdown
  bash vps-check.sh -o rep.txt -m rep.md 0   -> оба формата сразу
Без вопросов (tmux, cron): bash vps-check.sh -y 9
Пункт 9 может предложить установить fail2ban, если его нет (только с твоего согласия; -y вопрос отключает)
11 (SSL) нужен домен и не входит в общий прогон: bash vps-check.sh 11 example.com
12 (Geekbench) не входит в общий прогон: bash vps-check.sh 12
15 (Ookla): конкретный сервер — OOKLA_SERVER_ID=<id> bash vps-check.sh 15 (список: speedtest -L)
EOF
}

cmd_1() { run "YABS" "fetch_run 'YABS' 'https://yabs.sh'"; }
cmd_12() { run "Geekbench (только CPU)" "fetch_run 'Geekbench' 'https://yabs.sh' -f -i"; }
cmd_2() { run "RU Speedtest (itdoginfo)" "fetch_run 'RU Speedtest' 'https://raw.githubusercontent.com/itdoginfo/russian-iperf3-servers/main/speedtest.sh'"; }
cmd_3() { run "IP Quality" "fetch_run 'IP Quality' 'https://ip.check.place' -l en"; }
cmd_4() { run "Geolocation Check" "fetch_run 'Geolocation' 'https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh'"; }
cmd_5() { run "Censorcheck (DPI mode)" "fetch_run 'Censorcheck' 'https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh' --mode dpi"; }
cmd_13() { run "Censorcheck (geoblock mode)" "fetch_run 'Censorcheck geoblock' 'https://raw.githubusercontent.com/vernette/censorcheck/master/censorcheck.sh' --mode geoblock --no-dns"; }
cmd_6() { run "Bench.sh (Teddysun)" "fetch_run 'Bench.sh' 'https://bench.sh'"; }
cmd_7() { run "sysbench CPU" "command -v sysbench >/dev/null || pkg_install sysbench; if command -v sysbench >/dev/null; then sysbench cpu run --threads=1; else echo '[i] sysbench не установлен, тест пропущен'; fi"; }

cmd_8() {
  echo -e "\n########## Globalping (доступность этого сервера из РФ) ##########\n"
  local sudo_cmd=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo_cmd="sudo"

  if ! command -v globalping >/dev/null; then
    if [ "$(id -u)" -ne 0 ] && [ -z "$sudo_cmd" ]; then
      echo "[i] Запущено не от root и утилита sudo не найдена — автоматическая установка globalping невозможна. Пропускаю пункт."
      return
    fi

    if command -v apt >/dev/null; then
      curl -fsSL https://packagecloud.io/install/repositories/jsdelivr/globalping/script.deb.sh | $sudo_cmd bash >/dev/null 2>&1
      $sudo_cmd apt install -y globalping >/dev/null 2>&1
    elif command -v dnf >/dev/null; then
      curl -fsSL https://packagecloud.io/install/repositories/jsdelivr/globalping/script.rpm.sh | $sudo_cmd bash >/dev/null 2>&1
      $sudo_cmd dnf install -y globalping >/dev/null 2>&1
    elif command -v brew >/dev/null; then
      brew tap jsdelivr/globalping >/dev/null 2>&1
      brew install globalping >/dev/null 2>&1
    else
      echo "Официальных пакетов globalping для этого дистрибутива нет (apt/dnf/brew поддерживаются): https://github.com/jsdelivr/globalping-cli"
    fi
  fi
  if ! command -v globalping >/dev/null; then
    echo "globalping не установлен, пропускаю проверку."
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

# ---------- 9. Security Audit ----------
cmd_9() {
  echo -e "\n########## Security Audit (чтение; установка fail2ban — только по согласию) ##########\n"
  [ "$(id -u)" -ne 0 ] && echo "[!] Запущено не от root — ss/dmesg/iptables/nft/fail2ban-client могут отдать урезанный или пустой вывод. Для полной картины: sudo bash vps-check.sh 9"
  echo

  SCORE=100
  FW_UNVERIFIED=0
  deduct() {
    SCORE=$((SCORE - $1))
    echo "  [-$1] $2"
  }

  echo "=== SSH-конфигурация ==="
  SSHD_FILES=()
  shopt -s nullglob
  [ -d /etc/ssh/sshd_config.d ] && SSHD_FILES+=(/etc/ssh/sshd_config.d/*.conf)
  shopt -u nullglob
  [ -r /etc/ssh/sshd_config ] && SSHD_FILES+=(/etc/ssh/sshd_config)

  get_ssh() {
    local key="$1"
    local val=""
    if command -v sshd >/dev/null && sshd_test=$(sshd -T 2>/dev/null); then
      val=$(echo "$sshd_test" | grep -i "^${key}[[:space:]]" | head -1 | awk '{print $2}')
    fi
    if [ -z "$val" ] && [ ${#SSHD_FILES[@]} -gt 0 ]; then
      val=$(cat "${SSHD_FILES[@]}" 2>/dev/null | grep -iE "^[[:space:]]*${key}[[:space:]]+" | head -1 | awk '{print $2}')
    fi
    echo "${val:-не задано}"
  }

  ROOT_LOGIN=$(get_ssh PermitRootLogin)
  PASS_AUTH=$(get_ssh PasswordAuthentication)
  SSH_PORT=$(get_ssh Port)
  PUBKEY_AUTH=$(get_ssh PubkeyAuthentication)
  EMPTY_PASS=$(get_ssh PermitEmptyPasswords)

  echo "PermitRootLogin:        $ROOT_LOGIN"
  echo "PasswordAuthentication: $PASS_AUTH"
  echo "Port:                   ${SSH_PORT:-22 (по умолчанию)}"
  echo "PubkeyAuthentication:   $PUBKEY_AUTH"
  echo "PermitEmptyPasswords:   $EMPTY_PASS"

  case "$ROOT_LOGIN" in
    yes) deduct 20 "root может логиниться по SSH напрямую (PermitRootLogin yes)" ;;
  esac
  case "$PASS_AUTH" in
    yes|"не задано") deduct 20 "разрешён вход по паролю (PasswordAuthentication yes/не задано — по умолчанию yes)" ;;
  esac
  case "$EMPTY_PASS" in
    yes) deduct 20 "разрешён вход по SSH с пустым паролем (PermitEmptyPasswords yes)" ;;
  esac

  echo
  echo "=== Учётные записи без пароля ==="
  if [ "$(id -u)" -ne 0 ]; then
    echo "недоступно без root (нужно читать /etc/shadow)"
  elif [ -r /etc/shadow ]; then
    EMPTY_PW_USERS=$(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null)
    if [ -n "$EMPTY_PW_USERS" ]; then
      echo "Найдены учётные записи с пустым паролем (вход без пароля):"
      echo "$EMPTY_PW_USERS" | sed 's/^/  [!] /'
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
      if [ "$(id -u)" -ne 0 ]; then
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
    echo "--- iptables (сырые правила) ---"
    if [ "$(id -u)" -ne 0 ]; then
      echo "правила недоступны без root"
    else
      RULES=$(iptables -L -n 2>/dev/null)
      echo "$RULES"
      if echo "$RULES" | grep -qE "^(ACCEPT|DROP|REJECT)"; then
        FW_ACTIVE=1
      fi
    fi
  fi
  if command -v nft >/dev/null && [ "$FW_ACTIVE" -eq 0 ]; then
    echo "--- nftables ---"
    NFT_RULES=""
    if [ "$(id -u)" -eq 0 ]; then
      NFT_RULES=$(nft list ruleset 2>/dev/null)
    fi
    if [ "$(id -u)" -ne 0 ]; then
      echo "ruleset недоступен без root"
    elif [ -n "$NFT_RULES" ]; then
      echo "$NFT_RULES" | head -40
      if [ "$(echo "$NFT_RULES" | wc -l)" -gt 40 ]; then
        echo "... (показаны первые 40 строк ruleset)"
      fi
      # активным считаем ruleset с правилами-вердиктами или цепочкой с policy drop
      if echo "$NFT_RULES" | grep -qE '(^|[[:space:]])(accept|drop|reject)([[:space:]]+comment[[:space:]].*)?[[:space:]]*$|(^|[[:space:]])(jump|goto)[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]*$|policy[[:space:]]+drop'; then
        FW_ACTIVE=1
      fi
    else
      echo "ruleset пуст (правил нет)."
    fi
  fi
  if [ "$FW_ACTIVE" -eq 0 ]; then
    if [ "$(id -u)" -ne 0 ]; then
      echo "Состояние firewall не удалось проверить без root (ufw, iptables и nft требуют права) — минус не засчитан. Для точной оценки: sudo bash vps-check.sh 9"
      FW_UNVERIFIED=1
    else
      echo "Активный firewall не обнаружен (ufw/firewalld неактивны, осмысленных правил iptables нет)."
      deduct 25 "нет активного firewall"
    fi
  fi

  echo
  echo "=== Защита от брутфорса ==="
  F2B_ACTIVE=0
  F2B_SUDO=""    # префикс для запуска команд
  F2B_HINT=""    # префикс для подсказок пользователю
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null; then
      F2B_SUDO="sudo "
      F2B_HINT="sudo "
    else
      F2B_HINT="(от root) "
    fi
  fi

  # Команда установки для подсказки (сама установка — через pkg_install)
  f2b_install_hint() {
    if command -v apt >/dev/null; then echo "${F2B_HINT}apt install -y fail2ban"
    elif command -v dnf >/dev/null; then echo "${F2B_HINT}dnf install -y fail2ban (на RHEL-совместимых системах сначала epel-release)"
    elif command -v yum >/dev/null; then echo "${F2B_HINT}yum install -y fail2ban (на RHEL-совместимых системах сначала epel-release)"
    elif command -v apk >/dev/null; then echo "${F2B_HINT}apk add fail2ban"
    elif command -v pacman >/dev/null; then echo "${F2B_HINT}pacman -S fail2ban"
    else echo "установи пакет fail2ban средствами своего дистрибутива"
    fi
  }

  # Предложение установить fail2ban: только в интерактивном режиме и только с согласия
  f2b_offer_install() {
    local hint ans
    hint=$(f2b_install_hint)
    if [ ! -t 0 ]; then
      echo "Нет терминала — установка пропущена. Вручную: ${hint}"
      return
    fi
    if [ "$NO_PROMPT" -eq 1 ]; then
      echo "Флаг -y отключает вопросы — установка пропущена. Вручную: ${hint}"
      return
    fi
    read -rp "Установить fail2ban сейчас? Будет поставлен пакет и запущена служба (изменение системы, нужен root или sudo) [y/N]: " ans
    if ! [[ "$ans" =~ ^[Yy] ]]; then
      echo "Установка пропущена. Вручную: ${hint}"
      return
    fi

    # Лог пакетного менеджера в отчёты не попадает: при успехе — одна строка, при сбое — его хвост
    local inst_out inst_rc
    echo "Устанавливаю fail2ban (может занять до минуты)..."
    inst_out=$(pkg_install fail2ban </dev/null 2>&1)
    inst_rc=$?
    if [ "$inst_rc" -ne 0 ]; then
      echo "$inst_out" | tail -15
      echo "[!] Не удалось установить fail2ban. На RHEL-совместимых системах пакет лежит в EPEL (сначала epel-release)."
      return
    fi
    echo "Пакет fail2ban установлен."

    if ! command -v systemctl >/dev/null; then
      echo "systemd не найден — запусти службу fail2ban вручную средствами своей init-системы."
      return
    fi
    ${F2B_SUDO}systemctl enable --now fail2ban >/dev/null 2>&1
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
      local st
      echo "fail2ban запущен."
      F2B_ACTIVE=1
      st=$(${F2B_SUDO}fail2ban-client status 2>/dev/null)
      echo "$st"
      if echo "$st" | grep -qE "Number of jail:[[:space:]]+0"; then
        echo "Jail'ов нет — защита SSH ещё не включена. Добавь в /etc/fail2ban/jail.local:"
        echo "  [sshd]"
        echo "  enabled = true"
        echo "и перезапусти службу: ${F2B_HINT}systemctl restart fail2ban"
      fi
    else
      echo "[!] Пакет установлен, но служба не запустилась. Смотри: ${F2B_HINT}systemctl status fail2ban"
    fi
  }

  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "fail2ban запущен (systemctl is-active). Активные jail'ы:"
    fail2ban-client status 2>/dev/null || echo "(команда fail2ban-client недоступна для чтения статуса)"
    F2B_ACTIVE=1
  elif command -v fail2ban-client >/dev/null; then
    echo "fail2ban установлен, но НЕ запущен. Запустить: ${F2B_HINT}systemctl enable --now fail2ban"
  elif command -v cscli >/dev/null && systemctl is-active --quiet crowdsec 2>/dev/null; then
    echo "CrowdSec установлен и запущен."
    cscli metrics 2>/dev/null | head -20
    F2B_ACTIVE=1
  elif command -v cscli >/dev/null; then
    echo "CrowdSec установлен, но сервис не запущен."
  else
    echo "fail2ban и CrowdSec не найдены."
    f2b_offer_install
  fi
  if [ "$F2B_ACTIVE" -eq 0 ]; then
    deduct 15 "нет активной защиты от брутфорса (fail2ban/CrowdSec не запущены)"
  fi

  echo
  echo "=== Автообновления безопасности ==="
  UPD_OK=0
  if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    echo "unattended-upgrades установлен."
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null || systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
      echo "и включён (через systemd сервис или apt-daily-upgrade.timer)."
      UPD_OK=1
    else
      echo "но не включён в systemd."
    fi
  elif command -v dnf >/dev/null && rpm -q dnf-automatic >/dev/null 2>&1; then
    echo "dnf-automatic установлен."
    if systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null || systemctl is-active --quiet dnf-automatic.timer 2>/dev/null; then
      echo "и активен dnf-automatic.timer."
      UPD_OK=1
    else
      echo "таймер dnf-automatic.timer не включён."
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
  elif command -v needs-restarting >/dev/null && [ "$(id -u)" -eq 0 ]; then
    needs-restarting -r >/dev/null 2>&1
    case $? in
      0) echo "Перезагрузка не требуется (needs-restarting -r)." ;;
      1) echo "Нужна перезагрузка (needs-restarting -r сообщает об обновлениях ядра/системных библиотек)." ;;
      *) echo "needs-restarting -r завершился с неожиданным кодом — состояние перезагрузки определить не удалось." ;;
    esac
  elif command -v needrestart >/dev/null && [ "$(id -u)" -eq 0 ]; then
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
    echo "Нет ни ss, ни netstat — установи iproute2 (apt install -y iproute2), чтобы увидеть список портов."
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
    echo "smartctl не установлен (apt install -y smartmontools) — для VPS часто бесполезно, диск виртуальный."
  fi
}

# ---------- 11. SSL Check ----------
cmd_11() {
  local domain="${1:-$TARGET_DOMAIN}"
  echo -e "\n########## SSL Check ##########\n"
  if [ -z "$domain" ]; then
    echo "Нужен домен: bash vps-check.sh 11 example.com"
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

  echo "Проверяю сертификат для: $target"
  local cert
  if [ "$is_ipv6" -eq 1 ]; then
    # SNI для IP-адреса не используется
    cert=$(echo | openssl s_client -connect "$target" 2>/dev/null)
  else
    cert=$(echo | openssl s_client -servername "$domain" -connect "$target" 2>/dev/null)
  fi
  printf '%s\n' "$cert" \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null \
    || echo "Не удалось получить сертификат ($target) — сервер не отвечает, на порту нет TLS или openssl не установлен."
}

# ---------- 14. Nmap outbound ----------
cmd_14() {
  echo -e "\n########## Nmap outbound (не режет ли хостер исходящие порты) ##########\n"
  command -v nmap >/dev/null || pkg_install nmap
  if ! command -v nmap >/dev/null; then
    echo "nmap не установлен, пропускаю проверку."
    return
  fi

  echo "=== Общая проверка (45.33.32.156 = scanme.nmap.org, официальная тестовая цель Nmap) ==="
  nmap -Pn -n --host-timeout 20s -p 22,80,443,9929,31337 45.33.32.156

  echo
  echo "=== Исходящий SMTP (часто режут хостеры для борьбы со спамом) ==="
  echo "--- Порт 25 (MX-сервер Google: 142.250.27.27) ---"
  nmap -Pn -n --host-timeout 20s -p 25 142.250.27.27

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
# Для другой версии можно передать хеш напрямую: OOKLA_SHA256=<хеш> OOKLA_VERSION=<версия> bash vps-check.sh 15
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

# ---------- 15. Ookla Speedtest ----------
# Официальный Speedtest CLI от Ookla. Бинарь скачивается архивом во временную
# папку и удаляется после теста — в систему ничего не ставится.
# Необязательно: OOKLA_SERVER_ID=<id> bash vps-check.sh 15  (список серверов: speedtest -L)
cmd_15() {
  echo -e "\n########## Ookla Speedtest ##########\n"
  local st tmpdir="" arch url rc
  st=$(command -v speedtest)

  # у python-speedtest-cli бинарь тоже называется speedtest, поэтому проверяем, что он от Ookla
  if [ -z "$st" ] || ! "$st" --version 2>&1 | grep -qi ookla; then
    case "$(uname -m)" in
      x86_64)        arch="x86_64" ;;
      aarch64|arm64) arch="aarch64" ;;
      armv7l)        arch="armhf" ;;
      i386|i686)     arch="i386" ;;
      *)
        echo "[i] Для архитектуры $(uname -m) у Ookla нет официального CLI (есть x86_64, i386, armhf, aarch64) — пропускаю пункт."
        return
        ;;
    esac

    tmpdir=$(mktemp -d /tmp/vps-ookla-XXXXXX) || {
      echo "[!] Не удалось создать временную папку в /tmp для Ookla CLI" >&2
      return 1
    }
    OOKLA_TMPDIR="$tmpdir"

    url="https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-${arch}.tgz"
    local tgz="$tmpdir/ookla.tgz"
    if ! { curl -fsSL --connect-timeout 5 --max-time 30 -o "$tgz" "$url" 2>/dev/null \
           || wget -qO "$tgz" --timeout=30 "$url" 2>/dev/null; } \
       || [ ! -s "$tgz" ]; then
      echo "[!] Не удалось скачать Ookla Speedtest CLI ($url) — сеть недоступна или версия в ссылке устарела (поменяй OOKLA_VERSION в начале скрипта)."
      rm -rf "$tmpdir"
      OOKLA_TMPDIR=""
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
        OOKLA_TMPDIR=""
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
      OOKLA_TMPDIR=""
      return 1
    fi
    st="$tmpdir/speedtest"
  fi

  local st_args=(--accept-license --accept-gdpr --progress=no)
  [ -n "${OOKLA_SERVER_ID:-}" ] && st_args+=(-s "$OOKLA_SERVER_ID")

  if command -v timeout >/dev/null; then
    timeout 180 "$st" "${st_args[@]}"
  else
    "$st" "${st_args[@]}"
  fi
  rc=$?

  if [ -n "$tmpdir" ]; then
    rm -rf "$tmpdir"
    OOKLA_TMPDIR=""
  fi

  if [ "$rc" -ne 0 ]; then
    echo "[!] Пункт \"Ookla Speedtest\" завершился с ошибкой (код $rc) — сеть моргнула, сервер Speedtest недоступен или тест не уложился в 180 секунд."
    return "$rc"
  fi
}

# ---------- генератор Markdown-отчёта ----------
generate_markdown_report() {
  local raw_file="$1"
  local md_file="$2"

  local clean_file
  clean_file=$(mktemp /tmp/vps-clean-XXXXXX.log) || {
    echo "[!] Не удалось создать временный файл для очистки отчёта" >&2
    return 1
  }
  CLEAN_FILE="$clean_file"
  strip_ansi < "$raw_file" > "$clean_file"

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

  # Итог Ookla Speedtest (если запускался пункт 15): берём только текст его раздела
  local ookla_block ookla_dl ookla_ul ookla_lat
  ookla_block=$(awk '/^########## Ookla Speedtest ##########$/ {f=1; next} /^########## / {f=0} f' "$clean_file")
  ookla_dl=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Download:[[:space:]]*([0-9.]+ [KMG]bps).*/\1/p' | head -1)
  ookla_ul=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Upload:[[:space:]]*([0-9.]+ [KMG]bps).*/\1/p' | head -1)
  ookla_lat=$(printf '%s\n' "$ookla_block" | sed -nE 's/.*Latency:[[:space:]]*([0-9.]+ ms).*/\1/p' | head -1)

  cat <<EOF > "$md_file"
# Отчёт проверки VPS

| Параметр | Значение |
| :--- | :--- |
| **Дата проверки** | $report_date |
| **ОС** | $os_info |
| **Ядро Linux** | $kernel_info |
| **Процессор** | $cpu_info ($cpu_cores vCPU) |
| **Оперативная память** | $ram_info |
EOF

  if [ -n "$sec_score" ]; then
    echo "| **Аудит безопасности** | $sec_score |" >> "$md_file"
  fi

  if [ -n "$ookla_dl" ] && [ -n "$ookla_ul" ]; then
    if [ -n "$ookla_lat" ]; then
      echo "| **Ookla Speedtest** | ↓ $ookla_dl / ↑ $ookla_ul, задержка $ookla_lat |" >> "$md_file"
    else
      echo "| **Ookla Speedtest** | ↓ $ookla_dl / ↑ $ookla_ul |" >> "$md_file"
    fi
  fi

  echo -e "\n---\n" >> "$md_file"
  echo "## Результаты проверок" >> "$md_file"

  awk '
    BEGIN { in_block = 0 }
    /^#{10} .+ #{10}$/ {
      if (in_block) {
        print "```\n"
      }
      sub(/^########## /, "")
      sub(/ ##########$/, "")
      print "\n### " $0 "\n"
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
  ' "$clean_file" >> "$md_file"

  rm -f "$clean_file"
  CLEAN_FILE=""
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
dispatch() {
  local mode="${1:-$ARG}"
  local extra="${2:-$TARGET_DOMAIN}"
  case "$mode" in
    ""|все|all|0)
      for i in $DEFAULT_ITEMS; do "cmd_$i"; done
      echo -e "\n(пункт 11 — SSL Check — пропущен, нужен домен: bash vps-check.sh 11 example.com)"
      echo "(пункт 12 — Geekbench отдельно — пропущен, CPU уже покрыт пунктом 1 (YABS))"
      ;;
    11)
      cmd_11 "$extra"
      ;;
    *[0-9]*)
      for n in $(expand_selection "$mode"); do
        if [ "$n" = "11" ]; then
          cmd_11 "$extra"
        else
          "cmd_$n"
        fi
      done
      ;;
  esac
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

# ---------- выполнение и запись в сырой лог ----------
TEMP_RAW=$(mktemp /tmp/vps-raw-XXXXXX.log) || {
  echo "Не удалось создать временный файл в /tmp (диск переполнен или смонтирован в read-only)" >&2
  exit 1
}
cleanup() {
  rm -f "$TEMP_RAW" "$CLEAN_FILE"
  if [ -n "$OOKLA_TMPDIR" ]; then
    rm -rf "$OOKLA_TMPDIR"
  fi
}
trap cleanup EXIT

dispatch "$@" 2>&1 | tee "$TEMP_RAW"

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
