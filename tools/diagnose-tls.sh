#!/bin/sh
#
# Разбор причин TLS-ошибок на роутере с forkop.
#
# Различает четыре вещи, которые выглядят одинаково в отчёте проверки сервисов:
#   - сбитые часы (нет RTC, NTP не синхронизировался)
#   - отсутствующий или битый CA-бандл
#   - обрыв хендшейка по DPI (TCP встаёт, ClientHello получает RST)
#   - сломанный выходной узел прокси
#
# Запускать прямо на роутере:  sh diagnose-tls.sh
#

echo "=========================================="
echo " 1. ЧАСЫ  (частая причина: все сертификаты становятся невалидными)"
echo "=========================================="
date
echo "  unixtime: $(date +%s)"
YEAR=$(date +%Y)
if [ "$YEAR" -lt 2025 ] 2>/dev/null; then
    echo "  !!! ГОДА $YEAR НЕ БЫВАЕТ - часы сбиты, это и есть причина TLS-ошибок"
    echo "      лечится: /etc/init.d/sysntpd restart   (или ntpd -q -p 2.openwrt.pool.ntp.org)"
else
    echo "  часы выглядят разумно"
fi
echo "  состояние NTP:"
/etc/init.d/sysntpd status 2>&1 | head -2
pgrep -l ntpd 2>/dev/null | head -2 || echo "    ntpd не запущен"

echo
echo "=========================================="
echo " 2. CA-БАНДЛ"
echo "=========================================="
for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
    if [ -s "$f" ]; then
        echo "  OK  $f ($(wc -c < "$f") байт, сертификатов: $(grep -c 'BEGIN CERTIFICATE' "$f" 2>/dev/null))"
    else
        echo "  НЕТ/ПУСТО  $f"
    fi
done
(opkg list-installed 2>/dev/null || apk list -I 2>/dev/null) | grep -iE '^(ca-bundle|ca-certificates)' | head -3

echo
echo "=========================================="
echo " 3. РЕШАЮЩИЙ ТЕСТ: проверка сертификата против хендшейка"
echo "=========================================="
echo "  Если с -k работает, а без него нет - виноваты часы или CA, а не DPI."
for host in cp.cloudflare.com www.gstatic.com; do
    curl -sS -o /dev/null --connect-timeout 7 --max-time 12 "https://$host/" 2>/tmp/.e1
    normal=$?
    curl -sSk -o /dev/null --connect-timeout 7 --max-time 12 "https://$host/" 2>/tmp/.e2
    insecure=$?
    printf "  %-22s обычный=%-3s с -k=%-3s" "$host" "$normal" "$insecure"
    if [ "$normal" != "0" ] && [ "$insecure" = "0" ]; then
        echo "  <-- ПРОВЕРКА СЕРТИФИКАТА (часы/CA)"
    elif [ "$normal" != "0" ] && [ "$insecure" != "0" ]; then
        echo "  <-- хендшейк не проходит вовсе"
    else
        echo "  ok"
    fi
    [ "$normal" != "0" ] && echo "        $(head -c 150 /tmp/.e1 | tr '\n' ' ')"
done
rm -f /tmp/.e1 /tmp/.e2

echo
echo "=========================================="
echo " 4. ЧТО ИДЁТ ЧЕРЕЗ ПРОКСИ, А ЧТО НАПРЯМУЮ"
echo "=========================================="
echo "  Адрес из 198.18.x.x (fakeip) = домен заворачивается в sing-box."
echo "  Реальный адрес = трафик идёт напрямую и может ловить DPI."
for host in cp.cloudflare.com www.youtube.com api.telegram.org rutracker.org; do
    ip=$(nslookup "$host" 127.0.0.1 2>/dev/null | awk '/^Address [0-9]*: / {print $3; exit}')
    [ -z "$ip" ] && ip=$(nslookup "$host" 2>/dev/null | awk '/^Address/ {a=$NF} END {print a}')
    case "$ip" in
        198.18.*) route="через прокси (fakeip)" ;;
        "")       route="НЕ РЕЗОЛВИТСЯ" ;;
        *)        route="напрямую" ;;
    esac
    printf "  %-22s %-16s %s\n" "$host" "$ip" "$route"
done

echo
echo "=========================================="
echo " 5. СОСТОЯНИЕ FORKOP И SING-BOX"
echo "=========================================="
/usr/bin/forkop get_status 2>&1
echo "  sing-box: $(pgrep -f sing-box >/dev/null && echo запущен || echo НЕ ЗАПУЩЕН)"
echo "  версия curl и его TLS-движок:"
curl --version 2>/dev/null | head -1 | sed 's/^/    /'

echo
echo "=========================================="
echo " 6. ПОСЛЕДНИЕ ОШИБКИ SING-BOX"
echo "=========================================="
logread 2>/dev/null | grep -iE 'sing-box|forkop' | grep -iE 'error|fatal|fail|timeout|handshake' | tail -12
echo "  (пусто - значит sing-box не жалуется)"

echo
echo "=========================================="
echo " 7. ВЫБРАННЫЙ УЗЕЛ И ЕГО ЗАДЕРЖКА"
echo "=========================================="
/usr/bin/forkop clash_api get_proxies 2>/dev/null | head -c 600
echo
echo
echo "Готово. Ключевые места - пункты 1 и 3."
