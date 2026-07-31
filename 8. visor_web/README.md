# Visor web de temperatura y humedad

Página web que se sirve **desde el propio gateway** (el RPi del curso) y
muestra en vivo las lecturas de los nodos: gráfica de temperatura y humedad,
y una tabla con la última lectura, RSSI, SNR y contador de cada dispositivo.

Los alumnos no instalan nada: abren `http://IP_DEL_GATEWAY:8081` en el
navegador de su laptop, tablet o teléfono, conectados a la red del aula.

## Cómo funciona

```
nodo LoRaWAN ──radio──> gateway ──> ChirpStack ──> Mosquitto ──WebSockets──> navegador
                                    (payload codec)              (mqtt.js + Chart.js)
```

La página es un cliente MQTT sobre WebSockets (el navegador no puede abrir
TCP crudo al puerto 1883, de ahí el listener adicional). Se suscribe a
`application/+/device/+/event/up`, donde ChirpStack publica cada uplink ya
decodificado por el payload codec del curso, y grafica los campos
`temperatura` y `humedad` del objeto decodificado (acepta también
`temp`/`hum` como alternativa).

No hay backend: es una página estática servida por un servicio systemd
(`visor-lorawan`). Las librerías mqtt.js y Chart.js se instalan localmente
en el gateway, así que el aula no necesita salida a Internet para usar el
visor (solo se necesita Internet durante la instalación).

## Requisitos

- El mismo RPi con Yubox Gateway OS y ChirpStack v4 instalado según el
  capítulo 7 (broker Mosquitto local en `127.0.0.1:1883`).
- El payload codec del curso cargado en el device profile
  (ver `6. ejemplos_firmware/YBXIND_hdc2080/codec_chirpstack.js`).

## Instalación

En el gateway:

```bash
curl -fsSL "https://raw.githubusercontent.com/elandivar/Curso_LoRaWAN_Master_Training/main/8.%20visor_web/instalar-visor.sh" | bash
```

O desde el repo clonado:

```bash
bash "8. visor_web/instalar-visor.sh"
```

El instalador pregunta el puerto HTTP del visor (por defecto **8081**) y el
puerto WebSockets de Mosquitto (por defecto **9001**), respalda cualquier
configuración que toque y verifica al final que todo quedó funcionando
(broker clásico incluido: si algo falla, restaura y aborta).

Las librerías de terceros se descargan con versión y SHA-256 fijos: si el
CDN entregara un archivo distinto al esperado, la instalación se detiene
sin instalar nada.

## Desinstalación

```bash
sudo systemctl disable --now visor-lorawan
sudo rm /etc/systemd/system/visor-lorawan.service
sudo systemctl daemon-reload
sudo rm -rf /opt/visor-lorawan
sudo rm /etc/mosquitto/conf.d/visor-websockets.conf
sudo systemctl restart mosquitto
```

## Nota de seguridad

El listener WebSockets acepta conexiones **sin credenciales** desde la red
local: cualquier persona en la red del aula puede leer (y publicar) en el
broker. Es un compromiso deliberado para simplificar la clase; en un
despliegue real se usarían credenciales y TLS, como se discute en el
capítulo de seguridad del curso.
