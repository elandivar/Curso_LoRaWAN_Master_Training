#!/usr/bin/env bash
# Instalador interactivo de ChirpStack v4 para Debian / Ubuntu.
# Diseñado para Raspberry Pi OS / Debian ARM64, pero también funciona en amd64.
#
# Instala y configura:
#   - PostgreSQL + pg_trgm
#   - Redis
#   - Mosquitto (broker MQTT local)
#   - ChirpStack v4
#   - ChirpStack Gateway Bridge (opcional, Semtech UDP)
#
# No modifica automáticamente global_conf.json / local_conf.json del Packet Forwarder.

set -Eeuo pipefail
IFS=$'\n\t'

CHIRPSTACK_CONF="/etc/chirpstack/chirpstack.toml"
GWB_CONF="/etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml"
APT_SOURCE="/etc/apt/sources.list.d/chirpstack.list"
APT_KEY="/etc/apt/keyrings/chirpstack.gpg"
DB_NAME="chirpstack"
DB_USER="chirpstack"

# ---------- Presentación ----------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi

info()  { printf '%s\n' "${GREEN}==>${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW}Aviso:${RESET} $*" >&2; }
error() { printf '%s\n' "${RED}Error:${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

on_error() {
  local exit_code=$?
  error "La instalación se detuvo en la línea ${BASH_LINENO[0]} (código ${exit_code})."
  exit "$exit_code"
}
trap on_error ERR

cleanup() {
  local file
  for file in \
    "${TMP_KEY:-}" \
    "${TMP_CS_CONF:-}" \
    "${TMP_GWB_CONF:-}" \
    "${ADMIN_PASSWORD_FILE:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
  unset DB_PASSWORD DB_PASSWORD_2 ADMIN_PASSWORD ADMIN_PASSWORD_2
}
trap cleanup EXIT

# Lee siempre desde la terminal, incluso si el script se ejecuta mediante una tubería.
[[ -r /dev/tty ]] || die "Se requiere una terminal interactiva."

ask_yes_no() {
  local question="$1"
  local default="${2:-yes}"
  local hint answer

  if [[ "$default" == "yes" ]]; then
    hint="[S/n]"
  else
    hint="[s/N]"
  fi

  while true; do
    read -r -p "$question $hint " answer </dev/tty
    answer="${answer,,}"
    case "$answer" in
      "") [[ "$default" == "yes" ]] && return 0 || return 1 ;;
      s|si|sí|y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Responde s o n." ;;
    esac
  done
}

ask_value() {
  local question="$1"
  local default="$2"
  local answer
  read -r -p "$question [$default]: " answer </dev/tty
  printf '%s' "${answer:-$default}"
}

ask_password() {
  while true; do
    read -r -s -p "Contraseña para la base PostgreSQL de ChirpStack: " DB_PASSWORD </dev/tty
    printf '\n'

    if (( ${#DB_PASSWORD} < 8 )); then
      warn "Usa al menos 8 caracteres."
      continue
    fi

    read -r -s -p "Repite la contraseña: " DB_PASSWORD_2 </dev/tty
    printf '\n'

    if [[ "$DB_PASSWORD" != "$DB_PASSWORD_2" ]]; then
      warn "Las contraseñas no coinciden."
      continue
    fi

    unset DB_PASSWORD_2
    break
  done
}

ask_admin_password() {
  while true; do
    read -r -s -p "Nueva contraseña para el usuario web admin: " ADMIN_PASSWORD </dev/tty
    printf '\n'

    if (( ${#ADMIN_PASSWORD} < 8 )); then
      warn "Usa al menos 8 caracteres."
      continue
    fi

    read -r -s -p "Repite la contraseña de admin: " ADMIN_PASSWORD_2 </dev/tty
    printf '\n'

    if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_2" ]]; then
      warn "Las contraseñas no coinciden."
      continue
    fi

    unset ADMIN_PASSWORD_2
    break
  done
}

# ---------- Privilegios ----------

if (( EUID == 0 )); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "Instala sudo o ejecuta este script como root."
  sudo -v
  SUDO=(sudo)
fi

root() {
  "${SUDO[@]}" "$@"
}

as_postgres() {
  if (( EUID == 0 )); then
    runuser -u postgres -- "$@"
  else
    sudo -u postgres "$@"
  fi
}

# ---------- Validación del sistema ----------

[[ -f /etc/os-release ]] || die "No encuentro /etc/os-release."
# shellcheck disable=SC1091
source /etc/os-release

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$ARCH" in
  arm64|armhf|amd64) ;;
  *) warn "Arquitectura no probada por este script: ${ARCH:-desconocida}." ;;
esac

case "${ID:-}" in
  debian|ubuntu|raspbian) ;;
  *) warn "Distribución no probada: ${PRETTY_NAME:-desconocida}." ;;
esac

printf '\n%sInstalador interactivo de ChirpStack v4%s\n' "$BOLD" "$RESET"
printf 'Sistema: %s | Arquitectura: %s\n\n' "${PRETTY_NAME:-desconocido}" "${ARCH:-desconocida}"
printf '%s\n' \
  "Se instalarán PostgreSQL, Redis, Mosquitto y ChirpStack." \
  "Los archivos existentes de configuración se respaldarán antes de modificarlos." \
  "El broker MQTT quedará local en 127.0.0.1:1883."
printf '\n'

ask_yes_no "¿Continuar?" yes || exit 0

# ---------- Preferencias ----------

ask_password

if ask_yes_no "¿Establecer ahora una contraseña distinta para el usuario web admin?" yes; then
  SET_ADMIN_PASSWORD="yes"
  ask_admin_password
else
  SET_ADMIN_PASSWORD="no"
  ADMIN_PASSWORD=""
fi

while true; do
  NET_ID="$(ask_value "NetID LoRaWAN, 3 bytes hexadecimales" "000000")"
  NET_ID="${NET_ID^^}"
  [[ "$NET_ID" =~ ^[0-9A-F]{6}$ ]] && break
  warn "El NetID debe tener exactamente 6 caracteres hexadecimales, por ejemplo 000000."
done

while true; do
  WEB_PORT="$(ask_value "Puerto de la interfaz web" "8080")"
  [[ "$WEB_PORT" =~ ^[0-9]+$ ]] && (( WEB_PORT >= 1 && WEB_PORT <= 65535 )) && break
  warn "Introduce un puerto entre 1 y 65535."
done

if ask_yes_no "¿Permitir acceso a la interfaz web desde la red local?" yes; then
  API_HOST="0.0.0.0"
else
  API_HOST="127.0.0.1"
fi

if ask_yes_no "¿Instalar Gateway Bridge para un Semtech UDP Packet Forwarder?" yes; then
  INSTALL_GWB="yes"

  if ask_yes_no "¿El Packet Forwarder corre en esta misma Raspberry Pi?" yes; then
    PF_LOCAL="yes"
    UDP_HOST="127.0.0.1"
  else
    PF_LOCAL="no"
    UDP_HOST="0.0.0.0"
    warn "Semtech UDP no cifra ni autentica el tráfico. No expongas el puerto directamente a Internet."
  fi

  while true; do
    UDP_PORT="$(ask_value "Puerto UDP del Gateway Bridge" "1700")"
    [[ "$UDP_PORT" =~ ^[0-9]+$ ]] && (( UDP_PORT >= 1 && UDP_PORT <= 65535 )) && break
    warn "Introduce un puerto entre 1 y 65535."
  done
else
  INSTALL_GWB="no"
  PF_LOCAL="no"
  UDP_HOST=""
  UDP_PORT=""
fi

printf '\n'
info "Instalando dependencias..."
root apt-get update
root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  gpg \
  mosquitto \
  mosquitto-clients \
  openssl \
  postgresql \
  postgresql-contrib \
  python3-minimal \
  redis-server \
  redis-tools

root systemctl enable --now mosquitto redis-server postgresql

# Comprueba que el broker local acepta conexiones anónimas locales, como espera esta instalación.
if ! mosquitto_pub -h 127.0.0.1 -p 1883 -t chirpstack/installer/test -m ok >/dev/null 2>&1; then
  die "Mosquitto no acepta conexiones locales sin credenciales en 127.0.0.1:1883. Revisa su configuración existente."
fi

# ---------- PostgreSQL ----------

info "Creando o actualizando la base de datos..."
as_postgres psql \
  --set=ON_ERROR_STOP=1 \
  --set=dbpass="$DB_PASSWORD" <<'SQL'
SELECT format(
  'CREATE ROLE chirpstack LOGIN PASSWORD %L',
  :'dbpass'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = 'chirpstack'
)
\gexec

ALTER ROLE chirpstack WITH LOGIN PASSWORD :'dbpass';

SELECT 'CREATE DATABASE chirpstack OWNER chirpstack'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'chirpstack'
)
\gexec

ALTER DATABASE chirpstack OWNER TO chirpstack;
SQL

as_postgres psql \
  --set=ON_ERROR_STOP=1 \
  --dbname="$DB_NAME" \
  --command="CREATE EXTENSION IF NOT EXISTS pg_trgm;"

PGPASSWORD="$DB_PASSWORD" psql \
  -h 127.0.0.1 \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -tAc 'SELECT 1;' >/dev/null

# URL-encode para que caracteres especiales no rompan el DSN.
DB_PASSWORD_URLENC="$(printf '%s' "$DB_PASSWORD" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')"

# ---------- Repositorio de ChirpStack ----------

info "Configurando el repositorio oficial de ChirpStack..."
root install -d -m 0755 /etc/apt/keyrings
TMP_KEY="$(mktemp)"
curl -fsSL https://artifacts.chirpstack.io/packages/chirpstack.key \
  | gpg --dearmor --batch --yes -o "$TMP_KEY"
root install -o root -g root -m 0644 "$TMP_KEY" "$APT_KEY"
rm -f "$TMP_KEY"

printf '%s\n' \
  "deb [signed-by=${APT_KEY}] https://artifacts.chirpstack.io/packages/4.x/deb stable main" \
  | root tee "$APT_SOURCE" >/dev/null

root apt-get update

PACKAGES=(chirpstack)
if [[ "$INSTALL_GWB" == "yes" ]]; then
  PACKAGES+=(chirpstack-gateway-bridge)
fi
root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

root systemctl stop chirpstack 2>/dev/null || true
if [[ "$INSTALL_GWB" == "yes" ]]; then
  root systemctl stop chirpstack-gateway-bridge 2>/dev/null || true
fi

# ---------- Selección dinámica de región ----------

mapfile -t REGION_FILES < <(find /etc/chirpstack -maxdepth 1 -type f -name 'region_*.toml' | sort)
(( ${#REGION_FILES[@]} > 0 )) || die "No se encontraron archivos region_*.toml en /etc/chirpstack."

REGION_IDS=()
REGION_DESCRIPTIONS=()
REGION_TOPICS=()
VALID_REGION_FILES=()

for region_file in "${REGION_FILES[@]}"; do
  region_id="$(sed -nE 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$region_file" | head -n1)"
  region_description="$(sed -nE 's/^[[:space:]]*description[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$region_file" | head -n1)"
  region_topic="$(sed -nE 's/^[[:space:]]*topic_prefix[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$region_file" | head -n1)"

  [[ -n "$region_id" ]] || continue
  [[ -n "$region_description" ]] || region_description="$region_id"
  [[ -n "$region_topic" ]] || region_topic="$region_id"

  VALID_REGION_FILES+=("$region_file")
  REGION_IDS+=("$region_id")
  REGION_DESCRIPTIONS+=("$region_description")
  REGION_TOPICS+=("$region_topic")
done

(( ${#REGION_IDS[@]} > 0 )) || die "No fue posible leer las regiones instaladas."

DEFAULT_REGION_INDEX=0
for i in "${!REGION_IDS[@]}"; do
  if [[ "${REGION_IDS[$i]}" == "au915_1" ]]; then
    DEFAULT_REGION_INDEX="$i"
    break
  fi
done

printf '\n%sRegiones disponibles:%s\n' "$BOLD" "$RESET"
for i in "${!REGION_IDS[@]}"; do
  printf '  %2d) %-15s %s\n' "$((i + 1))" "${REGION_IDS[$i]}" "${REGION_DESCRIPTIONS[$i]}"
done
printf '\n'

while true; do
  read -r -p "Selecciona la región [$((DEFAULT_REGION_INDEX + 1))]: " REGION_CHOICE </dev/tty
  REGION_CHOICE="${REGION_CHOICE:-$((DEFAULT_REGION_INDEX + 1))}"

  if [[ "$REGION_CHOICE" =~ ^[0-9]+$ ]] \
    && (( REGION_CHOICE >= 1 && REGION_CHOICE <= ${#REGION_IDS[@]} )); then
    REGION_INDEX="$((REGION_CHOICE - 1))"
    break
  fi

  REGION_INDEX=""
  for i in "${!REGION_IDS[@]}"; do
    if [[ "${REGION_IDS[$i]}" == "$REGION_CHOICE" ]]; then
      REGION_INDEX="$i"
      break
    fi
  done
  [[ -n "$REGION_INDEX" ]] && break

  warn "Selecciona un número válido o escribe el ID exacto de la región."
done

REGION_ID="${REGION_IDS[$REGION_INDEX]}"
REGION_DESCRIPTION="${REGION_DESCRIPTIONS[$REGION_INDEX]}"
REGION_TOPIC="${REGION_TOPICS[$REGION_INDEX]}"
REGION_FILE="${VALID_REGION_FILES[$REGION_INDEX]}"

info "Región seleccionada: ${REGION_ID} — ${REGION_DESCRIPTION}"

# ---------- Configuración de ChirpStack ----------

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CS_BACKUP=""
REGION_BACKUP=""
GWB_BACKUP=""

if [[ -f "$CHIRPSTACK_CONF" ]]; then
  CS_BACKUP="${CHIRPSTACK_CONF}.bak-${TIMESTAMP}"
  root cp -a "$CHIRPSTACK_CONF" "$CS_BACKUP"
fi

# Conserva el secreto API existente cuando ya es válido, para no invalidar sesiones al repetir el script.
API_SECRET=""
if [[ -f "$CHIRPSTACK_CONF" ]]; then
  API_SECRET="$(root python3 - "$CHIRPSTACK_CONF" <<'PY' 2>/dev/null || true
import re
import sys
import tomllib
try:
    with open(sys.argv[1], "rb") as f:
        value = tomllib.load(f).get("api", {}).get("secret", "")
    if (
        isinstance(value, str)
        and value != "you-must-replace-this"
        and re.fullmatch(r"[A-Za-z0-9+/=_-]+", value)
    ):
        print(value)
except Exception:
    pass
PY
)"
fi
[[ -n "$API_SECRET" ]] || API_SECRET="$(openssl rand -base64 32)"

TMP_CS_CONF="$(mktemp)"
cat >"$TMP_CS_CONF" <<EOF
[logging]
level = "info"

[postgresql]
dsn = "postgres://chirpstack:${DB_PASSWORD_URLENC}@127.0.0.1/chirpstack?sslmode=disable"
max_open_connections = 10
min_idle_connections = 0
connection_recycling_method = "verified"

[redis]
servers = ["redis://127.0.0.1/"]
cluster = false

[network]
net_id = "${NET_ID}"
enabled_regions = ["${REGION_ID}"]

[api]
bind = "${API_HOST}:${WEB_PORT}"
secret = "${API_SECRET}"

[integration]
enabled = ["mqtt"]

[integration.mqtt]
server = "tcp://127.0.0.1:1883/"
json = true
EOF

CS_SERVICE_USER="$(systemctl show -p User --value chirpstack 2>/dev/null || true)"
[[ -n "$CS_SERVICE_USER" ]] || CS_SERVICE_USER="root"
if id "$CS_SERVICE_USER" >/dev/null 2>&1; then
  CS_GROUP="$(id -gn "$CS_SERVICE_USER")"
else
  CS_GROUP="root"
fi
root install -o root -g "$CS_GROUP" -m 0640 "$TMP_CS_CONF" "$CHIRPSTACK_CONF"
rm -f "$TMP_CS_CONF"

# Asegura que el backend MQTT de la región elegida use el broker local.
REGION_BACKUP="${REGION_FILE}.bak-${TIMESTAMP}"
root cp -a "$REGION_FILE" "$REGION_BACKUP"
root python3 - "$REGION_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
section = "regions.gateway.backend.mqtt"
replacements = {
    "server": 'server = "tcp://127.0.0.1:1883"',
    "username": 'username = ""',
    "password": 'password = ""',
}

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

section_re = re.compile(r"^\s*\[\[?([^\]]+)\]\]?\s*(?:#.*)?$")
key_re = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=")
in_section = False
found = set()
out = []
inserted = False

for line in lines:
    match = section_re.match(line)
    if match:
        if in_section and not inserted:
            for key, replacement in replacements.items():
                if key not in found:
                    out.append(replacement + "\n")
            inserted = True
        in_section = match.group(1).strip() == section

    if in_section:
        key_match = key_re.match(line)
        if key_match and key_match.group(1) in replacements:
            key = key_match.group(1)
            out.append(replacements[key] + "\n")
            found.add(key)
            continue

    out.append(line)

if in_section and not inserted:
    for key, replacement in replacements.items():
        if key not in found:
            out.append(replacement + "\n")
    inserted = True

if not inserted and not found:
    raise SystemExit(f"No se encontró la sección [{section}] en {path}")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY

# Valida toda la configuración con el binario instalado.
if ! root chirpstack --config /etc/chirpstack configfile >/dev/null; then
  [[ -n "$CS_BACKUP" ]] && root cp -a "$CS_BACKUP" "$CHIRPSTACK_CONF"
  [[ -n "$REGION_BACKUP" ]] && root cp -a "$REGION_BACKUP" "$REGION_FILE"
  die "La configuración de ChirpStack no pasó la validación; se restauraron los respaldos."
fi

# ---------- Gateway Bridge ----------

if [[ "$INSTALL_GWB" == "yes" ]]; then
  if [[ -f "$GWB_CONF" ]]; then
    GWB_BACKUP="${GWB_CONF}.bak-${TIMESTAMP}"
    root cp -a "$GWB_CONF" "$GWB_BACKUP"
  fi

  TMP_GWB_CONF="$(mktemp)"
  cat >"$TMP_GWB_CONF" <<EOF
[general]
log_level = 4
log_json = false
log_to_syslog = false

[backend]
type = "semtech_udp"

[backend.semtech_udp]
udp_bind = "${UDP_HOST}:${UDP_PORT}"
fake_rx_time = false

[integration]
marshaler = "protobuf"

[integration.mqtt]
event_topic_template = "${REGION_TOPIC}/gateway/{{ .GatewayID }}/event/{{ .EventType }}"
state_topic_template = "${REGION_TOPIC}/gateway/{{ .GatewayID }}/state/{{ .StateType }}"
command_topic_template = "${REGION_TOPIC}/gateway/{{ .GatewayID }}/command/#"
state_retained = true
keep_alive = "30s"
max_reconnect_interval = "1m0s"
terminate_on_connect_error = false

[integration.mqtt.auth]
type = "generic"

[integration.mqtt.auth.generic]
servers = ["tcp://127.0.0.1:1883"]
username = ""
password = ""
qos = 0
clean_session = true
client_id = "chirpstack-gwb"
EOF

  GWB_SERVICE_USER="$(systemctl show -p User --value chirpstack-gateway-bridge 2>/dev/null || true)"
  [[ -n "$GWB_SERVICE_USER" ]] || GWB_SERVICE_USER="root"
  if id "$GWB_SERVICE_USER" >/dev/null 2>&1; then
    GWB_GROUP="$(id -gn "$GWB_SERVICE_USER")"
  else
    GWB_GROUP="root"
  fi
  root install -o root -g "$GWB_GROUP" -m 0640 "$TMP_GWB_CONF" "$GWB_CONF"
  rm -f "$TMP_GWB_CONF"

  # Compatibilidad con Yubox gwOS: la imagen del gateway trae su propia unit
  # chirpstack-gateway-bridge (User=chirpstack) que tapa a la del paquete apt
  # (User=gatewaybridge). El postinst del paquete deja el directorio de
  # configuración 0750 gatewaybridge:gatewaybridge, y el usuario de la unit
  # efectiva no puede ni atravesarlo: el servicio muere en bucle con
  # "permission denied". Permiso de tránsito al directorio; el .toml en sí
  # conserva su 0640.
  root chmod 0755 "$(dirname "$GWB_CONF")"

  if ! root chirpstack-gateway-bridge configfile --config "$GWB_CONF" >/dev/null; then
    [[ -n "$GWB_BACKUP" ]] && root cp -a "$GWB_BACKUP" "$GWB_CONF"
    die "La configuración de Gateway Bridge no pasó la validación; se restauró el respaldo."
  fi
fi

# ---------- Inicio y verificación ----------

info "Iniciando servicios..."
root systemctl restart postgresql redis-server mosquitto
root systemctl enable chirpstack
root systemctl restart chirpstack

if ! root systemctl is-active --quiet chirpstack; then
  root journalctl -u chirpstack -n 50 --no-pager || true
  die "ChirpStack no pudo iniciar."
fi

if [[ "$INSTALL_GWB" == "yes" ]]; then
  root systemctl enable chirpstack-gateway-bridge
  root systemctl restart chirpstack-gateway-bridge

  if ! root systemctl is-active --quiet chirpstack-gateway-bridge; then
    root journalctl -u chirpstack-gateway-bridge -n 50 --no-pager || true
    die "ChirpStack Gateway Bridge no pudo iniciar."
  fi
fi

HTTP_OK="no"
for _ in $(seq 1 45); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${WEB_PORT}/" >/dev/null 2>&1; then
    HTTP_OK="yes"
    break
  fi
  sleep 1
done

if [[ "$HTTP_OK" != "yes" ]]; then
  root journalctl -u chirpstack -n 50 --no-pager || true
  die "ChirpStack está activo, pero la interfaz web no respondió en el puerto ${WEB_PORT}."
fi

ADMIN_PASSWORD_SET="no"
if [[ "$SET_ADMIN_PASSWORD" == "yes" ]]; then
  ADMIN_PASSWORD_FILE="$(mktemp)"
  chmod 0600 "$ADMIN_PASSWORD_FILE"
  printf '%s' "$ADMIN_PASSWORD" >"$ADMIN_PASSWORD_FILE"

  if root chirpstack \
    --config /etc/chirpstack \
    set-password \
    --email admin \
    --password-file "$ADMIN_PASSWORD_FILE"; then
    ADMIN_PASSWORD_SET="yes"
  else
    warn "No se pudo cambiar la contraseña web de admin. Podrás hacerlo luego desde ChirpStack."
  fi

  rm -f "$ADMIN_PASSWORD_FILE"
fi

PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$PRIMARY_IP" ]] || PRIMARY_IP="IP_DE_ESTA_MAQUINA"
CS_VERSION="$(dpkg-query -W -f='${Version}' chirpstack 2>/dev/null || printf 'instalado')"

printf '\n%sInstalación completada%s\n' "$BOLD" "$RESET"
printf '  ChirpStack: %s\n' "$CS_VERSION"
printf '  Región:    %s — %s\n' "$REGION_ID" "$REGION_DESCRIPTION"
printf '  NetID:     %s\n' "$NET_ID"
printf '  MQTT:      tcp://127.0.0.1:1883\n'

if [[ "$API_HOST" == "0.0.0.0" ]]; then
  printf '  Interfaz:  http://%s:%s\n' "$PRIMARY_IP" "$WEB_PORT"
else
  printf '  Interfaz:  http://127.0.0.1:%s\n' "$WEB_PORT"
fi

printf '  Usuario web: admin\n'
if [[ "$ADMIN_PASSWORD_SET" == "yes" ]]; then
  printf '  Clave web:   la definida durante la instalación\n'
else
  printf '  En una instalación nueva, la clave inicial es: admin\n'
fi

if [[ "$INSTALL_GWB" == "yes" ]]; then
  printf '\n%sPacket Forwarder Semtech UDP%s\n' "$BOLD" "$RESET"
  if [[ "$PF_LOCAL" == "yes" ]]; then
    printf '  server_address: 127.0.0.1\n'
  else
    printf '  server_address: %s\n' "$PRIMARY_IP"
  fi
  printf '  serv_port_up:   %s\n' "$UDP_PORT"
  printf '  serv_port_down: %s\n' "$UDP_PORT"
  printf '  Topic MQTT:     %s/gateway/...\n' "$REGION_TOPIC"
fi

printf '\n%sImportante:%s el Packet Forwarder también debe usar las frecuencias/canales de la región seleccionada.\n' "$YELLOW" "$RESET"
printf 'Este script no modifica global_conf.json ni local_conf.json.\n'
printf '\nComandos útiles:\n'
printf '  sudo journalctl -fu chirpstack\n'
if [[ "$INSTALL_GWB" == "yes" ]]; then
  printf '  sudo journalctl -fu chirpstack-gateway-bridge\n'
  printf "  mosquitto_sub -h 127.0.0.1 -v -t '%s/gateway/#'\n" "$REGION_TOPIC"
fi
