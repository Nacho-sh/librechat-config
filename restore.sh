#!/bin/bash
# restore.sh — restaurar estado completo de un checkpoint
# Uso: ./restore.sh <timestamp> [--source-only] [--config-only] [--list]
#
# Opciones:
#   --list          Muestra checkpoints disponibles y sale
#   --source-only   Solo restaura el código fuente (git), no toca config ni volúmenes
#   --config-only   Solo restaura .env, yamls, mcp y searxng; no toca volúmenes ni git

set -euo pipefail

# ── Configuración ────────────────────────────────────────────────────────────
DOCKER_BASE="${HOME}/.local/docker"
LIBRECHAT_DIR="${DOCKER_BASE}/LibreChat"
MCP_DIR="${DOCKER_BASE}/mcp"
SEARXNG_DIR="${DOCKER_BASE}/searxng"
BACKUP_DIR="${HOME}/.config/librechat-checkpoints"
SOURCE_ONLY=false
CONFIG_ONLY=false
TIMESTAMP=""

# ── Argumentos ───────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "Uso: restore.sh <timestamp> [--source-only] [--config-only] [--list]"
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      echo "Checkpoints disponibles:"
      echo ""
      for cp in "${BACKUP_DIR}"/*/; do
        ts=$(basename "$cp")
        label=""
        if [ -f "${cp}/meta.txt" ]; then
          label=$(grep '^label=' "${cp}/meta.txt" | cut -d= -f2-)
          skip_vols=$(grep '^skip_volumes=' "${cp}/meta.txt" | cut -d= -f2-)
        fi
        branch=""
        commit=""
        if [ -f "${cp}/source/git-branch.txt" ]; then
          branch=$(cat "${cp}/source/git-branch.txt")
          commit=$(cat "${cp}/source/git-commit.txt" | cut -c1-12)
        fi
        size=$(du -sh "$cp" 2>/dev/null | cut -f1)
        echo "  ${ts}  [${size}]"
        [ -n "$label" ]  && echo "    etiqueta : ${label}"
        [ -n "$branch" ] && echo "    git      : ${branch} @ ${commit}"
        [ "${skip_vols:-false}" = "true" ] && echo "    volúmenes: NO incluidos"
        echo ""
      done
      exit 0
      ;;
    --source-only) SOURCE_ONLY=true ;;
    --config-only) CONFIG_ONLY=true ;;
    -*) echo "Opción desconocida: $1" >&2; exit 1 ;;
    *)  TIMESTAMP="$1" ;;
  esac
  shift
done

CHECKPOINT="${BACKUP_DIR}/${TIMESTAMP}"

if [ ! -d "$CHECKPOINT" ]; then
  echo "✗ Checkpoint no encontrado: ${CHECKPOINT}"
  echo "  Usa restore.sh --list para ver los disponibles"
  exit 1
fi

# ── Confirmación ─────────────────────────────────────────────────────────────
echo "━━━ Restaurar checkpoint ${TIMESTAMP} ━━━"
if [ -f "${CHECKPOINT}/meta.txt" ]; then
  label=$(grep '^label=' "${CHECKPOINT}/meta.txt" | cut -d= -f2-)
  [ -n "$label" ] && echo "    ${label}"
fi
echo ""
echo "  Esto bajará los contenedores activos."
echo -n "  ¿Continuar? [s/N] "
read -r CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# ── Bajar contenedores ────────────────────────────────────────────────────────
echo ""
echo "▸ Bajando contenedores..."
docker compose -f "${LIBRECHAT_DIR}/docker-compose.yml" \
               -f "${LIBRECHAT_DIR}/docker-compose.override.yml" \
               down 2>/dev/null || true

# ── Restaurar configuración ───────────────────────────────────────────────────
if [ "$SOURCE_ONLY" = false ]; then
  echo ""
  echo "▸ Restaurando config LibreChat..."
  for f in .env librechat.yaml docker-compose.yml docker-compose.override.yml; do
    if [ -f "${CHECKPOINT}/${f}" ]; then
      cp "${CHECKPOINT}/${f}" "${LIBRECHAT_DIR}/"
      echo "  ✓ ${f}"
    fi
  done

  # MCP
  if [ -d "${CHECKPOINT}/mcp" ] && [ "$(ls -A "${CHECKPOINT}/mcp")" ]; then
    echo ""
    echo "▸ Restaurando MCP..."
    rsync -a --delete \
      --exclude='node_modules/' \
      --exclude='.venv/' \
      --exclude='__pycache__/' \
      "${CHECKPOINT}/mcp/" "${MCP_DIR}/"
    echo "  ✓ Restaurado"
  fi

  # SearXNG
  if [ -d "${CHECKPOINT}/searxng" ] && [ "$(ls -A "${CHECKPOINT}/searxng")" ]; then
    echo ""
    echo "▸ Restaurando SearXNG..."
    rsync -a --delete "${CHECKPOINT}/searxng/" "${SEARXNG_DIR}/"
    echo "  ✓ Restaurado"
  fi
fi

# ── Restaurar código fuente git ───────────────────────────────────────────────
if [ "$CONFIG_ONLY" = false ] && [ -f "${CHECKPOINT}/source/git-commit.txt" ]; then
  echo ""
  echo "▸ Restaurando código fuente git..."
  TARGET_COMMIT=$(cat "${CHECKPOINT}/source/git-commit.txt")
  TARGET_BRANCH=$(cat "${CHECKPOINT}/source/git-branch.txt")
  echo "  Branch: ${TARGET_BRANCH}"
  echo "  Commit: ${TARGET_COMMIT:0:12}"

  # Verificar que el commit existe localmente
  if git -C "${LIBRECHAT_DIR}" cat-file -e "${TARGET_COMMIT}^{commit}" 2>/dev/null; then
    git -C "${LIBRECHAT_DIR}" checkout "${TARGET_BRANCH}" -- 2>/dev/null || true
    git -C "${LIBRECHAT_DIR}" reset --hard "${TARGET_COMMIT}"
    echo "  ✓ Código restaurado a ${TARGET_COMMIT:0:12}"

    # Si había un diff sin commitear, avisar (no aplicarlo automáticamente — podría romper)
    if [ -s "${CHECKPOINT}/source/git-diff.patch" ]; then
      echo ""
      echo "  ⚠ Había cambios sin commitear en el checkpoint."
      echo "    El patch está guardado en:"
      echo "    ${CHECKPOINT}/source/git-diff.patch"
      echo "    Para aplicarlo manualmente: git apply ${CHECKPOINT}/source/git-diff.patch"
    fi
  else
    echo "  ✗ Commit ${TARGET_COMMIT:0:12} no encontrado en el repo local."
    echo "    Es posible que hayas hecho git pull desde entonces."
    echo "    Revisa git log en ${LIBRECHAT_DIR}"
  fi
fi

# ── Restaurar volúmenes ───────────────────────────────────────────────────────
if [ "$CONFIG_ONLY" = false ] && [ "$SOURCE_ONLY" = false ]; then
  VOLS_DIR="${CHECKPOINT}/volumes"
  if [ -d "$VOLS_DIR" ] && [ "$(ls -A "$VOLS_DIR")" ]; then
    echo ""
    echo "▸ Restaurando volúmenes Docker..."
    for tarfile in "${VOLS_DIR}"/*.tar.gz; do
      volname=$(basename "$tarfile" .tar.gz)
      echo -n "  • ${volname}... "
      docker volume rm "$volname" 2>/dev/null || true
      docker volume create "$volname" > /dev/null
      docker run --rm \
        -v "${volname}":/data \
        -v "${VOLS_DIR}":/backup \
        alpine tar xzf "/backup/$(basename "$tarfile")" -C /data
      echo "ok"
    done
  else
    echo ""
    echo "▸ Volúmenes: no hay snapshots en este checkpoint (fue creado con --no-volumes)"
  fi
fi

# ── Levantar servicios ────────────────────────────────────────────────────────
echo ""
echo "▸ Levantando servicios..."
docker compose -f "${LIBRECHAT_DIR}/docker-compose.yml" \
               -f "${LIBRECHAT_DIR}/docker-compose.override.yml" \
               up -d

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Restaurado a checkpoint ${TIMESTAMP}"
echo ""
echo "  Imágenes que estaban activas en ese momento:"
cat "${CHECKPOINT}/docker-images.txt" | grep -v '^#' | awk '{print "  ", $1, "→", $2}'
