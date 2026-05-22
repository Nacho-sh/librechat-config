#!/bin/bash
# update-librechat.sh — actualizar LibreChat manteniendo el branch de personalización
# Uso: ./update-librechat.sh [--no-checkpoint] [--no-volumes]
#
# Qué hace:
#   1. Crea un checkpoint automático (configurable)
#   2. Hace fetch del upstream
#   3. Merge de main → tu branch de personalización
#   4. Si hay conflictos, para y te guía
#   5. Rebuild + restart de los contenedores afectados

set -euo pipefail

# ── Configuración ────────────────────────────────────────────────────────────
DOCKER_BASE="${HOME}/.local/docker"
LIBRECHAT_DIR="${DOCKER_BASE}/LibreChat"
SCRIPTS_DIR="${DOCKER_BASE}"          # donde están checkpoint.sh y restore.sh
CUSTOM_BRANCH="nacho/llama-timings"   # ← tu branch de personalización (ajustar si cambia)
UPSTREAM_BRANCH="main"
SKIP_CHECKPOINT=false
CHECKPOINT_ARGS=""

# ── Argumentos ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-checkpoint) SKIP_CHECKPOINT=true ;;
    --no-volumes)    CHECKPOINT_ARGS="--no-volumes" ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Verificaciones previas ───────────────────────────────────────────────────
cd "${LIBRECHAT_DIR}"

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$CUSTOM_BRANCH" ]; then
  echo "⚠ Estás en el branch '${CURRENT_BRANCH}', no en '${CUSTOM_BRANCH}'."
  echo -n "  ¿Continuar igualmente? [s/N] "
  read -r CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

if ! git diff --quiet HEAD 2>/dev/null; then
  echo "✗ Hay cambios sin commitear en el repo."
  echo "  Haz commit o stash antes de actualizar."
  echo "  Estado actual:"
  git status --short
  exit 1
fi

# ── Checkpoint pre-update ─────────────────────────────────────────────────────
if [ "$SKIP_CHECKPOINT" = false ]; then
  echo "▸ Creando checkpoint pre-update..."
  "${SCRIPTS_DIR}/checkpoint.sh" --label "pre-update automático" ${CHECKPOINT_ARGS}
  echo ""
fi

# ── Fetch upstream ────────────────────────────────────────────────────────────
echo "▸ Fetching upstream..."
git fetch upstream

# Ver qué commits nuevos hay en main
NEW_COMMITS=$(git log HEAD..origin/${UPSTREAM_BRANCH} --oneline 2>/dev/null | wc -l | tr -d ' ')
if [ "$NEW_COMMITS" -eq 0 ]; then
  echo "  Ya estás al día con origin/${UPSTREAM_BRANCH}. No hay nada nuevo."
  echo ""
  echo "  Si solo quieres rebuildar sin actualizar:"
  echo "  docker compose -f docker-compose.yml -f docker-compose.override.yml up -d --build api"
  exit 0
fi

echo "  ${NEW_COMMITS} commit(s) nuevos en origin/${UPSTREAM_BRANCH}:"
git log HEAD..origin/${UPSTREAM_BRANCH} --oneline | head -20 | sed 's/^/    /'
echo ""

# ── Merge upstream → custom branch ───────────────────────────────────────────
echo "▸ Mergeando origin/${UPSTREAM_BRANCH} → ${CURRENT_BRANCH}..."

# Intentar merge
if git merge "upstream/${UPSTREAM_BRANCH}" --no-edit 2>&1; then
  echo "  ✓ Merge limpio"
else
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✗ CONFLICTOS DE MERGE"
  echo ""
  echo "  Archivos con conflictos:"
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  echo ""
  echo "  Qué hacer:"
  echo "  1. Edita cada archivo conflictivo (busca <<<<<<< / ======= / >>>>>>>)"
  echo "  2. git add <archivo> para cada uno resuelto"
  echo "  3. git commit"
  echo "  4. Vuelve a ejecutar este script con --no-checkpoint"
  echo ""
  echo "  Para abortar el merge y volver al estado anterior:"
  echo "  git merge --abort"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi

# ── Rebuild y restart ─────────────────────────────────────────────────────────
echo ""
echo "▸ Rebuilding imagen de LibreChat..."
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  build --no-cache api

echo ""
echo "▸ Reiniciando contenedores afectados..."
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  up -d --no-deps api

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ LibreChat actualizado"
echo ""
echo "  Branch: ${CURRENT_BRANCH}"
echo "  Commit: $(git rev-parse --short HEAD)"
echo ""
echo "  Logs en tiempo real:"
echo "  docker logs -f LibreChat"
