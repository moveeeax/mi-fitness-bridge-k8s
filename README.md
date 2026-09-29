# mi-fitness-bridge-k8s

Упаковка [mi_fitness_data_bridge](https://github.com/shkyyy18/mi_fitness_data_bridge) в образ и деплой в `talos-nbg1-tarassov-me`: CronJob тянет данные Mi Fitness в SQLite на PVC, отдельный под отдает те же данные по MCP через HTTP за nginx.

Апстрим не модифицируется, ставится из git по закрепленному коммиту `096f2bc` (v0.3.3). Лицензия апстрима AGPL-3.0-only, и раздача по сети подпадает под §13: если к этому MCP получит доступ кто-то кроме тебя, ему надо предложить исходники.

## Что здесь лежит

| Файл | Зачем |
| --- | --- |
| `Dockerfile` | Два стейджа, venv в `/opt/venv`, к апстриму добавлены `keyrings.alt` и `mcp-proxy`. |
| `bridge_entrypoint.py` | Посев учетки из Secret, WAL на базе, превращение `sync-window` в конкретные даты, запуск прокси. |
| `k8s/` | Namespace, PVC, CronJob синка, Deployment с MCP, Service, Ingress, NetworkPolicy, kustomization. |
| `.github/workflows/image.yml` | Сборка на amd64 и пуш в `ghcr.io/moveeeax/mi-fitness-bridge`. |

## Три вещи, которые ломают наивный деплой

1. Ключницы в контейнере нет. Апстрим хранит `passToken` через `keyring`, поэтому в образе стоит `keyrings.alt` с плоским файловым бэкендом, а файл лежит на PVC (`/data/python_keyring/keyring_pass.cfg`) в открытом виде. Том монтирует только этот namespace, но это именно открытый текст, а не Secret.
2. Токен ротируется при каждом логине, и апстрим перезаписывает его в ключнице. Поэтому Secret это только семя: если в ключнице уже есть токен, entrypoint его не трогает. Перезасев руками через `MI_FITNESS_RESEED=1`.
3. Держатель токена может быть только один. После первого успешного логина из кластера копия в Keychain на маке умирает. Синк живет либо в кластере, либо на ноутбуке, но не в двух местах.

Плюс к этому апстрим ходит в SQLite обычными соединениями без WAL и с таймаутом 5 секунд, поэтому entrypoint один раз переводит базу в `journal_mode=wal`: иначе ночной синк и запрос от MCP могут столкнуться на блокировке.

## Развертывание

```bash
# 1. образ: пуш в main, дальше GitHub Actions
git push

# 2. семя учетки (файл в .gitignore)
cp k8s/20-secret.example.yaml secret.yaml && $EDITOR secret.yaml
kubectl apply -f secret.yaml

# 3. basic auth для ingress: у mcp-proxy своей авторизации нет
USER_NAME=claude PASSWORD="$(openssl rand -base64 24)" make basic-auth

# 4. манифесты
TAG=<короткий-sha-из-CI> make deploy

# 5. первый синк вручную, не ждать 03:20
kubectl -n mi-fitness create job --from=cronjob/mi-fitness-sync backfill-1
kubectl -n mi-fitness logs -l job-name=backfill-1 -f
```

Историю поглубже одним разом:

```bash
kubectl -n mi-fitness run backfill --rm -it --restart=Never \
  --image=ghcr.io/moveeeax/mi-fitness-bridge:<tag> \
  --overrides='{"spec":{"containers":[{"name":"backfill","image":"ghcr.io/moveeeax/mi-fitness-bridge:<tag>","args":["sync","--start-date","2026-07-01","--end-date","2026-09-29"],"envFrom":[{"secretRef":{"name":"mi-fitness-credentials"}}],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"mi-fitness-data"}}]}}'
```

## Подключение клиента

```bash
claude mcp add --transport http mi-fitness https://mi-fitness.tarassov.me/mcp \
  --header "Authorization: Basic $(printf 'claude:ПАРОЛЬ' | base64)"
```

Эндпоинты прокси: `/mcp` (streamable HTTP), `/sse` (устаревший транспорт), `/status` (используется пробами).

## Эксплуатация

```bash
make status     # PVC, CronJob, поды, ingress
make logs       # логи MCP-пода
make rollout    # перезапуск после обновления образа
make db-pull    # забрать SQLite на мак для локального анализа
```

Один под пишет, один под читает, и оба держат один RWO-том, поэтому Deployment переезжает стратегией `Recreate`, а CronJob стоит с `concurrencyPolicy: Forbid`. Реплик у MCP строго одна: апстрим разрешает одному серверу владеть базой.

## Что проверено, а что нет

Проверено локально на macOS, python 3.14, в изолированном венве: посев учетки из переменных, защита ротированного токена от перезаписи семенем, отбой токена с мусорными символами, перевод базы в WAL, расчет окна синка, а также полный путь запроса `mcp-proxy` → stdio-мост: MCP-хендшейк, 17 инструментов, вызов `get_data_coverage`.

Не проверено: сборка образа (делается в CI на amd64) и сам деплой в кластер. Данные Mi Fitness трогались только реальным локальным синком, в контейнере логин шел с фальшивым токеном и ожидаемо отбивался Xiaomi.
