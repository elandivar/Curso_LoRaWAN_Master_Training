/*
 * ---------------------------------------------------------------------------
 *  Nodo LoRaWAN de prueba — Arduino MKR WAN 1310 → The Things Network (AU915)
 * ---------------------------------------------------------------------------
 *  Envía periódicamente un payload binario de 5 bytes:
 *
 *      byte 0-1 : contador de mensajes        uint16, big-endian
 *      byte 2-3 : lectura del pin A0          uint16, 0..1023
 *      byte 4   : minutos encendido           uint8, satura en 255
 *
 *  El empaquetado sigue el criterio del capítulo 7.5 del libro: se envía el
 *  mínimo número de bytes y se reconstruyen los valores en el servidor con un
 *  decoder (ver decoder_ttn.js).
 *
 *  NOTA SOBRE LA BATERÍA: a diferencia de otras placas MKR, la WAN 1310 NO
 *  permite medir la batería con la constante ADC_BATTERY —ese pin está
 *  ocupado como FLASH_CS, y PB09 lo usa el chip LoRa—. Para medirla hace
 *  falta un divisor de tensión externo; el README explica cómo añadirlo.
 *
 *  Placa    : Arduino MKR WAN 1310 (Murata CMWX1ZZABZ)
 *  Librería : MKRWAN (Gestor de librerías del IDE)
 *  Región   : AU915, sub-banda 2 — la que usan TTN y el gateway del libro
 *
 *  Edgar Landívar · «LoRaWAN para todos», 2ª edición
 * ---------------------------------------------------------------------------
 */

#include <MKRWAN.h>
#include "arduino_secrets.h"

LoRaModem modem;

// ---------------------------------------------------------------------------
//  Configuración
// ---------------------------------------------------------------------------

// Intervalo entre envíos.
//   60 s está bien para PROBAR y ver llegar mensajes enseguida.
//   Para dejarlo funcionando, súbelo a 600 s (10 min): ver nota de política
//   de uso justo más abajo.
const unsigned long INTERVALO_MS = 60UL * 1000UL;

// Puerto de aplicación (FPort). El 0 está reservado a comandos MAC.
// Usar puertos distintos para datos y diagnóstico facilita filtrar después.
const uint8_t PUERTO_DATOS = 10;

// Pin de entrada analógica de propósito general. Aquí puedes conectar lo que
// quieras medir de verdad: un LDR, un divisor con un NTC, un sensor con salida
// de 0 a 3,3 V… Sin nada conectado, la lectura flota y va cambiando sola, que
// para probar el enlace también sirve.
const uint8_t PIN_SENSOR = A0;

// ---------------------------------------------------------------------------

uint16_t contador = 0;
unsigned long ultimoEnvio = 0;

// ---------------------------------------------------------------------------
//  Arranque
// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  // Espera al monitor serie un máximo de 10 s: así la placa también arranca
  // sola cuando la alimentas con una batería, sin ordenador conectado.
  unsigned long t0 = millis();
  while (!Serial && (millis() - t0 < 10000)) { }

  Serial.println();
  Serial.println(F("=== Nodo LoRaWAN MKR WAN 1310 -> TTN (AU915) ==="));

  analogReadResolution(10);

  if (!modem.begin(AU915)) {
    Serial.println(F("ERROR: no se pudo iniciar el modulo LoRa."));
    Serial.println(F("Revisa que la placa seleccionada sea la MKR WAN 1310."));
    while (true) { }
  }
  delay(3000);

  Serial.print(F("Firmware del modulo : "));
  Serial.println(modem.version());

  // El DevEUI NO se inventa: viene grabado de fabrica en el modulo Murata.
  // Es el que hay que registrar en TTN.
  Serial.print(F("DevEUI de esta placa: "));
  Serial.println(modem.deviceEUI());
  Serial.println(F("   ^-- copia este valor al registrar el nodo en TTN"));

  configurarCanalesAU915();

  // ADR activado: el nodo esta fijo, asi que dejamos que el servidor optimice
  // velocidad y potencia. En un nodo movil habria que DESACTIVARLO (ver 4.15).
  modem.setADR(true);

  unirseATTN();

  ultimoEnvio = millis() - INTERVALO_MS;   // primer envio inmediato
}

// ---------------------------------------------------------------------------
//  Canales: AU915 sub-banda 2 (8..15) + canal 65
// ---------------------------------------------------------------------------
//  Un gateway de 8 canales solo escucha una sub-banda. Si el nodo transmite
//  en las ocho sub-bandas, siete de cada ocho mensajes se pierden y el join
//  tarda una eternidad o no llega nunca. Este es el fallo mas comun al
//  estrenar un nodo en 915 MHz.
//
//  La mascara se envia completa y UNA sola vez con sendMask(). Dos trampas
//  conocidas, comprobadas preparando este capitulo:
//
//  1) NO sirve recorrer los canales con disableChannel()/enableChannel():
//     son mas de 160 comandos AT y, peor, en cuanto quedan pocos canales el
//     modulo empieza a RECHAZAR las escrituras (ver punto 2) mientras la
//     libreria sigue con su copia local. El resultado es una mascara
//     imprevisible y un join que casi nunca entra.
//
//  2) El firmware del modulo (stack LoRaMac, RegionAU915.c) exige un minimo
//     de VEINTE canales de 125 kHz activos: "According to ACMA regulation,
//     we require at least 20 125KHz channels". Una mascara "perfecta" con
//     solo los 8 canales de la sub-banda 2 es rechazada con error.
//
//  Por eso se usa la mascara de abajo, la misma que emplea la comunidad de
//  TTN para esta placa: sub-banda 2 completa (canales 8-15), el canal 65 de
//  500 kHz, y los canales 44-63 de relleno para superar el minimo de 20.
//  ¿Y los joins que salgan por 44-63, que el gateway no escucha? Se pierden
//  y el modulo reintenta; en pocos intentos cae en la sub-banda 2. Tras el
//  join, el servidor corrige el plan de canales por ADR (LinkADRReq) y el
//  trafico queda solo en los canales correctos.
//
//  Formato: 6 grupos de 16 bits en hexadecimal; el bit N del grupo G es el
//  canal G*16+N.
//    ff00 = canales  8-15   (sub-banda 2, 125 kHz)
//    f000 = canales 44-47   (relleno)
//    ffff = canales 48-63   (relleno)
//    0002 = canal   65      (500 kHz de la sub-banda 2)
// ---------------------------------------------------------------------------
void configurarCanalesAU915() {
  Serial.print(F("Mascara por defecto : "));
  Serial.println(modem.getChannelMask());

  if (!modem.sendMask("ff000000f000ffff00020000")) {
    Serial.println(F("AVISO: el modulo no acepto la mascara de canales."));
  }

  // Se relee del modulo, no de una variable local: confirma lo aplicado.
  Serial.print(F("Mascara aplicada    : "));
  Serial.println(modem.getChannelMask());
}

// ---------------------------------------------------------------------------
//  Join OTAA
// ---------------------------------------------------------------------------
void unirseATTN() {
  Serial.println(F("Uniendose a la red (OTAA)..."));

  int intento = 0;
  while (!modem.joinOTAA(SECRET_APP_EUI, SECRET_APP_KEY)) {
    intento++;
    Serial.print(F("  join fallido (intento "));
    Serial.print(intento);
    Serial.println(F("). Comprueba:"));
    Serial.println(F("   - AppEUI/JoinEUI y AppKey identicos a los de TTN"));
    Serial.println(F("   - el gateway registrado y en linea"));
    Serial.println(F("   - que estas dentro de su cobertura"));

    // Espera creciente: reintentar sin pausa satura el canal y no ayuda.
    unsigned long espera = min(30000UL * intento, 300000UL);
    Serial.print(F("  reintentando en "));
    Serial.print(espera / 1000);
    Serial.println(F(" s..."));
    delay(espera);
  }

  Serial.println(F("Unido a la red."));
}

// ---------------------------------------------------------------------------
//  Envio
// ---------------------------------------------------------------------------
void enviarMuestra() {
  uint16_t lectura = analogRead(PIN_SENSOR);

  // Minutos encendido. Se satura en 255 en vez de dar la vuelta: un valor que
  // vuelve a 0 de golpe se confunde con un reinicio de la placa.
  unsigned long minutos = millis() / 60000UL;
  uint8_t uptime = (minutos > 255) ? 255 : (uint8_t)minutos;

  // --- empaquetado: 5 bytes ---
  uint8_t payload[5];

  payload[0] = contador >> 8;              // contador, byte alto
  payload[1] = contador & 0xFF;            // contador, byte bajo
  payload[2] = lectura >> 8;               // A0, byte alto
  payload[3] = lectura & 0xFF;             // A0, byte bajo
  payload[4] = uptime;                     // minutos encendido

  Serial.print(F("["));
  Serial.print(contador);
  Serial.print(F("] A0="));
  Serial.print(lectura);
  Serial.print(F(" ("));
  Serial.print(lectura * 3.3f / 1023.0f, 2);
  Serial.print(F(" V)  uptime="));
  Serial.print(uptime);
  Serial.print(F(" min  ->  "));
  for (uint8_t i = 0; i < sizeof(payload); i++) {
    if (payload[i] < 0x10) Serial.print('0');
    Serial.print(payload[i], HEX);
  }
  Serial.print(F(" ("));
  Serial.print(sizeof(payload));
  Serial.println(F(" bytes)"));

  modem.setPort(PUERTO_DATOS);
  modem.beginPacket();
  modem.write(payload, sizeof(payload));

  // endPacket(false) = mensaje NO confirmado.
  // Los confirmados obligan al servidor a responder con un downlink, y los
  // downlinks son un recurso escaso: el gateway no puede recibir mientras
  // transmite. Para telemetria periodica, no confirmados.
  int err = modem.endPacket(false);

  if (err > 0) {
    Serial.println(F("   enviado."));
    contador++;
  } else {
    Serial.print(F("   ERROR al enviar (codigo "));
    Serial.print(err);
    Serial.println(F(")."));
  }
}

// ---------------------------------------------------------------------------
void loop() {
  if (millis() - ultimoEnvio >= INTERVALO_MS) {
    ultimoEnvio = millis();
    enviarMuestra();
  }

  // Si llega un downlink, lo mostramos. No hace falta pedirlo: el modulo lo
  // entrega despues de cada uplink, en las ventanas RX1/RX2 (ver 4.9).
  if (modem.available()) {
    Serial.print(F("Downlink recibido: "));
    while (modem.available()) {
      uint8_t b = modem.read();
      if (b < 0x10) Serial.print('0');
      Serial.print(b, HEX);
    }
    Serial.println();
  }
}
