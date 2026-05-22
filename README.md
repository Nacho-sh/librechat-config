# librechat-config

Infraestructura personal para LibreChat con llama.cpp.

## Estructura

- `checkpoint.sh` / `restore.sh` — backup y restauración de estado completo
- `update-librechat.sh` — actualización manteniendo el branch de personalización
- `docker-compose.override.yml` — servicios extra (SearXNG, MCP servers)
- `librechat.yaml` — configuración de LibreChat (sin secretos; ver `.env.example`)

## Variables necesarias en .env

(lista aquí las variables que uses)
