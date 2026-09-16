vps-check
Скрипт для проверки VPS при покупке: мощность (CPU/RAM/диск), скорость и пинг до РФ, репутация IP/ASN, доступность сервисов, DNS/DPI.
Установка одной командой
Скачать и сразу запустить (все проверки подряд):
```bash
bash <(curl -sL https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh)
```
Или через wget:
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh)
```
Установка как команда
Чтобы потом просто вызывать `vps-check` без повторного скачивания:
```bash
curl -sL https://raw.githubusercontent.com/Yushapro10000/vps-check/main/vps-check.sh -o /usr/local/bin/vps-check && chmod +x /usr/local/bin/vps-check
```
Дальше:
```bash
vps-check          # все проверки подряд
vps-check 3        # только пункт 3
vps-check menu     # список пунктов
```
Что внутри
№	Проверка	Что показывает
1	YABS	CPU, RAM, диск (fio), сеть (iperf3, зарубежные точки)
2	RU Speedtest	Скорость и пинг до городов России (itdoginfo)
3	IP Quality	ASN, risk score, доступность стриминга/AI-сервисов, блэклисты почты (check.place)
4	Geolocation	В какой стране тебя видят Google/Netflix/Steam и др. (ipregion)
5	Censorcheck	DNS-резолверы (DoH/DoT) на подмену + доступность сайтов, режим DPI
6	Bench.sh	CPU и диск, компактный вывод (Teddysun)
7	sysbench CPU	Однопоточный CPU-тест
Каждый пункт можно запускать отдельно:
```bash
bash vps-check.sh 1   # только YABS
bash vps-check.sh 5   # только Censorcheck
```
Требования
Bash, `curl`/`wget`. Отдельные пункты сами подтянут нужные утилиты (например `sysbench`) при необходимости.
