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
- Классификация причин ошибок: DNS failure, timeout, TCP refused, TLS reset, ошибки сертификата, HTTP 403/451 и медленные соединения.
- Кнопка **«Починить импорт xHTTP»** с проверкой совместимости, backup и проверкой ucode-компиляции до замены файла.

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
opkg install luci-app-forkop-servicecheck_1.0.0-r1_all.ipk
```

Для OpenWrt с apk:

```sh
apk add --allow-untrusted ./luci-app-forkop-servicecheck-1.0.0-r1.apk
```

Установка без пакетного менеджера:

```sh
sh install-forkop-servicecheck.sh
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

Собственные профили сервисов можно разместить в:

```text
/etc/forkop-servicecheck/profiles.json
```

Этот файл имеет приоритет над встроенным `/usr/share/forkop-servicecheck/profiles.json`.

## UDP-проверки

UDP-проверка показывает возможность отправки UDP-трафика через текущий маршрут. Так как UDP не подтверждает доставку без ответа приложения, результат является best-effort и не равен полноценному тесту протокола QUIC.

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
