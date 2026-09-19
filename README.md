# vps-check

Скрипт для проверки VPS при покупке: мощность (CPU/RAM/диск), скорость и пинг до РФ, репутация IP/ASN, доступность сервисов, DNS/DPI, безопасность.

## Установка одной командой

Скачать и сразу запустить (все проверки подряд):

```bash
bash <(curl -sL https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh)
```

Или через wget:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh)
```

## Установка как команда

Чтобы потом просто вызывать `vps-check` без повторного скачивания:

```bash
curl -sL https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh -o /usr/local/bin/vps-check && chmod +x /usr/local/bin/vps-check
```

Дальше:

```bash
vps-check          # все проверки подряд (кроме SSL — ему нужен домен)
vps-check 3        # только пункт 3
vps-check 2,4,5-7  # несколько пунктов сразу: 2, 4, 5, 6, 7
vps-check 11 example.com   # SSL-проверка конкретного домена
vps-check menu     # список пунктов
```

## Что внутри
```bash
1 — YABS: CPU, RAM, диск (fio), сеть (iperf3, зарубежные точки), включает Geekbench. 
2 — RU Speedtest: скорость и пинг до городов России (itdoginfo). 
3 — IP Quality: ASN, risk score, доступность стриминга/AI-сервисов, блэклисты почты (check.place). 
4 — Geolocation: в какой стране тебя видят Google/Netflix/Steam и др. (ipregion). 
5 — Censorcheck: DNS-резолверы (DoH/DoT) на подмену + доступность сайтов, режим DPI. 
6 — Bench.sh: CPU и диск, компактный вывод (Teddysun). 
7 — sysbench CPU: однопоточный CPU-тест. 8 — Globalping: доступность ЭТОГО сервера с проверочных нод в РФ (ping/mtr, видно на каком хопе рвётся). 
9 — Security Audit: SSH-конфиг (root-логин, парольная аутентификация, порт), firewall (ufw/firewalld/iptables), fail2ban/CrowdSec, автообновления безопасности, список открытых портов — только чтение, ничего не меняет. 
10 — Disk & FS: свободное место, использование inode, ошибки файловой системы в dmesg, SMART-статус диска. 
11 — SSL Check: срок действия и издатель сертификата для указанного домена. 
12 — Geekbench: тот же тест, что внутри YABS, но отдельно и без fio/iperf3 — удобно, когда нужно быстро сравнить только CPU между несколькими хостерами.
```

Каждый пункт можно запускать отдельно или несколько сразу через запятую/диапазон:

```bash
bash vps-check.sh 1        # только YABS
bash vps-check.sh 5        # только Censorcheck
bash vps-check.sh 8        # только Globalping
bash vps-check.sh 9        # только Security Audit
bash vps-check.sh 2,4,5-7  # RU Speedtest, Geolocation, Censorcheck, Bench.sh, sysbench
bash vps-check.sh 11 example.com  # SSL для домена
bash vps-check.sh 12               # только Geekbench
```

## Требования

Bash, `curl`/`wget`. Отдельные пункты сами подтянут нужные утилиты (например `sysbench`, `globalping`) при необходимости. Пункты 9 и 10 — только чтение, ничего не устанавливают и не меняют в системе.
