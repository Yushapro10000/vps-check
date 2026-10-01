#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки
# Запуск:
#   bash vps-check.sh                      -> интерактивный запуск (пункты 1-10, 13, 14)
#   bash vps-check.sh -o report.txt        -> сохранить чистый TXT отчёт
#   bash vps-check.sh -m report.md         -> сгенерировать форматированный Markdown
#   bash vps-check.sh -o rep.txt -m rep.md -> сохранить оба отчёта сразу
#   bash vps-check.sh 3                    -> только пункт 3
#   bash vps-check.sh 2,4,5-7              -> пункты 2, 4, 5, 6, 7
#   bash vps-check.sh menu                 -> список пунктов

MIN_ITEM=1
MAX_ITEM=14

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
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]}"

ARG="${1:-}"
TARGET_DOMAIN="${2:-}"

# ---------- утилиты очистки и безопасной загрузки ----------
strip_ansi() {
  sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b([B0]//g' -e 's/\r//g'
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
}

pkg_install() {
  local pkg="$1"
  local sudo_cmd=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo_cmd="sudo"

  if command -v apt >/dev/null; then
    if ! $sudo_cmd apt update -qq 2>/dev/null; then
      echo "[i] apt update не удался — возможно, нет сети до зеркал репозитория."
    fi
    $sudo_cmd apt install -y "$pkg"
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
9)  Security Audit  - SSH-конфиг, firewall, fail2ban/crowdsec, автообновления, открытые порты + оценка
10) Disk & FS       - свободное место, inode, ошибки файловой системы
11) SSL Check       - срок действия сертификата домена (нужен аргумент-домен)
12) Geekbench       - только Geekbench (без fio/iperf3), для сравнения CPU между хостерами
13) Censorcheck (geoblock) - не банит ли зарубежный сервис сам IP по гео (в отличие от 5 — DPI РФ)
14) Nmap outbound   - не режет ли хостер исходящие порты (SMTP, DNS/DoT) — scanme.nmap.org, smtp.gmail.com, 1.1.1.1, 8.8.8.8
0)  Все по очереди (пункты 1-10, 13, 14; 11 и 12 пропускаются — см. ниже)

Диапазоны: bash vps-check.sh 2,4,5-7
Вывод в файл:
  bash vps-check.sh -o report.txt 9          -> чистый текстовый файл
  bash vps-check.sh -m report.md 9           -> форматированный Markdown
  bash vps-check.sh -o rep.txt -m rep.md 0   -> оба формата сразу
11 (SSL) нужен домен и не входит в общий прогон: bash vps-check.sh 11 example.com
12 (Geekbench) не входит в общий прогон: bash vps-check.sh 12
EOF
}

cmd_1() { run "YABS" "curl -fsSL --connect-timeout 5 --max-time 30 https://yabs.sh | bash"; }
cmd_12() { run "Geekbench (только CPU)" "curl -fsSL --connect-timeout 5 --max-time 30 https://yabs.sh | bash -s -- -f -i"; }
cmd_2() { run "RU Speedtest (itdoginfo)" "fetch_run 'RU Speedtest' 'https://raw.githubusercontent.com/itdoginfo/russian-iperf3-servers/main/speedtest.sh'"; }
cmd_3() { run "IP Quality" "curl -fsSL --connect-timeout 5 --max-time 30 https://ip.check.place | bash -s -- -l en"; }
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
  echo -e "\n########## Security Audit (только чтение) ##########\n"
  [ "$(id -u)" -ne 0 ] && echo "[!] Запущено не от root — ss/dmesg/iptables/fail2ban-client могут отдать урезанный или пустой вывод. Для полной картины: sudo bash vps-check.sh 9"
  echo

  SCORE=100
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

  echo "PermitRootLogin:        $ROOT_LOGIN"
  echo "PasswordAuthentication: $PASS_AUTH"
  echo "Port:                   ${SSH_PORT:-22 (по умолчанию)}"
  echo "PubkeyAuthentication:   $PUBKEY_AUTH"

  case "$ROOT_LOGIN" in
    yes) deduct 20 "root может логиниться по SSH напрямую (PermitRootLogin yes)" ;;
  esac
  case "$PASS_AUTH" in
    yes|"не задано") deduct 20 "разрешён вход по паролю (PasswordAuthentication yes/не задано — по умолчанию yes)" ;;
  esac

  echo
  echo "=== Firewall ==="
  FW_ACTIVE=0
  if command -v ufw >/dev/null; then
    echo "--- ufw ---"
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw status verbose 2>/dev/null
      FW_ACTIVE=1
    else
      echo "ufw установлен, но неактивен (или нет прав посмотреть статус)"
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
    RULES=$(iptables -L -n 2>/dev/null)
    echo "$RULES"
    if echo "$RULES" | grep -qE "^(ACCEPT|DROP|REJECT)"; then
      FW_ACTIVE=1
    fi
  fi
  if [ "$FW_ACTIVE" -eq 0 ]; then
    echo "Активный firewall не обнаружен (ufw/firewalld неактивны, осмысленных правил iptables нет)."
    deduct 25 "нет активного firewall"
  fi

  echo
  echo "=== Защита от брутфорса ==="
  F2B_ACTIVE=0
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "fail2ban запущен (systemctl is-active). Активные jail'ы:"
    fail2ban-client status 2>/dev/null || echo "(команда fail2ban-client недоступна для чтения статуса)"
    F2B_ACTIVE=1
  elif command -v fail2ban-client >/dev/null; then
    echo "fail2ban установлен, но НЕ запущен."
  elif command -v cscli >/dev/null && systemctl is-active --quiet crowdsec 2>/dev/null; then
    echo "CrowdSec установлен и запущен."
    cscli metrics 2>/dev/null | head -20
    F2B_ACTIVE=1
  elif command -v cscli >/dev/null; then
    echo "CrowdSec установлен, но сервис не запущен."
  else
    echo "Fail2ban/CrowdSec не найдены."
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
  domain="${domain%%:*}"

  echo "Проверяю сертификат для: $domain"
  echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates \
    || echo "Не удалось получить сертификат (сайт недоступен по 443 или openssl не установлен)."
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

# ---------- генератор Markdown-отчёта ----------
generate_markdown_report() {
  local raw_file="$1"
  local md_file="$2"

  local clean_file
  clean_file=$(mktemp /tmp/vps-clean-XXXXXX.log) || {
    echo "[!] Не удалось создать временный файл для очистки отчёта" >&2
    return 1
  }
  strip_ansi < "$raw_file" > "$clean_file"

  local os_info="Не определено"
  [ -f /etc/os-release ] && os_info=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')

  local cpu_info
  cpu_info=$(lscpu 2>/dev/null | awk -F: '/Model name/ {print $2}' | xargs)
  [ -z "$cpu_info" ] && cpu_info=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
  [ -z "$cpu_info" ] && cpu_info="Не определено"

  local cpu_cores
  cpu_cores=$(nproc 2>/dev/null || echo "1")

  local ram_info
  ram_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}')
  [ -z "$ram_info" ] && ram_info="Не определено"

  local kernel_info
  kernel_info=$(uname -r)

  local report_date
  report_date=$(date "+%Y-%m-%d %H:%M:%S")

  local sec_score
  sec_score=$(grep -E "Оценка: [0-9]+/100" "$clean_file" | tail -1 | sed -E 's/.*Оценка: ([0-9]+\/100.*)/\1/')

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
      for i in 1 2 3 4 5 6 7 8 9 10 13 14; do "cmd_$i"; done
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

# ---------- интерактивные вопросы (только если запуск в реальном TTY) ----------
CACHE_AND_SHOW=false
if [ -t 0 ]; then
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
trap 'rm -f "$TEMP_RAW"' EXIT

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
