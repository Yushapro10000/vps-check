#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки
# Запуск:
#   bash vps-check.sh                      -> пункты 1-10 по очереди (без 11 и 12)
#   bash vps-check.sh 3                    -> только пункт 3
#   bash vps-check.sh 2,4,5-7              -> пункты 2, 4, 5, 6, 7
#   bash vps-check.sh -o report.txt 9      -> тот же запуск, плюс сохранить вывод в файл
#   bash vps-check.sh menu                 -> список пунктов

MIN_ITEM=1
MAX_ITEM=12

# ---------- вывод в файл (флаг -o/--output перед номером пункта) ----------
OUTPUT_FILE=""
if [ "$1" = "-o" ] || [ "$1" = "--output" ]; then
  OUTPUT_FILE="$2"
  shift 2
fi
if [ -n "$OUTPUT_FILE" ]; then
  exec > >(tee "$OUTPUT_FILE") 2>&1
  echo "Вывод дублируется в файл: $OUTPUT_FILE"
fi

run() {
  echo -e "\n########## $1 ##########\n"
  eval "$2"
}

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
0)  Все по очереди (пункты 1-10; 11 и 12 пропускаются — см. ниже)

Диапазоны: bash vps-check.sh 2,4,5-7
Вывод в файл: bash vps-check.sh -o report.txt 9
11 (SSL) нужен домен и не входит в общий прогон: bash vps-check.sh 11 example.com
12 (Geekbench) не входит в общий прогон — CPU уже покрыт пунктом 1: bash vps-check.sh 12
EOF
}

cmd_1() { run "YABS" "curl -sL yabs.sh | bash"; }
cmd_12() { run "Geekbench (только CPU, без fio/iperf3)" "curl -sL yabs.sh | bash -s -- -f -i"; }
cmd_2() { run "RU Speedtest (itdoginfo)" "bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)"; }
cmd_3() { run "IP Quality" "bash <(curl -Ls ip.check.place) -l en"; }
cmd_4() { run "Geolocation Check" "bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh)"; }
cmd_5() { run "Censorcheck (DPI mode)" "bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi"; }
cmd_6() { run "Bench.sh (Teddysun)" "wget -qO- bench.sh | bash"; }
cmd_7() { run "sysbench CPU" "command -v sysbench >/dev/null || apt install -y sysbench; sysbench cpu run --threads=1"; }

cmd_8() {
  echo -e "\n########## Globalping (доступность этого сервера из РФ) ##########\n"
  if ! command -v globalping >/dev/null; then
    curl -s https://packagecloud.io/install/repositories/jsdelivr/globalping/script.deb.sh | bash >/dev/null 2>&1
    apt install -y globalping >/dev/null 2>&1
  fi
  MY_IP=$(curl -s https://api.ipify.org || curl -s ifconfig.me)
  echo "Проверяемый IP этого сервера: ${MY_IP}"
  echo
  echo "--- ping с 5 нод в РФ ---"
  globalping ping "$MY_IP" from Russia --limit 5
  echo
  echo "--- mtr с 3 нод в РФ (видно, на каком хопе рвётся) ---"
  globalping mtr "$MY_IP" from Russia --limit 3
}

# ---------- 9. Security Audit ----------
# Только чтение: ничего не меняет и не устанавливает, кроме
# отсутствующих утилит для самой проверки. В конце — оценка 0-100.
cmd_9() {
  echo -e "\n########## Security Audit (только чтение) ##########\n"

  SCORE=100
  deduct() {
    SCORE=$((SCORE - $1))
    echo "  [-$1] $2"
  }

  echo "=== SSH-конфигурация ==="
  # Debian/Ubuntu подключают /etc/ssh/sshd_config.d/*.conf директивой Include
  # обычно в начале основного файла — то есть более поздние совпадения в
  # sshd_config.d/ и в самом sshd_config переопределяют более ранние.
  # Склеиваем файлы в этом порядке и берём последнее совпадение.
  SSHD_FILES=()
  [ -d /etc/ssh/sshd_config.d ] && SSHD_FILES+=(/etc/ssh/sshd_config.d/*.conf)
  [ -r /etc/ssh/sshd_config ] && SSHD_FILES+=(/etc/ssh/sshd_config)

  if [ ${#SSHD_FILES[@]} -gt 0 ]; then
    get_ssh() {
      val=$(cat "${SSHD_FILES[@]}" 2>/dev/null | grep -iE "^\s*$1\s+" | tail -1 | awk '{print $2}')
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
    echo "(учтены основной sshd_config и /etc/ssh/sshd_config.d/*.conf)"

    case "$ROOT_LOGIN" in
      yes) deduct 20 "root может логиниться по SSH напрямую (PermitRootLogin yes)" ;;
    esac
    case "$PASS_AUTH" in
      yes|"не задано") deduct 20 "разрешён вход по паролю (PasswordAuthentication yes/не задано — по умолчанию у большинства систем это yes)" ;;
    esac
  else
    echo "Нет доступа к sshd_config и sshd_config.d/ — SSH-часть аудита пропущена."
    deduct 10 "не удалось прочитать конфиг SSH (запусти от root для полной проверки)"
  fi

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
    # если есть хоть одно ACCEPT/DROP/REJECT правило кроме политики по умолчанию — считаем, что что-то настроено
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
    echo "fail2ban установлен, но НЕ запущен (systemctl is-active вернул false)."
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
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
      echo "и включён (systemctl is-enabled)."
      UPD_OK=1
    else
      echo "но не включён в systemd."
    fi
  elif command -v dnf >/dev/null && rpm -q dnf-automatic >/dev/null 2>&1; then
    echo "dnf-automatic установлен."
    UPD_OK=1
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

  echo "=== Свободное место (df) ==="
  df -hT 2>/dev/null || df -h

  echo
  echo "=== Использование inode ==="
  df -i 2>/dev/null

  echo
  echo "=== Ошибки файловой системы в dmesg (последние 20 строк) ==="
  if command -v dmesg >/dev/null; then
    dmesg 2>/dev/null | grep -iE "ext4|xfs|i/o error|read-only file system" | tail -20
    if [ $? -ne 0 ]; then
      echo "Ошибок не найдено (или dmesg недоступен без root)."
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
      smartctl -H "$dev" 2>/dev/null || echo "недоступно (частая история для VPS — диск виртуальный)"
    done
  else
    echo "smartctl не установлен (apt install -y smartmontools) — для VPS часто бесполезно, диск виртуальный."
  fi
}

# ---------- 11. SSL Check ----------
# Использование: bash vps-check.sh 11 example.com
cmd_11() {
  domain="$1"
  echo -e "\n########## SSL Check ##########\n"
  if [ -z "$domain" ]; then
    echo "Нужен домен: bash vps-check.sh 11 example.com"
    return
  fi
  echo "Проверяю сертификат для: $domain"
  echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates \
    || echo "Не удалось получить сертификат (сайт недоступен по 443 или openssl не установлен)."
}

# ---------- разбор аргументов вида 2,4,5-7 (с проверкой границ 1-12) ----------
expand_selection() {
  input="$1"
  result=""
  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if [ "$start" -gt "$end" ]; then
        echo "Пропускаю некорректный диапазон $part (начало больше конца)" >&2
        continue
      fi
      [ "$start" -lt "$MIN_ITEM" ] && { echo "Диапазон $part выходит за $MIN_ITEM-$MAX_ITEM, обрезаю до $MIN_ITEM" >&2; start=$MIN_ITEM; }
      [ "$end" -gt "$MAX_ITEM" ] && { echo "Диапазон $part выходит за $MIN_ITEM-$MAX_ITEM, обрезаю до $MAX_ITEM" >&2; end=$MAX_ITEM; }
      for ((i=start; i<=end; i++)); do
        result="$result $i"
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      if [ "$part" -lt "$MIN_ITEM" ] || [ "$part" -gt "$MAX_ITEM" ]; then
        echo "Пункта $part не существует (доступны $MIN_ITEM-$MAX_ITEM), пропускаю" >&2
        continue
      fi
      result="$result $part"
    fi
  done
  echo "$result"
}

ARG="$1"
case "$ARG" in
  ""|все|all|0)
    for i in 1 2 3 4 5 6 7 8 9 10; do "cmd_$i"; done
    echo -e "\n(пункт 11 — SSL Check — пропущен, нужен домен: bash vps-check.sh 11 example.com)"
    echo "(пункт 12 — Geekbench отдельно — пропущен, CPU уже покрыт пунктом 1 (YABS); запусти bash vps-check.sh 12 вручную для отдельного сравнения)"
    ;;
  menu|-h|--help)
    menu
    ;;
  11)
    cmd_11 "$2"
    ;;
  *[0-9]*)
    for n in $(expand_selection "$ARG"); do
      "cmd_$n"
    done
    ;;
  *)
    echo "Неизвестный аргумент"
    menu
    ;;
esac
