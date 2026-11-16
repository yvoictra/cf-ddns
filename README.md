# Cloudflare Dynamic DNS Updater (cf-ddns)

Script ligero en Bash para actualizar automáticamente registros DNS de tipo `A` en Cloudflare cuando cambia la IP pública, con notificaciones y alertas de error mediante Telegram y registro en `syslog`.

## Características

- **Detección rápida de IP pública** mediante consulta DNS directa a OpenDNS (`dig`), sin depender de APIs HTTP externas.
- **Tolerancia a microcortes**: si falla la resolución DNS local o hay un timeout de red (`HTTP 000`), aborta silenciosamente en `syslog` sin generar falsas alarmas.
- **Alertas detalladas en Telegram**: notifica únicamente cuando se actualiza la IP o cuando la API de Cloudflare devuelve un error real (`4xx`/`5xx` o `success: false`).
- **Configuración externa mediante `.env`**: mantiene las credenciales de Telegram fuera del código fuente.
- **Multidominio / Multizona**: al recibir los datos de Cloudflare por parámetro, un mismo script sirve para actualizar múltiples subdominios o zonas distintas.

## Requisitos

Asegúrate de tener instaladas las siguientes utilidades en el sistema:

- `bash`
- `curl`
- `jq`
- `dig` (paquete `dnsutils` en Debian/Ubuntu o `bind-utils` en RHEL/Fedora)

```bash
sudo apt update && sudo apt install -y curl jq dnsutils
```

## Instalación y configuración

1. **Clona el repositorio:**
   ```bash
   git clone https://github.com/yvoictra/cf-ddns.git
   cd cf-ddns
   ```

2. **Configura las variables de Telegram:**
   Copia la plantilla de ejemplo y añade tus credenciales:
   ```bash
   cp .env.example .env
   chmod 600 .env
   nano .env
   ```

   Contenido de `.env`:
   ```env
   TG_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
   TG_CHAT_ID="-100123456789"
   TAG="ddns-cloudflare"
   ```

3. **Da permisos de ejecución al script:**
   ```bash
   chmod +x cf-ddns.sh
   ```

## Uso y ejecución de parámetros

El script requiere **3 parámetros posicionales obligatorios** en este orden exacto:

```bash
./cf-ddns.sh <API_TOKEN> <ZONE_ID> <RECORD_NAME>
```

### Descripción de los parámetros

| Posición | Parámetro | Descripción | Dónde obtenerlo en Cloudflare |
| :--- | :--- | :--- | :--- |
| **`$1`** | `API_TOKEN` | Token de API con permisos de edición DNS (`Zone` → `DNS` → `Edit`) restringido a tu zona. | *My Profile → API Tokens → Create Token* |
| **`$2`** | `ZONE_ID` | Identificador alfanumérico de 32 caracteres de la zona (dominio principal). | *Dashboard → Seleccionar dominio → Overview (columna derecha)* |
| **`$3`** | `RECORD_NAME` | Nombre FQDN completo del registro tipo `A` que quieres mantener actualizado. | *Dashboard → Seleccionar dominio → DNS → Records* |

> **Importante:** El registro DNS de tipo `A` **debe existir previamente** en el panel de Cloudflare (puedes crearlo inicialmente apuntando a `1.1.1.1`). El script actualiza su IP con `TTL=120` y `proxied=false`, pero no crea registros nuevos.

### Ejemplos de ejecución manual

**Actualizar un subdominio:**
```bash
./cf-ddns.sh "cf_token_ejemplo_12345" "023e105f4ecef8ad9ca31a8372d0c353" "casa.tudominio.com"
```

**Actualizar el dominio raíz (`@`):**
```bash
./cf-ddns.sh "cf_token_ejemplo_12345" "023e105f4ecef8ad9ca31a8372d0c353" "tudominio.com"
```

## Automatización con Cron

Para ejecutar la comprobación cada 5 minutos, edita el crontab (`crontab -e`) y añade una línea por cada registro que quieras mantener actualizado:

```cron
*/5 * * * * /ruta/completa/cf-ddns/cf-ddns.sh "TU_API_TOKEN" "TU_ZONE_ID" "casa.tudominio.com" >/dev/null 2>&1
```

*(No es necesario pasar variables de entorno en `cron`, ya que el script localiza y carga automáticamente el archivo `.env` situado en su mismo directorio).*

## Logs y monitorización

Toda la actividad (comprobaciones sin cambios, actualizaciones de IP y errores de API o red) se envía a `syslog` usando la etiqueta `TAG` definida en `.env`:

```bash
# Ver histórico en syslog
grep "ddns-cloudflare" /var/log/syslog

# Seguir logs en tiempo real con systemd/journald
journalctl -t ddns-cloudflare -f
```
