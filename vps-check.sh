#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки
# Запуск:
#   bash vps-check.sh              -> всё по очереди
#   bash vps-check.sh 3            -> только пункт 3
#   bash vps-check.sh 2,4,5-7      -> пункты 2, 4, 5, 6, 7
#   bash vps-check.sh menu         -> список пунктов

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
9)  Security Audit  - SSH-конфиг, firewall, fail2ban/crowdsec, автообновления, открытые порты
10) Disk & FS       - свободное место, inode, ошибки файловой системы
11) SSL Check       - срок действия сертификата домена (нужен аргумент-домен)
12) Geekbench       - только Geekbench (без fio/iperf3), для сравнения CPU между хостерами
0)  Все по очереди

Диапазоны: bash vps-check.sh 2,4,5-7
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
# отсутствующих утилит для самой проверки.
cmd_9() {
  echo -e "\n########## Security Audit (только чтение) ##########\n"

  echo "=== SSH-конфигурация (/etc/ssh/sshd_config) ==="
  if [ -r /etc/ssh/sshd_config ]; then
    get_ssh() {
      val=$(grep -iE "^\s*$1\s+" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
      echo "${val:-не задано (по умолчанию у sshd)}"
    }
    echo "PermitRootLogin:        $(get_ssh PermitRootLogin)"
    echo "PasswordAuthentication: $(get_ssh PasswordAuthentication)"
    echo "Port:                   $(get_ssh Port)"
    echo "PubkeyAuthentication:   $(get_ssh PubkeyAuthentication)"
  else
    echo "Нет доступа к /etc/ssh/sshd_config"
  fi

  echo
  echo "=== Firewall ==="
  if command -v ufw >/dev/null; then
    echo "--- ufw ---"
    ufw status verbose 2>/dev/null || echo "ufw установлен, но статус получить не удалось (нужен root?)"
  fi
  if command -v firewall-cmd >/dev/null; then
    echo "--- firewalld ---"
    firewall-cmd --state 2>/dev/null
    firewall-cmd --list-all 2>/dev/null
  fi
  if command -v iptables >/dev/null && ! command -v ufw >/dev/null && ! command -v firewall-cmd >/dev/null; then
    echo "--- iptables (сырые правила) ---"
    iptables -L -n 2>/dev/null || echo "нет доступа к iptables (нужен root?)"
  fi
  if ! command -v ufw >/dev/null && ! command -v firewall-cmd >/dev/null && ! command -v iptables >/dev/null; then
    echo "Не найдено ни ufw, ни firewalld, ни iptables."
  fi

  echo
  echo "=== Защита от брутфорса ==="
  if command -v fail2ban-client >/dev/null; then
    echo "fail2ban установлен. Активные jail'ы:"
    fail2ban-client status 2>/dev/null || echo "не удалось получить статус (нужен root?)"
  elif command -v cscli >/dev/null; then
    echo "CrowdSec установлен."
    cscli metrics 2>/dev/null | head -20
  else
    echo "Fail2ban/CrowdSec не найдены — SSH ничем не защищён от подбора пароля/брутфорса."
  fi

  echo
  echo "=== Автообновления безопасности ==="
  if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    echo "unattended-upgrades установлен."
    systemctl is-enabled unattended-upgrades 2>/dev/null
  elif command -v dnf >/dev/null && rpm -q dnf-automatic >/dev/null 2>&1; then
    echo "dnf-automatic установлен."
  else
    echo "Автообновления безопасности не настроены (unattended-upgrades/dnf-automatic не найдены)."
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

# ---------- разбор аргументов вида 2,4,5-7 ----------
expand_selection() {
  input="$1"
  result=""
  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      for ((i=start; i<=end; i++)); do
        result="$result $i"
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
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
      if declare -f "cmd_$n" >/dev/null; then
        "cmd_$n"
      else
        echo "Пункта $n не существует, см. bash vps-check.sh menu"
      fi
    done
    ;;
  *)
    echo "Неизвестный аргумент"
    menu
    ;;
esac
