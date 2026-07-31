# LoRaWAN Master Training

Material práctico del curso de LoRaWAN y del libro **«LoRaWAN para todos»,
2ª edición**, de Edgar Landívar.

Este repositorio reúne los ejemplos, sketches y payload formatters que
acompañan a los capítulos del libro y a las sesiones del training. La idea es
que cada ejemplo se pueda cargar, probar y romper sin miedo: todos están
comentados en español y explican no solo el *cómo* sino el *porqué* de cada
decisión (máscaras de canales, empaquetado de payloads, política de uso justo
de TTN, etc.).

## Contenido

| Carpeta | Ejemplo | Descripción |
|:--|:--|:--|
| [6. ejemplos_firmware/MKRWAN1310_TTN_AU915](6.%20ejemplos_firmware/MKRWAN1310_TTN_AU915/) | Nodo básico → TTN | Arduino MKR WAN 1310 enviando telemetría periódica a The Things Network por OTAA en AU915 (sub-banda 2), con su decoder de payload para la consola de TTN |
| [6. ejemplos_firmware/YBXIND_helloworld](6.%20ejemplos_firmware/YBXIND_helloworld/) | Yubox Industrial: hola mundo | Primer firmware para la tarjeta Yubox Industrial (ESP32): envía texto plano por LoRaWAN, configurable desde su propia interfaz web; incluye payload codec para ChirpStack |
| [6. ejemplos_firmware/YBXIND_hdc2080](6.%20ejemplos_firmware/YBXIND_hdc2080/) | Yubox Industrial + sensor | Lee temperatura y humedad del sensor HDC2080 (I2C) y las envía como JSON por LoRaWAN; incluye payload codec para ChirpStack que expone los valores decodificados |
| [7. instalador_chirpstack](7.%20instalador_chirpstack/) | Network Server propio | Instalador interactivo de ChirpStack v4 para el gateway del curso (RPi con Yubox Gateway OS): PostgreSQL, Redis, Mosquitto y ChirpStack, con conexión de la radio al broker local |
| [8. visor_web](8.%20visor_web/) | Visor para el aula | Página web servida desde el propio gateway que grafica en vivo la temperatura y humedad de todos los nodos, vía MQTT sobre WebSockets; los alumnos solo abren un navegador |

El repositorio irá creciendo con más ejemplos a medida que avance el curso.

## Requisitos generales

- **Arduino IDE** (1.8 o 2.x) con el core que indique cada ejemplo (*Arduino
  SAMD Boards* para el MKR WAN 1310; los ejemplos Yubox usan el framework
  Yubox sobre ESP32) y las librerías de su README.
- Un gateway LoRaWAN dentro de cobertura con el mismo plan de frecuencias que
  el nodo (en el curso: *Australia 915-928 MHz, FSB 2*).
- Un Network Server: los ejemplos usan una cuenta gratuita de
  [The Things Network](https://www.thethingsnetwork.org/) o un
  **ChirpStack v4 propio** corriendo en el mismo gateway del curso
  (ver `7. instalador_chirpstack`).

## Credenciales: cómo se manejan en este repo

Los sketches leen sus claves de un archivo `arduino_secrets.h` que **no se
sube al repositorio** (está en el `.gitignore`). Cada ejemplo incluye en su
lugar una plantilla `arduino_secrets.h.example` con las claves en cero:

```
cp arduino_secrets.h.example arduino_secrets.h
```

Edita la copia con el AppEUI/JoinEUI y la AppKey que te dé TTN al registrar tu
dispositivo. Nunca publiques una AppKey real: quien la tenga puede unirse a la
red haciéndose pasar por tu nodo.

Los ejemplos de la Yubox Industrial no usan este mecanismo: sus credenciales
LoRaWAN se configuran en tiempo de ejecución desde la interfaz web de la
propia tarjeta (framework Yubox), así que no hay claves en el código.

## Estructura de cada ejemplo

Cada carpeta de ejemplo es autocontenida e incluye:

- El **sketch** (`.ino`) comentado línea a línea donde hace falta.
- Un **README** propio con el paso a paso: registro en TTN, configuración del
  IDE, qué esperar en el Monitor Serie y una guía de diagnóstico de los
  fallos más comunes.
- El **payload codec** para el Network Server correspondiente:
  `decoder_ttn.js` para pegar en la consola de TTN, o `codec_chirpstack.js`
  para pegar en el device profile de ChirpStack. Ambos deshacen el
  empaquetado que hace el firmware y documentan sus diferencias (por
  ejemplo, ChirpStack reporta errores con `throw` en lugar de los arreglos
  `errors`/`warnings` de TTN).

## Autor y licencia

**Edgar Landívar** — «LoRaWAN para todos», 2ª edición.

El código de este repositorio se publica bajo licencia [MIT](LICENSE).
