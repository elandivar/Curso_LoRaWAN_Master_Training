# Nodo de prueba: Arduino MKR WAN 1310 → TTN (AU915)

Envía cada minuto un payload de 5 bytes con un contador, la lectura del pin A0
y los minutos que lleva encendida la placa.

No necesitas conectar nada a A0 para probar: sin nada, la entrada flota y da
lecturas que van cambiando, lo cual basta para comprobar que el enlace
funciona. Cuando quieras medir algo de verdad, ahí es donde va el sensor.

## Las credenciales van en `arduino_secrets.h`

El sketch incluye un archivo `arduino_secrets.h` que no viene en el
repositorio (está en el `.gitignore`, precisamente para que nadie publique sus
claves por accidente). Créalo copiando la plantilla:

```
cp arduino_secrets.h.example arduino_secrets.h
```

La copia recién hecha trae las claves en cero, y así debe quedarse hasta el
paso 4 de la sección siguiente.

## Antes de nada: el orden importa

El DevEUI de la MKR WAN 1310 **viene grabado de fábrica** en el módulo Murata;
no se inventa ni se genera en TTN. Así que el orden correcto es:

1. Cargar el sketch **con las credenciales aún en ceros**.
2. Abrir el Monitor Serie a **115200 baudios** y anotar el `DevEUI` que imprime.
3. Registrar el dispositivo en TTN **con ese DevEUI**.
4. Copiar el AppEUI y la AppKey que da TTN a `arduino_secrets.h`.
5. Volver a cargar el sketch.

El join fallará en el primer arranque. Es lo esperado.

## Preparar el IDE

- **Placa:** Gestor de tarjetas → *Arduino SAMD Boards (32-bits ARM Cortex-M0+)*
- **Librería:** Gestor de librerías → **MKRWAN**
- **Firmware del módulo:** conviene actualizarlo antes de empezar, con
  *Archivo → Ejemplos → MKRWAN → MKRWANFWUpdate_standalone*. Muchos problemas
  de join en placas recién compradas se resuelven solo con esto.

## Al registrar el dispositivo en TTN

| Campo | Valor |
|:--|:--|
| Frequency plan | **Australia 915-928 MHz, FSB 2** |
| LoRaWAN version | **1.0.3** |
| Regional Parameters | **RP001 1.0.3 revision A** |
| Activación | OTAA |
| DevEUI | el que imprime la placa |
| JoinEUI (AppEUI) | ceros está bien |
| AppKey | *Generate* |

**El plan de frecuencias del nodo debe coincidir con el del gateway.** Tu
gateway de pruebas está registrado como *Australia 915-928 MHz, FSB 2*; si al
nodo le pones US915 —que es lo que ofrece por defecto el clúster `nam1`— no se
van a encontrar nunca, aunque estén en la misma mesa.

Si con la versión 1.0.3 los join requests llegan a TTN pero el join nunca se
completa (o ves errores tipo *Data rate not found*), cambia el dispositivo a
**LoRaWAN 1.0.2 con Regional Parameters PHY V1.0.2 REV B**: es la
combinación que la comunidad ha verificado con el firmware ARD-078 1.2.3 en
AU915, y el desajuste de *revision* es un problema conocido entre el módulo
Murata y el valor que TTN propone por defecto.

## La sub-banda: el fallo más común en 915 MHz

Un gateway de 8 canales escucha **una sola sub-banda**. Si el nodo transmite
repartiendo sus mensajes por las ocho, siete de cada ocho caen en canales que
nadie escucha: el join tarda muchísimo o no llega nunca, y parece un problema
de cobertura cuando no lo es.

Por eso el sketch fija la máscara de canales con una sola llamada a
`sendMask("ff000000f000ffff00020000")`: sub-banda 2 completa (canales 8-15),
su canal de 500 kHz (el 65), y los canales 44-63 de relleno.

¿Relleno? Sí, y la razón merece contarse. El firmware del módulo Murata
exige que cualquier máscara tenga **al menos 20 canales de 125 kHz activos**
—el código del stack lo atribuye a la regulación australiana (ACMA)—, así que
la máscara "perfecta" con solo los 8 canales de la sub-banda 2 es rechazada
con error. La de arriba, que es la que usa la comunidad de TTN para esta
placa, supera el mínimo con canales que el gateway no escucha: los joins que
salgan por ahí se pierden, el módulo reintenta, y en pocos intentos cae en la
sub-banda 2. En cuanto el join entra, el servidor poda el plan de canales por
ADR (`LinkADRReq`) y el tráfico queda solo en los canales correctos.

Ese mínimo de 20 canales explica también por qué **no** sirve el camino
aparentemente más didáctico —recorrer los 72 canales con `disableChannel()` y
activar los buenos con `enableChannel()`—: cada llamada reescribe la máscara
por comandos AT, y en cuanto el conteo baja de 20 el módulo empieza a
rechazar las escrituras mientras la librería sigue con su copia local. El
resultado es una máscara imprevisible. Lo comprobamos en carne propia
preparando este capítulo.

## Política de uso justo de TTN

TTN limita a **30 segundos de tiempo en el aire por dispositivo y día**, y a 10
downlinks. No es un límite técnico sino un acuerdo de convivencia: el espectro
es compartido.

Con 5 bytes a SF9, cada mensaje ocupa unos 120 ms. Eso da unos 240 mensajes al
día, es decir, **uno cada seis minutos** como mínimo.

El sketch viene con **60 segundos** para que veas llegar datos enseguida
mientras pruebas. En cuanto funcione, súbelo a `600UL * 1000UL` (10 minutos).

## El payload

Cinco bytes, empaquetados como explica el capítulo 7.5 del libro:

| Byte | Campo | Codificación |
|:--:|:--|:--|
| 0-1 | Contador | `uint16` big-endian |
| 2-3 | Lectura de A0 | `uint16`, 0..1023 |
| 4 | Minutos encendido | `uint8`, satura en 255 |

El uptime satura en 255 en lugar de dar la vuelta a cero. Un contador que
vuelve a cero de golpe es indistinguible de un reinicio de la placa, y eso
lleva a diagnosticar problemas que no existen.

Para verlo decodificado en la consola, pega `decoder_ttn.js` en
*Payload formatters → Uplink → Custom JavaScript formatter*.

## Medir la batería (opcional, requiere un divisor)

Aquí hay una diferencia con otras placas MKR que conviene conocer: **en la
MKR WAN 1310 no se puede usar `ADC_BATTERY`**. Ese pin está asignado a
`FLASH_CS`, y PB09 —que en otras placas sirve para esto— lo necesita el chip
LoRa. Si intentas compilar con `ADC_BATTERY` obtendrás
*'ADC_BATTERY' was not declared in this scope*.

Para medirla hay que montar un divisor de tensión externo entre VBAT y masa,
con el punto medio en una entrada analógica libre (A1, por ejemplo). Con dos
resistencias iguales de 1 MΩ la tensión se divide por dos, el consumo del
divisor es despreciable y una batería LiPo de 4,2 V queda en 2,1 V, dentro del
rango del ADC.

Después, en el sketch:

```cpp
const uint8_t PIN_BATERIA = A1;
const float   FACTOR_DIVISOR = 2.0f;   // ajústalo con un multímetro

float leerBateria() {
  return analogRead(PIN_BATERIA) * (3.3f / 1023.0f) * FACTOR_DIVISOR;
}
```

y añade un sexto byte al payload con el mismo criterio de la sección 7.5
—offset de 2,00 V y ×100, que da 10 mV de resolución en 8 bits:

```cpp
uint8_t payload[6];
// … los cinco primeros bytes igual que antes …
float v = leerBateria();
if (v < 2.00f) v = 2.00f;
if (v > 4.55f) v = 4.55f;
payload[5] = (uint8_t)lround((v - 2.00f) * 100.0f);
```

El decoder ya contempla ese sexto byte: si llega, lo decodifica; si no, lo
ignora. **Calibra `FACTOR_DIVISOR` con un multímetro la primera vez**, o
acabarás con alarmas de batería baja que no son ciertas.

## Qué esperar

En el Monitor Serie:

```
=== Nodo LoRaWAN MKR WAN 1310 -> TTN (AU915) ===
Firmware del modulo : ARD-078 1.2.3
DevEUI de esta placa: A8610A34xxxxxxxx
   ^-- copia este valor al registrar el nodo en TTN
Mascara por defecto : ffffffffffffffff00ff0000
Mascara aplicada    : ff000000f000ffff00020000
Uniendose a la red (OTAA)...
Unido a la red.
[0] A0=512 (1.65 V)  uptime=0 min  ->  0000020000 (5 bytes)
   enviado.
```

Y en TTN, en *Live data* de la aplicación: primero el `join-accept`, después un
`uplink message` por cada envío con el payload decodificado.

## Si el join falla: qué mirar en Live data

El *Live data* de la aplicación (y el del gateway) dice exactamente en qué
eslabón se rompió la cadena. Los tres casos típicos:

| Lo que aparece | Qué significa | Qué hacer |
|:--|:--|:--|
| **Nada** — ni un evento | Los join requests no llegan: sub-banda equivocada, gateway fuera de línea o fuera de cobertura | Revisa la máscara en el Monitor Serie y el estado del gateway |
| `Receive join-request` + error **`mic_mismatch`** | El mensaje llega y el dispositivo está registrado, pero **la AppKey del nodo no es la de TTN** | Abre el dispositivo en TTN, revela la AppKey (icono del ojo) y cópiala tal cual a `arduino_secrets.h`; vuelve a flashear |
| Error **`device not found`** | DevEUI o JoinEUI no coinciden con lo registrado | Compara el DevEUI del Monitor Serie y el JoinEUI de `arduino_secrets.h` con los del registro |

Un `mic_mismatch` con la clave "bien copiada" casi siempre es una de estas
tres: se regeneró la AppKey en TTN después de copiarla, se copió la de *otro*
dispositivo, o el dispositivo quedó registrado como LoRaWAN 1.1 (esta placa
es 1.0.x; verifica *LoRaWAN version* en los ajustes generales del
dispositivo).
