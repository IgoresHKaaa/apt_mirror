# Корпоративное зеркало Ubuntu

В зеркало попадают только пакеты из `packages.list` 

```
apt-mirror-prod/
├── docker-compose.yml   # aptly + nginx
├── packages.list        # здесь выбираем пакеты
├── mirror.sh            # всё управление
└── client.sources       # конфиг для клиентов
```

Раздача: `http://<сервер>/ubuntu/` (Ubuntu), `http://<сервер>/internal/` (свои пакеты), `http://<сервер>/corp.gpg` (ключ)

## Установка (один раз)

```bash
cd /opt/apt-mirror
nano packages.list                 # вписать нужные пакеты
docker compose up -d --build
./mirror.sh init                   # ключ подписи
./mirror.sh update                 # первая загрузка
./mirror.sh status
```

**Потом сохранить ключ подписи** вне сервера. Если его потерять, придётся заново раздавать ключ всем клиентам

## Повседневная работа

| Задача | Команда |
|---|---|
| Добавить/убрать пакет | правка `packages.list`, затем `./mirror.sh update` |
| Скачать обновления | `./mirror.sh update` |
| Что опубликовано, какие есть версии | `./mirror.sh status` |
| Откатить на прошлую версию | `./mirror.sh rollback 20261022-134750` |

Автообновление раз в неделю (вск, 03:00)

```bash
echo '0 3 * * 0 root cd /opt/apt-mirror && ./mirror.sh update >> /var/log/apt-mirror.log 2>&1' \
    > /etc/cron.d/apt-mirror
```

## Клиенты (Ubuntu 24.04)

```bash
sudo curl -fsSL http://apt.corp.local/corp.gpg -o /etc/apt/keyrings/corp.gpg
sudo cp client.sources /etc/apt/sources.list.d/ubuntu.sources   # предварительно заменить apt.corp.local
sudo apt update
```


