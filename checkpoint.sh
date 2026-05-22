#!/bin/bash
# checkpoint.sh — guardar estado completo antes de cambios en LibreChat
# Uso: ./checkpoint.sh [--no-volumes] [--label "descripción"]
#
# Opciones:
#   --no-volumes   Salta el snapshot de volúmenes Docker (más rápido)
#   --label TEXT   Añade una etiqueta legible al checkpoint

set -euo pipefail

# ── Configuración ────────────────────────────────────────────────────────────
DOCKER_BASE="${HOME}/.local/docker"
LIBRECHAT_DIR="${DOCKER_BASE}/LibreChat"
MCP_DIR="${DOCKER_BASE}/mcp"
SEARXNG_DIR="${DOCKER_BASE}/searxng"
BACKUP_DIR="${HOME}/.config/librechat-checkpoints"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CHECKPOINT="${BACKUP_DIR}/${TIMESTAMP}"
SKIP_VOLUMES=false
LABEL=""

# ── Argumentos ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-volumes) SKIP_VOLUMES=true ;;
    --label) LABEL="$2"; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Preparar estructura ───────────────────────────────────────────────────────
mkdir -p "${CHECKPOINT}/volumes"
mkdir -p "${CHECKPOINT}/source"
mkdir -p "${CHECKPOINT}/mcp"
mkdir -p "${CHECKPOINT}/searxng"

echo "━━━ Checkpoint ${TIMESTAMP} ━━━"
[ -n "$LABEL" ] && echo "    ${LABEL}"

# ── 1. Archivos de configuración de LibreChat ─────────────────────────────────
echo ""
echo "▸ Config LibreChat..."
for f in .env librechat.yaml docker-compose.yml docker-compose.override.yml; do
  if [ -f "${LIBRECHAT_DIR}/${f}" ]; then
    cp "${LIBRECHAT_DIR}/${f}" "${CHECKPOINT}/"
    echo "  ✓ ${f}"
  fi
done

# ── 2. Código fuente del repo (para capturar branch + commits locales) ────────
echo ""
echo "▸ Estado del repo git..."
if [ -d "${LIBRECHAT_DIR}/.git" ]; then
  # Guardar hash actual, branch, y cualquier diff no commiteado
  git -C "${LIBRECHAT_DIR}" rev-parse HEAD           > "${CHECKPOINT}/source/git-commit.txt"
  git -C "${LIBRECHAT_DIR}" branch --show-current    > "${CHECKPOINT}/source/git-branch.txt"
  git -C "${LIBRECHAT_DIR}" status --short           > "${CHECKPOINT}/source/git-status.txt"
  git -C "${LIBRECHAT_DIR}" diff HEAD                > "${CHECKPOINT}/source/git-diff.patch"
  git -C "${LIBRECHAT_DIR}" log --oneline -20        > "${CHECKPOINT}/source/git-log.txt"
  COMMIT=$(cat "${CHECKPOINT}/source/git-commit.txt")
  BRANCH=$(cat "${CHECKPOINT}/source/git-branch.txt")
  echo "  ✓ branch=${BRANCH}  commit=${COMMIT:0:12}"
else
  echo "  ⚠ No hay repo git en ${LIBRECHAT_DIR}"
fi

# ── 3. Imágenes Docker en uso (nombre + digest exacto) ───────────────────────
echo ""
echo "▸ Imágenes Docker en uso..."
{
  echo "# Imágenes activas al momento del checkpoint ${TIMESTAMP}"
  echo "# Formato: CONTAINER  IMAGE  DIGEST"
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.ID}}' | while read -r name image cid; do
    digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "sin-digest")
    echo "${name}	${image}	${digest}"
  done
} > "${CHECKPOINT}/docker-images.txt"
echo "  ✓ $(wc -l < "${CHECKPOINT}/docker-images.txt") contenedores registrados"

# ── 4. Directorio MCP ─────────────────────────────────────────────────────────
echo ""
echo "▸ Archivos MCP..."
if [ -d "${MCP_DIR}" ]; then
  # Copiar todo excepto node_modules, .venv, __pycache__, builds pesados
  rsync -a --quiet \
    --exclude='node_modules/' \
    --exclude='.venv/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='dist/' \
    --exclude='build/' \
    "${MCP_DIR}/" "${CHECKPOINT}/mcp/"
  echo "  ✓ $(find "${CHECKPOINT}/mcp" -type f | wc -l) archivos"
else
  echo "  ⚠ No encontrado: ${MCP_DIR}"
fi

# ── 5. Configuración SearXNG ──────────────────────────────────────────────────
echo ""
echo "▸ Config SearXNG..."
if [ -d "${SEARXNG_DIR}" ]; then
  cp -r "${SEARXNG_DIR}/." "${CHECKPOINT}/searxng/"
  echo "  ✓ $(find "${CHECKPOINT}/searxng" -type f | wc -l) archivos"
else
  echo "  ⚠ No encontrado: ${SEARXNG_DIR}"
fi

# ── 6. Volúmenes Docker ───────────────────────────────────────────────────────
if [ "$SKIP_VOLUMES" = false ]; then
  echo ""
  echo "▸ Volúmenes Docker..."
  # Capturar volúmenes relacionados con librechat (nombre o montaje)
  VOLS=$(docker volume ls --format '{{.Name}}' | grep -iE 'librechat|pgdata|meili' || true)
  if [ -z "$VOLS" ]; then
    echo "  ⚠ No se encontraron volúmenes relevantes"
  else
    for vol in $VOLS; do
      echo -n "  • ${vol}... "
      docker run --rm \
        -v "${vol}":/data \
        -v "${CHECKPOINT}/volumes":/backup \
        alpine tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null
      SIZE=$(du -sh "${CHECKPOINT}/volumes/${vol}.tar.gz" | cut -f1)
      echo "${SIZE}"
    done
  fi
else
  echo ""
  echo "▸ Volúmenes: omitidos (--no-volumes)"
fi

# ── 7. Metadata del checkpoint ────────────────────────────────────────────────
{
  echo "timestamp=${TIMESTAMP}"
  echo "label=${LABEL}"
  echo "skip_volumes=${SKIP_VOLUMES}"
  echo "hostname=$(hostname)"
  echo "user=$(whoami)"
  echo "librechat_dir=${LIBRECHAT_DIR}"
} > "${CHECKPOINT}/meta.txt"

# ── 8. Tamaño total ───────────────────────────────────────────────────────────
TOTAL_SIZE=$(du -sh "${CHECKPOINT}" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Checkpoint guardado en:"
echo "  ${CHECKPOINT}"
echo "  Tamaño total: ${TOTAL_SIZE}"
[ -n "$LABEL" ] && echo "  Etiqueta: ${LABEL}"
echo ""
echo "  Para restaurar:"
echo "  restore.sh ${TIMESTAMP}"
