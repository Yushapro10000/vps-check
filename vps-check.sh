#!/usr/bin/env bash
# Полный чек-лист для проверки VPS перед/после покупки
# Запуск: bash vps-check.sh [все|номер]
# Пример: bash vps-check.sh 3   -> только IP Quality

run() {
  echo -e "\n########## $1 ##########\n"
  eval "$2"
}

menu() {
  cat <<EOF
1) YABS          - CPU/RAM/диск (fio)/сеть (iperf3, зарубеж)
2) RU Speedtest  - iperf3 до городов РФ (itdoginfo)
3) IP Quality    - ASN, risk score, доступность сервисов, блэклисты (check.place)
4) Geolocation   - в какой стране тебя видят сервисы (ipregion)
5) Censorcheck   - DNS resolvers (DoH/DoT) + доступность сайтов, DPI
6) Bench.sh      - CPU/диск (teddysun)
7) sysbench CPU  - однопоточный CPU-тест
0) Все по очереди
EOF
}

cmd_1() { run "YABS" "curl -sL yabs.sh | bash"; }
cmd_2() { run "RU Speedtest (itdoginfo)" "bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)"; }
cmd_3() { run "IP Quality" "bash <(curl -Ls ip.check.place) -l en"; }
cmd_4() { run "Geolocation Check" "bash <(wget -qO- https://raw.githubusercontent.com/Davoyan/ipregion/main/ipregion.sh)"; }
cmd_5() { run "Censorcheck (DPI mode)" "bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi"; }
cmd_6() { run "Bench.sh (Teddysun)" "wget -qO- bench.sh | bash"; }
cmd_7() { run "sysbench CPU" "command -v sysbench >/dev/null || apt install -y sysbench; sysbench cpu run --threads=1"; }

case "$1" in
  1|2|3|4|5|6|7) "cmd_$1" ;;
  все|all|0|"") for i in 1 2 3 4 5 6 7; do "cmd_$i"; done ;;
  menu|-h|--help) menu ;;
  *) echo "Неизвестный аргумент"; menu ;;
esac
