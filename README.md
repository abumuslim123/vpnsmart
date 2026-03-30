# VPNSmart

Умный VPN: российские сайты через Россию, заблокированные — через Финляндию. Автоматически.

## Как это работает

```
[Клиент] --VLESS+Reality--> [Сервер Россия (sing-box)]
                                    |
                    Сайт заблокирован? ──YES──> [WireGuard туннель] --> [Сервер Финляндия] --> Интернет
                                    |
                                   NO --> Интернет напрямую (российский IP)
```

- **Клиент → Россия:** VLESS + Reality (выглядит как обычный HTTPS, не детектируется ТСПУ)
- **Россия → Финляндия:** WireGuard (server-to-server, не блокируется)
- **Маршрутизация:** Автоматическая по базе [antizapret](https://github.com/savely-krasovsky/antizapret-sing-box) (700K+ доменов, обновляется каждые 6 часов)

## Требования

- 2 VPS сервера: Россия + Финляндия (Ubuntu 22.04+ / Debian 12+)
- Локально: `wg` (wireguard-tools), `sing-box`, `jq`

## Быстрый старт (один скрипт)

```bash
# Установить зависимости (macOS)
brew install wireguard-tools jq

# Запустить развертывание — скрипт сделает всё сам:
# генерация ключей → настройка Финляндии → настройка России → клиентский конфиг
./deploy.sh
```

Скрипт спросит IP серверов, проверит SSH-доступ, сгенерирует ключи, развернёт оба сервера и создаст готовый клиентский конфиг в `clients/client1.json`.

---

## Ручное развертывание (по шагам)

### 1. Генерация ключей

```bash
# Установить зависимости (macOS)
brew install wireguard-tools jq

# Установить sing-box
# https://sing-box.sagernet.org/installation/from-source/

# Сгенерировать все ключи
make keys
```

Сохраните вывод — это все ключи для настройки. Пример вывода:

```
RUSSIA_WG_PRIVATE_KEY=aAbBcCdD...
RUSSIA_WG_PUBLIC_KEY=eEfFgGhH...
FINLAND_WG_PRIVATE_KEY=iIjJkKlL...
FINLAND_WG_PUBLIC_KEY=mMnNoOpP...
WG_PRESHARED_KEY=qQrRsStT...
REALITY_PRIVATE_KEY=uUvVwWxX...
REALITY_PUBLIC_KEY=yYzZ0011...
REALITY_SHORT_ID=0123456789abcdef
CLIENT_UUID=bf000d23-0752-40b4-affe-68f7707a9661
```

### 2. Настройка сервера Финляндии

Отредактируйте `servers/finland/wireguard/wg0.conf` — замените плейсхолдеры:

```
${FINLAND_WG_PRIVATE_KEY}  → ваш ключ из шага 1
${RUSSIA_WG_PUBLIC_KEY}    → ваш ключ из шага 1
${WG_PRESHARED_KEY}        → ваш ключ из шага 1
```

> **Важно:** Проверьте имя сетевого интерфейса на сервере (`ip a`). Если это не `eth0`, замените `eth0` в `wg0.conf` на правильное имя (например, `ens3`).

Разверните:

```bash
make deploy-finland FINLAND_IP=<ip-финляндии>
```

Или вручную:

```bash
# На сервере Финляндии
scp -r servers/finland/* root@<ip>:/opt/vpnsmart/
ssh root@<ip>
cd /opt/vpnsmart
chmod +x scripts/setup.sh
./scripts/setup.sh
docker compose up -d
```

### 3. Настройка сервера России

Отредактируйте `servers/russia/sing-box/config.json` — замените плейсхолдеры:

```
${CLIENT_UUID}           → UUID клиента из шага 1
${REALITY_PRIVATE_KEY}   → приватный ключ Reality из шага 1
${REALITY_SHORT_ID}      → Short ID из шага 1
${FINLAND_IP}            → публичный IP сервера Финляндии
${RUSSIA_WG_PRIVATE_KEY} → приватный WG ключ России из шага 1
${FINLAND_WG_PUBLIC_KEY} → публичный WG ключ Финляндии из шага 1
${WG_PRESHARED_KEY}      → PSK из шага 1
```

Разверните:

```bash
make deploy-russia RUSSIA_IP=<ip-россии>
```

### 4. Проверка туннеля

```bash
# SSH на сервер России
ssh root@<ip-россии>
# Проверить туннель к Финляндии
docker exec vpnsmart-singbox-russia ping -c 3 10.10.0.2
```

### 5. Настройка клиента

Установите приложение sing-box:
- **iOS:** [SFI в App Store](https://apps.apple.com/app/sing-box/id6451272673)
- **Android:** [SFA в Google Play](https://play.google.com/store/apps/details?id=io.nekohasekai.sfa)
- **macOS:** [SFM в App Store](https://apps.apple.com/app/sing-box/id6673731168)
- **Windows:** [sing-box releases](https://github.com/SagerNet/sing-box/releases)

Сгенерируйте конфиг:

```bash
make client-config \
  SERVER_IP=<ip-россии> \
  UUID=<uuid-клиента> \
  PUBLIC_KEY=<reality-public-key> \
  SHORT_ID=<short-id>
```

Импортируйте полученный JSON в приложение sing-box.

### 6. Добавление новых клиентов

```bash
make add-client \
  NAME=phone-vasya \
  RUSSIA_IP=<ip-россии> \
  PUBLIC_KEY=<reality-public-key> \
  SHORT_ID=<short-id>
```

Скрипт:
1. Генерирует новый UUID
2. Добавляет пользователя в конфиг sing-box
3. Выводит готовый клиентский конфиг

После добавления перезапустите sing-box:

```bash
make restart-russia RUSSIA_IP=<ip-россии>
```

## Управление

```bash
make status RUSSIA_IP=... FINLAND_IP=...    # Статус обоих серверов
make logs-russia RUSSIA_IP=...               # Логи Russia
make logs-finland FINLAND_IP=...             # Логи Finland
make restart-russia RUSSIA_IP=...            # Перезапуск Russia
make restart-finland FINLAND_IP=...          # Перезапуск Finland
make test RUSSIA_IP=... FINLAND_IP=...       # Тесты маршрутизации
make test-direct                              # Тест прямого доступа
```

## Структура проекта

```
vpnsmart/
├── servers/
│   ├── russia/          # Точка входа VPN (sing-box + VLESS + Reality)
│   │   ├── sing-box/    # Конфигурация sing-box (маршрутизация + VLESS)
│   │   ├── scripts/     # Скрипты развертывания и управления
│   │   └── docker-compose.yml
│   └── finland/         # Выходной узел (WireGuard)
│       ├── wireguard/   # WireGuard конфигурация
│       ├── scripts/     # Скрипт установки
│       └── docker-compose.yml
├── clients/             # Клиентские конфиги и генератор
├── tests/               # Тесты маршрутизации
└── Makefile             # Автоматизация
```

## Как обновляются списки блокировок

sing-box автоматически скачивает обновленные rule-sets каждые 6 часов:
- [antizapret](https://github.com/savely-krasovsky/antizapret-sing-box) — домены и IP, заблокированные в РФ
- [geoip-ru](https://github.com/SagerNet/sing-geoip) — IP-адреса, принадлежащие российским сетям

Принудительное обновление: перезапустите sing-box (`make restart-russia`).

## Устранение неполадок

**Клиент не подключается:**
- Проверьте, что порт 443 открыт на сервере России
- Убедитесь, что `server_name` и `short_id` совпадают на сервере и клиенте
- Проверьте логи: `make logs-russia`

**Заблокированные сайты не открываются:**
- Проверьте туннель: `ping 10.10.0.2` с сервера России
- Проверьте, что порт 51820/udp открыт на сервере Финляндии
- Проверьте логи: `make logs-finland`

**Высокая задержка:**
- Нормальная задержка для заблокированных сайтов: +20-40мс (Россия → Финляндия)
- Для российских сайтов задержка должна быть минимальной

**Интерфейс не eth0:**
- На сервере Финляндии проверьте `ip a` и замените `eth0` в `wg0.conf` на правильное имя
