# VPNSmart

Умный VPN: российские сайты через Россию, заблокированные — через Латвию. Автоматически.

## Архитектура

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│   📱 Клиент (v2rayN / Hiddify / sing-box)                                   │
│   ┌─────────────────────────────┐                                            │
│   │  VLESS + Reality (TLS 1.3)  │                                            │
│   │  SNI: ya.ru                 │                                            │
│   │  Fingerprint: Chrome        │                                            │
│   └─────────────┬───────────────┘                                            │
│                 │ порт 443 (выглядит как обычный HTTPS)                       │
│                 │                                                             │
├─────────────────┼────────────────────────────────────────────────────────────┤
│                 ▼                                                             │
│   🇷🇺 Россия (91.218.247.244)                                                │
│   ┌─────────────────────────────────────────────────────────┐                │
│   │                     Xray-core                           │                │
│   │  ┌─────────────────────────────────────────────────┐    │                │
│   │  │              Маршрутизация                       │    │                │
│   │  │                                                  │    │                │
│   │  │  geosite_RU.dat:ru-blocked  ─┐                   │    │                │
│   │  │  geoip_RU.dat:ru-blocked    ─┼── fwmark = 1      │    │                │
│   │  │  geoip_RU.dat:re-filter     ─┘    │              │    │                │
│   │  │                                    │              │    │                │
│   │  │  geoip:private ──── direct         │              │    │                │
│   │  │  остальное ──────── direct         │              │    │                │
│   │  │  bittorrent ─────── blocked        │              │    │                │
│   │  └────────────────────────────────────┼──────────────┘    │                │
│   └───────────────────────────────────────┼──────────────────┘                │
│                                           │                                   │
│              ┌────────────────────────────┘                                   │
│              │  Linux Policy Routing                                          │
│              │  ip rule: fwmark 1 → table 100                                │
│              │  table 100: default dev awg0                                   │
│              ▼                                                                │
│   ┌──────────────────────────┐                                               │
│   │  AmneziaWG (awg0)       │                                                │
│   │  DPI-устойчивый туннель  │                                                │
│   │  Обфускация: Jc/Jmin/   │                                                │
│   │  Jmax/S1/S2/H1-H4       │                                                │
│   └─────────────┬────────────┘                                               │
│                 │ UDP :51820 (нераспознаваем для DPI)                         │
│                 │                                                             │
├─────────────────┼────────────────────────────────────────────────────────────┤
│                 ▼                                                             │
│   🇱🇻 Латвия (213.155.12.223)                                                │
│   ┌──────────────────────────┐                                               │
│   │  AmneziaWG (awg0)       │                                                │
│   │  NAT Masquerade         ├──────────▶  🌍 Интернет                        │
│   │  10.10.0.2/24           │             (YouTube, Instagram,               │
│   └──────────────────────────┘              Discord, Twitter...)              │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   📊 Управление                                                              │
│   ┌──────────────────────────┐    ┌──────────────────────────────────┐       │
│   │  Telegram бот            │    │  Geodata (авто-обновление 6ч)    │       │
│   │  @vlesssmart_bot         │    │  runetfreedom/russia-v2ray-rules │       │
│   │  /add /list /link /delete│    │  geosite_RU.dat + geoip_RU.dat  │       │
│   └──────────────────────────┘    └──────────────────────────────────┘       │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Поток трафика

```
Заблокированный сайт (youtube.com):
  Клиент → VLESS+Reality(:443) → Xray(fwmark=1) → awg0 → Латвия → Интернет

Российский сайт (ya.ru):
  Клиент → VLESS+Reality(:443) → Xray(direct) → Интернет напрямую

DNS заблокированных доменов:
  Cloudflare DoH → через AmneziaWG → без утечек через российских провайдеров
```

## Стек технологий

| Компонент | Технология | Назначение |
|-----------|-----------|------------|
| Прокси | Xray-core + VLESS + Reality | Обход DPI, маскировка под HTTPS к ya.ru |
| Туннель | AmneziaWG | DPI-устойчивый WireGuard с обфускацией |
| Маршрутизация | Linux fwmark + policy routing | Раздельный роутинг заблокированного трафика |
| Блоклисты | geosite_RU / geoip_RU | Автообновляемые списки заблокированных ресурсов |
| Управление | Telegram бот (aiogram) | Добавление/удаление клиентов |

## Требования

- 2 VPS сервера: Россия + Латвия/Европа (Ubuntu 22.04+)
- Локально: `wg` (wireguard-tools), `jq`, `curl`

## Быстрый старт

```bash
brew install wireguard-tools jq   # macOS
./deploy.sh                        # всё автоматически
```

Скрипт спросит IP серверов, сгенерирует ключи, развернёт AmneziaWG + Xray + бота и выдаст VLESS-ссылку.

## Ручное развертывание

### 1. Генерация ключей

```bash
make keys   # или: bash servers/russia/scripts/generate-keys.sh
```

Reality-ключи генерируются на сервере:
```bash
docker run --rm ghcr.io/xtls/xray-core:latest x25519
```

### 2. Развертывание Латвии (exit node)

```bash
make deploy-latvia LATVIA_IP=<ip>
```

### 3. Развертывание России (entry point)

```bash
make deploy-russia RUSSIA_IP=<ip>
```

### 4. Проверка

```bash
# Туннель
ssh root@<russia-ip> 'ping -c 2 10.10.0.2'

# Policy routing
ssh root@<russia-ip> 'ip rule show | grep fwmark'

# Подключение клиентом — импортировать VLESS-ссылку
```

### 5. Клиентские приложения

| Платформа | Приложение |
|-----------|-----------|
| Windows | [v2rayN](https://github.com/2dust/v2rayN), [Hiddify](https://github.com/hiddify/hiddify-app) |
| Android | [v2rayNG](https://github.com/2dust/v2rayNG), [Hiddify](https://github.com/hiddify/hiddify-app) |
| iOS | [Hiddify](https://apps.apple.com/app/hiddify-proxy-vpn/id6596777532), [Streisand](https://apps.apple.com/app/streisand/id6450534064) |
| macOS | [Hiddify](https://github.com/hiddify/hiddify-app), [V2BOX](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |

Импортируйте VLESS-ссылку в приложение.

## Управление

```bash
make status RUSSIA_IP=... LATVIA_IP=...    # Статус серверов
make logs-russia RUSSIA_IP=...              # Логи Xray + бот
make logs-latvia LATVIA_IP=...              # Статус AmneziaWG
make restart-russia RUSSIA_IP=...           # Перезапуск Xray
make restart-latvia LATVIA_IP=...           # Перезапуск AmneziaWG
make update-geodata RUSSIA_IP=...           # Обновить блоклисты
```

Клиенты управляются через Telegram-бота: `/add`, `/list`, `/link`, `/info`, `/note`, удаление.

## Структура проекта

```
vpnsmart/
├── servers/
│   ├── russia/              # Entry point (Xray + AmneziaWG клиент)
│   │   ├── xray/            # Xray конфиг + geodata
│   │   ├── amneziawg/       # AWG туннель + policy routing
│   │   ├── bot/             # Telegram бот (aiogram)
│   │   ├── scripts/         # setup, generate-keys, update-geodata
│   │   └── docker-compose.yml
│   └── latvia/              # Exit node (AmneziaWG + NAT)
│       ├── amneziawg/       # AWG сервер
│       └── scripts/         # setup
├── clients/                 # Клиентские шаблоны
├── tests/                   # Тесты маршрутизации
├── deploy.sh                # One-click деплой
└── Makefile                 # Автоматизация
```

## Обновление блоклистов

Geodata обновляется автоматически каждые 6 часов через cron (`update-geodata.sh`).

Источник: [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat)

Принудительное обновление: `make update-geodata RUSSIA_IP=...`

## Устранение неполадок

**Клиент не подключается:**
- Порт 443 открыт? `ss -tlnp | grep 443`
- Xray работает? `docker logs vpnsmart-xray-russia`
- Reality ключи совпадают? (public key в ссылке = от private key на сервере)

**Заблокированные сайты не открываются:**
- Туннель жив? `ping 10.10.0.2`
- Policy routing? `ip rule show | grep fwmark` + `ip route show table 100`
- AWG handshake? `awg show awg0`

**Сервер недоступен после запуска AWG:**
- Убедитесь что в awg0.conf России есть `Table = off`
- Без этого awg-quick перехватывает весь трафик
