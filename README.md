# Forkop Service Check

LuCI-модуль для OpenWrt, который проверяет доступность сервисов через тот же сетевой маршрут, что и клиентский трафик Forkop.

Модуль помогает понять, на каком этапе возникает проблема: DNS, TCP/UDP, TLS, HTTP или выбор outbound-маршрута.

## Возможности

- Проверка популярных сервисов: Telegram, YouTube, Instagram, Discord, WhatsApp, GitHub и других.
- Проверка DNS через локальный dnsmasq и sing-box.
- HTTPS-проверки через forkop/tproxy.
- TCP-проверки и best-effort проверки UDP/QUIC.
- Режим проверки с роутера и режим проверки от имени клиента через временный network namespace.
- Отображение fakeip, времени DNS/TCP/TLS/HTTP и выбранного outbound через Clash API.
- Фоновый запуск с отображением прогресса.
- Поле **«Проверить свой IP или домен»**: произвольная цель и TCP-порт проверяются тем же маршрутом, с отдельным вердиктом «через sing-box» или «мимо sing-box».
- Классификация причин ошибок: DNS failure, timeout, TCP refused, TLS reset, ошибки сертификата, HTTP 403/451 и медленные соединения.
- Кнопка **«Починить импорт xHTTP»** с проверкой совместимости, backup и проверкой ucode-компиляции до замены файла.
- Кнопка **«Фикс ping/ICMP для правил подсетей»**: priority-правила TProxy ограничиваются TCP/UDP, чтобы ICMP не получал proxy-маркер.
- Расширяемая панель **«Фиксы Forkop»**: новые исправления добавляются в whitelist-реестр backend и не позволяют запускать произвольные команды из браузера.
- Двусторонние UDP-проверки через DNS в составе обычной проверки сервисов.

## Как это работает

Обычная проверка проходит по цепочке:

```text
LuCI → forkop-servicecheck → probe.uc
                         → dnsmasq → sing-box → forkop/tproxy → сервис
```

В режиме `netns` создаётся временный network namespace с отдельным IP-адресом в LAN. Это позволяет воспроизвести правила маршрутизации, зависящие от source IP клиента.

## Установка

Для OpenWrt с opkg:

```sh
opkg install luci-app-forkop-servicecheck_1.1.4-r1_all.ipk
```

Для OpenWrt с apk:

```sh
apk add --allow-untrusted ./luci-app-forkop-servicecheck-1.1.4-r1.apk
```

Установка без пакетного менеджера:

```sh
wget -O- https://raw.githubusercontent.com/Hellington-Rey/forkop-servicecheck/main/install-forkop-servicecheck.sh | sh
```

Установщик определяет уже установленную версию и сообщает, выполняется ли чистая установка, обновление или переустановка текущей версии.

На основной вкладке можно ввести домен или IPv4-адрес, указать TCP-порт и нажать **«Проверить IP/домен»**. Модуль проверит DNS и TCP-доступность, затем сопоставит удерживаемое тестовое соединение с Clash API sing-box. Для доменов FakeIP также используется как подтверждение маршрута через sing-box.

Та же проверка из консоли:

```sh
/usr/bin/forkop-servicecheck custom example.com 443 router
```

Удаление:

```sh
sh install-forkop-servicecheck.sh --uninstall
```

## xHTTP hotfix

В интерфейсе доступна кнопка **«Починить импорт xHTTP»**. Перед изменением `parser.uc` модуль:

1. находит parser Forkop;
2. проверяет совместимость якорей;
3. создаёт резервную копию в `/root`;
4. применяет исправление во временном файле;
5. проверяет файл через `ucode -c`;
6. заменяет оригинал только после успешной проверки.

Ручной запуск:

```sh
/usr/bin/forkop-servicecheck xhttp_patch
```

## ICMP/TProxy hotfix

Вкладка **«Фикс Forkop»** содержит отдельный фикс для priority-правил IP/подсетей. Он добавляет к правилам с proxy-маркером ограничение `meta l4proto { tcp, udp }`, поэтому ping/ICMP больше не маршрутизируется в TProxy, который ICMP не перехватывает.

Перед заменой `nft/apply.uc` модуль проверяет совместимость исходника, создаёт backup в `/root` и компилирует временный файл через `ucode -c`. Если Forkop работает, он перезапускается, а получившиеся цепочки `priority_rules` и `priority_output_rules` проверяются. При ошибке исходный файл возвращается автоматически.

Ручной запуск:

```sh
/usr/bin/forkop-servicecheck icmp_tproxy_patch
```

Собственные профили сервисов можно разместить в:

```text
/etc/forkop-servicecheck/profiles.json
```

Этот файл имеет приоритет над встроенным `/usr/share/forkop-servicecheck/profiles.json`.

## UDP-проверки

Обычная UDP-проверка показывает возможность отправки трафика через текущий маршрут. Цели `udp_dns` дополнительно ждут DNS-ответ и поэтому проверяют UDP в обе стороны.

UDP-диагностика находится в общем списке сервисов и не смешивается с исправлениями Forkop.

## Сборка

```sh
python3 build_packages.py
```

Результаты появятся в каталоге `dist/`.

## Требования

- OpenWrt и Forkop;
- LuCI и ucode;
- `curl` рекомендуется для точных измерений;
- `dig` рекомендуется для диагностики DNS;
- `ip` и поддержка network namespace — для режима `netns`;
- `nc` — для UDP-проверок.

## Лицензия

MIT.
