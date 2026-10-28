#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

# Git Bash может не видеть Docker Desktop CLI, который уже установлен в Windows.
# Как и setup.sh, ищем только стандартные каталоги и меняем PATH лишь для скрипта.
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

if [ -z "${DC:-}" ]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    echo "ОШИБКА: не найден Docker Compose. Запустите Docker Desktop и проверьте docker compose version." >&2
    exit 1
  fi
fi

# Сборка и контроль — одна транзакция. При ошибке psql откатывает обе части.
{
  # Ускоряет проверки исходных ключей; действует только внутри этой транзакции.
  printf "SET LOCAL work_mem = '64MB';\n"
  cat model/01_build_core.sql
  printf '\n'
  cat model/03_quality_checks.sql
} | $DC exec -T postgres psql -X -v ON_ERROR_STOP=1 --single-transaction \
      -U hack -d marketplace -f -

# Отчёты печатаются только после успешной фиксации новой модели.
$DC exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace \
    -f - < model/02_answers.sql
