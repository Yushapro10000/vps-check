# vps-check

Скрипт для проверки VPS при покупке: мощность (CPU/RAM/диск), скорость и пинг до РФ, репутация IP/ASN, доступность сервисов, DNS/DPI, безопасность.

## Установка одной командой

Скачать и сразу запустить (пункты 1-10 подряд):

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
vps-check                    # пункты 1-10 подряд (11 и 12 — вручную, см. ниже)
vps-check 3                  # только пункт 3
vps-check 2,4,5-7            # несколько пунктов сразу: 2, 4, 5, 6, 7
vps-check 11 example.com     # SSL-проверка конкретного домена
vps-check 12                 # только Geekbench
vps-check -o report.txt 9    # тот же запуск, плюс сохранить вывод в файл
vps-check menu                # список пунктов
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
9 — Security Audit: SSH-конфиг (учитывает и sshd_config, и sshd_config.d/*.conf), firewall (ufw/firewalld/iptables — проверяется, что реально активен, а не просто установлен), fail2ban/CrowdSec (проверяется, что реально запущен через systemctl is-active, а не просто установлен), автообновления безопасности, список открытых портов — и в конце оценка 0-100 с вердиктом. Только чтение, ничего не меняет. 
10 — Disk & FS: свободное место, использование inode, ошибки файловой системы в dmesg, SMART-статус диска. 
11 — SSL Check: срок действия и издатель сертификата для указанного домена, не входит в общий прогон — нужен домен вторым аргументом. 
12 — Geekbench: тот же тест, что внутри YABS, но отдельно и без fio/iperf3, не входит в общий прогон — CPU уже покрыт пунктом 1.
```

Каждый пункт можно запускать отдельно или несколько сразу через запятую/диапазон — номера вне диапазона 1-12 отбрасываются с предупреждением, скрипт не пытается вызвать несуществующий пункт:

```bash
bash vps-check.sh 1               # только YABS
bash vps-check.sh 5               # только Censorcheck
bash vps-check.sh 8               # только Globalping
bash vps-check.sh 9               # только Security Audit (с оценкой)
bash vps-check.sh 2,4,5-7         # RU Speedtest, Geolocation, Censorcheck, Bench.sh, sysbench
bash vps-check.sh 11 example.com  # SSL для домена
bash vps-check.sh 12              # только Geekbench
```

## Оценка в Security Audit

Стартовая оценка 100, вычитается за каждую найденную проблему:

- Root-логин по SSH разрешён — минус 20
- Вход по паролю разрешён (или не запрещён явно) — минус 20
- Нет активного firewall — минус 25
- Нет активной защиты от брутфорса (fail2ban/CrowdSec) — минус 15
- Автообновления безопасности не настроены — минус 10
- Не удалось прочитать конфиг SSH (скрипт запущен не от root) — минус 10

80+ — базовая защита на месте, 50-79 — есть незакрытые дыры, ниже 50 — сервер в дефолтном состоянии.

## Вывод в файл

Флаг `-o`/`--output` перед номером пункта дублирует весь вывод в файл (через `tee`) — удобно, когда сравниваешь несколько VPS между собой:

```bash
bash vps-check.sh -o report-vps1.txt
bash vps-check.sh -o report-vps2.txt 9,10
```

## Требования

Bash, `curl`/`wget`. Отдельные пункты сами подтянут нужные утилиты (например `sysbench`, `globalping`) при необходимости. Пункты 9 и 10 — только чтение, ничего не устанавливают и не меняют в системе. Для полной картины в Security Audit (чтение sshd_config, ufw/firewalld/iptables, systemctl) скрипт стоит запускать от root/через sudo.
