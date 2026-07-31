/*
 * Payload formatter para The Things Network.
 *
 * Dónde se pega:
 *   Consola de TTN → tu aplicación → Payload formatters → Uplink
 *   Formatter type: Custom JavaScript formatter
 *
 * Deshace el empaquetado del sketch MKRWAN1310_TTN_AU915.ino:
 *
 *   byte 0-1 : contador          uint16 big-endian
 *   byte 2-3 : lectura de A0     uint16, 0..1023
 *   byte 4   : minutos encendido uint8, saturado en 255
 *
 *   byte 5   : batería (OPCIONAL) (V − 2,00) × 100
 *              Solo aparece si activaste la medida con divisor externo.
 */

function decodeUplink(input) {
  var b = input.bytes;

  // Sin esta comprobación, un payload corto da valores absurdos en lugar de
  // un error claro. Conviene siempre.
  if (b.length < 5) {
    return {
      errors: ["Payload de " + b.length + " bytes; se esperaban 5 o 6"]
    };
  }

  var a0 = (b[2] << 8) | b[3];

  var salida = {
    contador: (b[0] << 8) | b[1],
    a0: a0,
    a0_voltios: Math.round((a0 * 3.3 / 1023) * 1000) / 1000,
    uptime_min: b[4]
  };

  var avisos = [];

  if (b[4] === 255) {
    avisos.push("Uptime saturado (255 min o más)");
  }

  // Sexto byte opcional: batería medida con divisor externo
  if (b.length >= 6) {
    salida.bateria_v = Math.round((b[5] / 100 + 2.0) * 100) / 100;
    if (salida.bateria_v < 3.3) {
      avisos.push("Batería baja: " + salida.bateria_v + " V");
    }
  }

  return avisos.length ? { data: salida, warnings: avisos }
                       : { data: salida };
}
