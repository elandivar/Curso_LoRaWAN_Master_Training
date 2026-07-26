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
| [6. ejemplos/MKRWAN1310_TTN_AU915](6.%20ejemplos/MKRWAN1310_TTN_AU915/) | Nodo básico → TTN | Arduino MKR WAN 1310 enviando telemetría periódica a The Things Network por OTAA en AU915 (sub-banda 2), con su decoder de payload para la consola de TTN |

El repositorio irá creciendo con más ejemplos a medida que avance el curso.

## Requisitos generales

- **Arduino IDE** (1.8 o 2.x) con el core *Arduino SAMD Boards* y las
  librerías que indique cada ejemplo en su README.
- Una cuenta gratuita en [The Things Network](https://www.thethingsnetwork.org/).
- Un gateway LoRaWAN dentro de cobertura, registrado en TTN con el mismo plan
  de frecuencias que el nodo (en el curso: *Australia 915-928 MHz, FSB 2*).

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

## Estructura de cada ejemplo

Cada carpeta de ejemplo es autocontenida e incluye:

- El **sketch** (`.ino`) comentado línea a línea donde hace falta.
- Un **README** propio con el paso a paso: registro en TTN, configuración del
  IDE, qué esperar en el Monitor Serie y una guía de diagnóstico de los
  fallos más comunes.
- El **payload formatter** (`decoder_ttn.js`) para pegar en la consola de TTN
  cuando el ejemplo envía datos binarios empaquetados.

## Autor y licencia

**Edgar Landívar** — «LoRaWAN para todos», 2ª edición.

El código de este repositorio se publica bajo licencia [MIT](LICENSE).
