#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="${DC:-docker compose}"
PORT="${PORT:-5432}"

cd "$ROOT"
$DC exec -T postgres psql -v ON_ERROR_STOP=1 -U hack -d marketplace -f - < model/01_build_core.sql
$DC exec -T postgres psql -v ON_ERROR_STOP=1 -U hack -d marketplace -f - < model/03_quality_checks.sql
$DC exec -T postgres psql -v ON_ERROR_STOP=1 -U hack -d marketplace -f - < model/02_answers.sql
