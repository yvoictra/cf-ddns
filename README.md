# Cloudflare Dynamic DNS Updater

Script ligero en Bash para actualizar automáticamente registros DNS de tipo `A` en Cloudflare cuando cambia la IP pública, con notificaciones y alertas de error mediante Telegram y registro en `syslog`.

## Características

- **Detección rápida de IP pública** mediante consulta DNS directa a OpenDNS (`dig`), sin depender de APIs HTTP externas.
- **Tolerancia a microcortes**: si falla la resolución DNS local o hay un timeout de red (`HTTP 000`), aborta silenciosamente en `syslog` sin generar falsas alarmas.
- **Alertas detalladas en Telegram**: notifica únicamente cuando se actualiza la IP o cuando la API de Cloudflare devuelve un error real (`4xx`/`5xx` o `success: false`).
- **Configuración externa mediante `.env`**: mantiene credenciales y tokens fuera del código fuente.

## Requisitos

Asegúrate de tener instaladas las siguientes utilidades en el sistema:

- `bash`
- `curl`
- `jq`
- `dig` (paquete `dnsutils` en Debian/Ubuntu o `bind-utils` en RHEL/Fedora)

```bash
sudo apt update && sudo apt install -y curl jq dnsutils
