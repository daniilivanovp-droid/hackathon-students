#!/usr/bin/env bash
# =====================================================================
#  Полная установка окружения: база, схемы, сырые данные.
#
#  Запуск из любого места:
#      bash scripts/setup.sh            обычная установка
#      bash scripts/setup.sh --reset    снести базу и поставить заново
#
#  Скрипт проверяет каждый шаг и останавливается на первом сломанном,
#  объясняя, что делать.
# =====================================================================

set -uo pipefail

# Скрипт лежит в scripts/, а работать надо из корня проекта.
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
cd "$ROOT"

RESET=0
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
  esac
done

step()  { echo; echo "==> $1"; }
ok()    { echo "    ок: $1"; }
die()   { echo; echo "ОШИБКА: $1"; echo; [ $# -gt 1 ] && echo "$2"; exit 1; }

# --- 1. Docker ------------------------------------------------------
step "Проверяю Docker"

# Git Bash иногда не видит CLI уже установленного Docker Desktop.
# Ищем только стандартные каталоги установки, не меняя системный PATH.
add_docker_cli_from() {
  local win_base="$1" subdir="$2" posix_base
  [ -n "$win_base" ] || return 1
  posix_base="$(cygpath -u "$win_base" 2>/dev/null)" || return 1
  [ -x "$posix_base/$subdir/docker.exe" ] || return 1
  PATH="$posix_base/$subdir:$PATH"
  export PATH
}

if ! command -v docker >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
  add_docker_cli_from "${LOCALAPPDATA:-}" "Programs/DockerDesktop/resources/bin" \
    || add_docker_cli_from "${ProgramFiles:-${PROGRAMFILES:-}}" "Docker/Docker/resources/bin" \
    || true
fi

command -v docker >/dev/null 2>&1 \
  || die "команда docker не найдена" \
         "Установите и запустите Docker Desktop. Откройте новый Git Bash и проверьте: docker --version.
Если Docker Desktop уже установлен, добавьте его каталог с docker.exe в PATH."

if ! docker info >/dev/null 2>&1; then
  echo "    Последние строки диагностики Docker:"
  docker info 2>&1 | tail -n 15 || true
  die "Docker CLI найден, но daemon не отвечает" \
      "Откройте Docker Desktop и дождитесь запуска движка (Engine running).
Убедитесь, что выбран режим Linux containers.
Проверьте контекст: docker context ls и docker context show.
Если доступен контекст desktop-linux, переключитесь: docker context use desktop-linux.
Если задан устаревший DOCKER_HOST, удалите его из окружения и откройте новый Git Bash.
Если работаете через WSL, проверьте Docker Desktop → Settings → Resources → WSL Integration.
Повторите docker info, затем bash scripts/setup.sh."
fi

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "не найден docker compose" "Обновите Docker Desktop."
fi
ok "Docker работает, команда: $DC"

# --- 2. Файлы -------------------------------------------------------
step "Проверяю файлы проекта"

[ -f docker-compose.yml ] || die "в корне проекта нет docker-compose.yml" \
  "Похоже, структура папки нарушена. Ожидается: docker-compose.yml в корне,
скрипты в scripts/, данные в data/."
[ -f scripts/init/01_init.sql ]   || die "нет scripts/init/01_init.sql" \
  "Файлы 01_init.sql и 02_raw_ddl.sql должны лежать ВНУТРИ папки scripts/init."
[ -f scripts/init/02_raw_ddl.sql ] || die "нет scripts/init/02_raw_ddl.sql" \
  "Файлы 01_init.sql и 02_raw_ddl.sql должны лежать ВНУТРИ папки scripts/init."
ok "init на месте"

CSV_COUNT=$(ls data/*.csv 2>/dev/null | wc -l | tr -d ' ')
if [ "$CSV_COUNT" -lt 8 ]; then
  echo "    в data только $CSV_COUNT файлов, качаю недостающие"
  bash scripts/download_data.sh || die "не удалось скачать данные" \
    "Проверьте интернет или скачайте файлы вручную,
список в scripts/download_data.sh"
  CSV_COUNT=$(ls data/*.csv 2>/dev/null | wc -l | tr -d ' ')
fi
[ "$CSV_COUNT" -ge 8 ] || die "в папке data всё ещё $CSV_COUNT файлов вместо 8"
ok "данные на месте: $CSV_COUNT файлов"

# --- 3. Python ------------------------------------------------------
step "Проверяю Python"

PY=()
# В Git Bash команды python/python3 могут вести к пустым алиасам Microsoft Store.
# Проверяем запуск и версию, а не только наличие команды в PATH.
if command -v python3 >/dev/null 2>&1 \
   && python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
  PY=(python3)
elif command -v py >/dev/null 2>&1 \
     && py -3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
  PY=(py -3)
elif command -v python >/dev/null 2>&1 \
     && python -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
  PY=(python)
else
  die "не найден работающий Python 3.10+" \
      "Установите Python 3.10 или новее. В Git Bash проверьте: py -3 --version.
Если работает только алиас Microsoft Store, отключите его в Windows: Settings → Apps → Advanced app settings → App execution aliases."
fi
ok "использую Python: ${PY[*]}"

"${PY[@]}" -c "import psycopg2" 2>/dev/null || {
  echo "    ставлю psycopg2-binary"
  "${PY[@]}" -m pip install --quiet psycopg2-binary 2>/dev/null \
    || "${PY[@]}" -m pip install --quiet --break-system-packages psycopg2-binary \
    || die "не удалось поставить psycopg2-binary" \
           "Поставьте вручную:  ${PY[*]} -m pip install psycopg2-binary"
}
ok "python и psycopg2 готовы"

# --- 4. Контейнер ---------------------------------------------------
if [ "$RESET" = "1" ]; then
  step "Сношу старую базу (--reset)"
  $DC --profile tools down -v --remove-orphans
  ok "удалено"
fi

step "Поднимаю PostgreSQL"
# Только postgres: pgadmin лежит в профиле tools и тянет лишние 400 МБ.
$DC up -d postgres || die "не удалось запустить контейнер" \
  "Посмотрите, что пишет:  $DC logs postgres"

printf "    жду готовности базы"
READY=0
for _ in $(seq 1 60); do
  if $DC exec -T postgres pg_isready -U hack -d marketplace >/dev/null 2>&1; then
    READY=1; break
  fi
  printf "."
  sleep 2
done
echo
[ "$READY" = "1" ] || die "база не ответила за две минуты" \
  "Посмотрите логи:  $DC logs postgres
Если порт 5432 занят другим постгресом, поменяйте проброс в docker-compose.yml
на \"5433:5432\" и запустите:  bash setup.sh --reset"
ok "база принимает подключения"

# --- 5. Загрузка ----------------------------------------------------
step "Загружаю сырые данные в схему raw"

PORT=$(awk -F'"' '/- "[0-9]+:5432"/ {split($2,a,":"); print a[1]; exit}' docker-compose.yml)
PORT=${PORT:-5432}

"${PY[@]}" scripts/load_raw.py --port "$PORT" || die "загрузка не прошла" \
  "Сообщение об ошибке выше. Частые причины:
  - контейнер ещё не готов, подождите полминуты и повторите
  - порт 5432 занят, смотрите подсказку про 5433"

# --- 6. Итог --------------------------------------------------------
step "Проверяю, что получилось"

$DC exec -T postgres psql -U hack -d marketplace -c "
SELECT s.schema_name AS shema, count(t.table_name) AS tablic
FROM information_schema.schemata s
LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
WHERE s.schema_name IN ('raw','core','mart')
GROUP BY 1 ORDER BY 1;"

$DC exec -T postgres psql -U hack -d marketplace -c "
SELECT 'raw.orders' t, count(*) FROM raw.orders
UNION ALL SELECT 'raw.order_items', count(*) FROM raw.order_items;"

echo
echo "====================================================================="
echo " Готово."
echo
echo " Подключение:  postgresql://hack:hack@localhost:$PORT/marketplace"
echo " Схемы:        raw (данные), core (ваша модель), mart (витрины)"
echo
echo " Задание и описание данных:  docs/handout.md"
echo " Вопросы к модели:           docs/tasks.md"
echo
echo " Веб-клиент, если нужен:  $DC --profile tools up -d"
echo "                          потом http://localhost:8080"
echo "====================================================================="
