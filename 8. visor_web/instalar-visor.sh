#!/usr/bin/env bash
# Instalador del visor web de temperatura y humedad (curso LoRaWAN).
#
# Pensado para el mismo RPi que ya corre el gateway con ChirpStack v4
# instalado según el capítulo 7 (broker Mosquitto local en 127.0.0.1:1883).
#
# Instala y configura:
#   - Un listener WebSockets en Mosquitto (para que el navegador pueda
#     suscribirse al broker; el listener clásico 1883 queda local como está).
#   - La página del visor + librerías (mqtt.js y Chart.js). Todo viene
#     incluido en el repo del curso: si el script corre desde el repo
#     clonado usa las copias locales; si corre suelto (curl | bash) las
#     descarga del propio repo, con SHA-256 fijo para las librerías.
#   - Un servicio systemd (visor-lorawan) que sirve la página por HTTP.
#
# Los alumnos solo abren http://IP_DEL_GATEWAY:PUERTO en su navegador.

set -Eeuo pipefail
IFS=$'\n\t'

VISOR_DIR="/opt/visor-lorawan"
UNIT_FILE="/etc/systemd/system/visor-lorawan.service"
MOSQ_CONF_DIR="/etc/mosquitto/conf.d"
MOSQ_VISOR_CONF="${MOSQ_CONF_DIR}/visor-websockets.conf"

RAW_BASE="https://raw.githubusercontent.com/elandivar/Curso_LoRaWAN_Master_Training/main/8.%20visor_web"

# Librerías de terceros incluidas en el repo del curso (mqtt.js 5.10.1 y
# Chart.js 4.4.7), con hash fijo para verificar la copia descargada cuando
# el script no corre desde el repo clonado (fail-closed).
MQTT_JS_SHA256="b088a7f9045df4e478dbc378f41125066e43d9c602755ee4c5cda0f3e9380ba0"
CHART_JS_SHA256="206b6e8bb00fc7bba2c7ee80ca41db3e9e05ba7be0aa35abeba9cfd5357f5d0e"

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
  for file in "${TMP_DL:-}" "${TMP_UNIT:-}" "${TMP_MOSQ:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
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

# ---------- Validación del sistema ----------

command -v mosquitto >/dev/null 2>&1 \
  || die "No encuentro Mosquitto. Instala primero ChirpStack con el instalador del capítulo 7."
systemctl is-active --quiet mosquitto \
  || die "Mosquitto no está activo. Revisa la instalación de ChirpStack (capítulo 7)."
mosquitto_pub -h 127.0.0.1 -p 1883 -t visor/installer/test -m ok >/dev/null 2>&1 \
  || die "El broker local no acepta conexiones en 127.0.0.1:1883, como espera esta instalación."

command -v python3 >/dev/null 2>&1 || die "Se requiere python3."
python3 -c 'import http.server' 2>/dev/null \
  || die "El python3 de este sistema no trae http.server; instala el paquete python3 completo."

puerto_en_uso() {
  local port="$1"
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"
}

printf '\n%sInstalador del visor web de temperatura y humedad%s\n\n' "$BOLD" "$RESET"
printf '%s\n' \
  "Se agregará un listener WebSockets a Mosquitto y un servicio systemd" \
  "(visor-lorawan) que sirve la página del visor a los alumnos por HTTP." \
  "Los archivos de configuración existentes se respaldan antes de tocarlos."
printf '\n'

ask_yes_no "¿Continuar?" yes || exit 0

# ---------- Preferencias ----------

while true; do
  HTTP_PORT="$(ask_value "Puerto HTTP para la página del visor" "8081")"
  [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || { warn "Puerto inválido."; continue; }
  if puerto_en_uso "$HTTP_PORT" && ! systemctl is-active --quiet visor-lorawan; then
    warn "El puerto ${HTTP_PORT} ya está en uso por otro servicio."
    continue
  fi
  break
done

while true; do
  WS_PORT="$(ask_value "Puerto WebSockets de Mosquitto" "9001")"
  [[ "$WS_PORT" =~ ^[0-9]+$ ]] && (( WS_PORT >= 1 && WS_PORT <= 65535 )) || { warn "Puerto inválido."; continue; }
  [[ "$WS_PORT" != "$HTTP_PORT" ]] || { warn "Debe ser distinto del puerto HTTP."; continue; }
  if puerto_en_uso "$WS_PORT" && ! grep -qs "listener ${WS_PORT}" "$MOSQ_VISOR_CONF"; then
    warn "El puerto ${WS_PORT} ya está en uso por otro servicio."
    continue
  fi
  break
done

# ---------- Archivos del visor ----------

info "Instalando la página del visor en ${VISOR_DIR}..."
root install -d -m 0755 "$VISOR_DIR"

# Cada archivo se toma de la copia local si el script corre desde el repo
# clonado; si no, se descarga del propio repo del curso. Las librerías de
# terceros se verifican por SHA-256 cuando vienen descargadas.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

instalar_archivo() {
  local fname="$1"
  local expected_sha="${2:-}"
  local actual_sha

  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${fname}" ]]; then
    root install -m 0644 "${SCRIPT_DIR}/${fname}" "${VISOR_DIR}/${fname}"
    return 0
  fi

  TMP_DL="$(mktemp)"
  curl -fsSL "${RAW_BASE}/${fname}" -o "$TMP_DL" \
    || { rm -f "$TMP_DL"; die "No se pudo descargar ${fname} del repo del curso (¿hay Internet?)."; }
  if [[ -n "$expected_sha" ]]; then
    actual_sha="$(sha256sum "$TMP_DL" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
      || { rm -f "$TMP_DL"; die "La verificación SHA-256 de ${fname} falló; no se instaló nada."; }
  fi
  root install -m 0644 "$TMP_DL" "${VISOR_DIR}/${fname}"
  rm -f "$TMP_DL"
}

instalar_archivo "index.html"
grep -q "Visor LoRaWAN" "${VISOR_DIR}/index.html" \
  || die "El index.html instalado no parece válido."

info "Instalando librerías (mqtt.js y Chart.js)..."
instalar_archivo "mqtt.min.js" "$MQTT_JS_SHA256"
instalar_archivo "chart.umd.min.js" "$CHART_JS_SHA256"

# config.js: comunica a la página el puerto WebSockets elegido.
printf 'window.VISOR_WS_PORT = %s;\n' "$WS_PORT" \
  | root tee "${VISOR_DIR}/config.js" >/dev/null
root chmod 0644 "${VISOR_DIR}/config.js"

# ---------- Mosquitto: listener WebSockets ----------

info "Configurando el listener WebSockets de Mosquitto..."
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
MOSQ_BACKUP=""
MOSQ_EXISTED="no"
if root test -f "$MOSQ_VISOR_CONF"; then
  MOSQ_EXISTED="yes"
  MOSQ_BACKUP="${MOSQ_VISOR_CONF}.bak-${TIMESTAMP}"
  root cp -a "$MOSQ_VISOR_CONF" "$MOSQ_BACKUP"
fi

# En Mosquitto 2.x, declarar cualquier listener desactiva el listener
# implícito (localhost:1883) del que depende ChirpStack, así que hay que
# declarar ambos aquí... salvo que otra configuración ya declare el 1883.
# Se excluye el archivo del propio visor para que re-ejecutar el instalador
# no cuente el 1883 que este mismo script escribió la vez anterior.
OTRO_LISTENER="no"
for f in /etc/mosquitto/mosquitto.conf "${MOSQ_CONF_DIR}"/*.conf; do
  [[ -f "$f" ]] || continue
  [[ "$f" == "$MOSQ_VISOR_CONF" ]] && continue
  if grep -qsE '^[[:space:]]*listener[[:space:]]+1883([[:space:]]|$)' "$f"; then
    OTRO_LISTENER="yes"
    break
  fi
done

TMP_MOSQ="$(mktemp)"
{
  printf '# Generado por instalar-visor.sh (curso LoRaWAN) el %s\n' "$TIMESTAMP"
  printf '# Listener WebSockets para el visor web de temperatura y humedad.\n\n'
  if [[ "$OTRO_LISTENER" == "no" ]]; then
    printf '# Listener clásico local: lo usan ChirpStack y el mqtt-forwarder.\n'
    printf '# Hay que declararlo porque al definir un listener explícito,\n'
    printf '# Mosquitto 2.x deja de crear el listener implícito de localhost.\n'
    printf 'listener 1883 127.0.0.1\n\n'
  fi
  printf '# Listener WebSockets: lo usa el navegador de los alumnos.\n'
  printf 'listener %s\n' "$WS_PORT"
  printf 'protocol websockets\n\n'
  printf '# Sin credenciales: aceptable en la red del aula del curso.\n'
  printf 'allow_anonymous true\n'
} >"$TMP_MOSQ"
root install -m 0644 "$TMP_MOSQ" "$MOSQ_VISOR_CONF"
rm -f "$TMP_MOSQ"

restaurar_mosquitto() {
  if [[ "$MOSQ_EXISTED" == "yes" && -n "$MOSQ_BACKUP" ]]; then
    root cp -a "$MOSQ_BACKUP" "$MOSQ_VISOR_CONF"
  else
    root rm -f "$MOSQ_VISOR_CONF"
  fi
  root systemctl restart mosquitto || true
}

root systemctl restart mosquitto
sleep 1

if ! systemctl is-active --quiet mosquitto; then
  restaurar_mosquitto
  root journalctl -u mosquitto -n 30 --no-pager || true
  die "Mosquitto no arrancó con el listener WebSockets; se restauró la configuración anterior."
fi

# El broker clásico debe seguir aceptando a ChirpStack tras el cambio.
if ! mosquitto_pub -h 127.0.0.1 -p 1883 -t visor/installer/test -m ok >/dev/null 2>&1; then
  restaurar_mosquitto
  die "Tras el cambio, el broker dejó de aceptar conexiones locales en 1883; se restauró la configuración anterior."
fi

puerto_en_uso "$WS_PORT" \
  || { restaurar_mosquitto; die "Mosquitto no quedó escuchando WebSockets en el puerto ${WS_PORT}; se restauró la configuración anterior."; }

# ---------- Servicio systemd del visor ----------

info "Creando el servicio systemd visor-lorawan..."
TMP_UNIT="$(mktemp)"
cat >"$TMP_UNIT" <<EOF
[Unit]
Description=Visor web de temperatura y humedad (curso LoRaWAN)
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server ${HTTP_PORT} --directory ${VISOR_DIR} --bind 0.0.0.0
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
root install -o root -g root -m 0644 "$TMP_UNIT" "$UNIT_FILE"
rm -f "$TMP_UNIT"

root systemctl daemon-reload
root systemctl enable visor-lorawan
root systemctl restart visor-lorawan

HTTP_OK="no"
for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${HTTP_PORT}/" >/dev/null 2>&1; then
    HTTP_OK="yes"
    break
  fi
  sleep 1
done
if [[ "$HTTP_OK" != "yes" ]]; then
  root journalctl -u visor-lorawan -n 30 --no-pager || true
  die "El servicio visor-lorawan no respondió en el puerto ${HTTP_PORT}."
fi

# ---------- Resumen ----------

PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$PRIMARY_IP" ]] || PRIMARY_IP="IP_DE_ESTA_MAQUINA"

printf '\n%sInstalación completada%s\n' "$BOLD" "$RESET"
printf '  Visor web:  http://%s:%s\n' "$PRIMARY_IP" "$HTTP_PORT"
printf '  WebSockets: ws://%s:%s (Mosquitto)\n' "$PRIMARY_IP" "$WS_PORT"
printf '  Archivos:   %s\n' "$VISOR_DIR"
printf '\n'
printf '%s\n' \
  "Los alumnos solo necesitan abrir la dirección del visor en su navegador," \
  "conectados a la misma red que este gateway. La página se suscribe a" \
  "application/+/device/+/event/up y grafica lo que decodifica el payload" \
  "codec de ChirpStack (campos temperatura/humedad)."
printf '\n%sNota de seguridad:%s el listener WebSockets acepta conexiones sin\n' "$YELLOW" "$RESET"
printf 'credenciales desde la red local: adecuado para el aula del curso, no\n'
printf 'para producción (ver capítulo de seguridad).\n'
printf '\nComandos útiles:\n'
printf '  sudo systemctl status visor-lorawan\n'
printf '  sudo journalctl -fu visor-lorawan\n'
printf "  mosquitto_sub -h 127.0.0.1 -v -t 'application/#'\n"
