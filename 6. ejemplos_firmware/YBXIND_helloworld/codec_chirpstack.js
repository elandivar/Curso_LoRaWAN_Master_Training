/*
 * Payload codec para ChirpStack v4 — YUBOX Industrial "Hola mundo".
 *
 * Dónde se pega:
 *   ChirpStack → Device profiles → (perfil del Yubox) → pestaña "Codec"
 *   Payload codec: JavaScript functions
 *
 * Qué envía este firmware (ver yubox-lorawan-helloworld.ino):
 *   A diferencia de un nodo de producción, este ejemplo NO empaqueta binario:
 *   transmite TEXTO plano en ASCII. Por defecto envía "Hola mundo" cada 10 s,
 *   y desde la interfaz web del Yubox (POST /yubox-api/lorawan/payload) se
 *   puede cargar cualquier otro texto para el siguiente envío.
 *
 * Qué hace este decoder:
 *   1. Convierte los bytes recibidos a texto y lo publica en data.texto.
 *   2. Si el texto es JSON (p. ej. {"temp":25.4,"hum":60.2}), expone sus
 *      campos numéricos directamente, con lo que ChirpStack los puede
 *      graficar y las integraciones (InfluxDB, MQTT, etc.) los reciben
 *      como valores y no como cadena.
 *   3. Si el texto son dos números separados por coma o punto y coma
 *      (p. ej. "25.4,60.2"), los interpreta como temperatura y humedad.
 *
 *   Con el "Hola mundo" por defecto solo verás data.texto; en cuanto se
 *   cargue una lectura con formato numérico aparecen los campos extra.
 */

function decodeUplink(input) {
  var b = input.bytes;

  // Bytes -> texto. Se sustituye cualquier byte no imprimible por "." para
  // que un payload binario inesperado no ensucie la consola de ChirpStack.
  var texto = "";
  for (var i = 0; i < b.length; i++) {
    texto += (b[i] >= 32 && b[i] <= 126) ? String.fromCharCode(b[i]) : ".";
  }

  var data = {
    texto: texto,
    longitud: b.length,
    fPort: input.fPort
  };

  var recortado = texto.trim();

  // Caso 1: el texto es un objeto JSON -> se copian sus campos numéricos
  // (y de paso se normalizan los nombres más comunes de temp/humedad).
  if (recortado.charAt(0) === "{") {
    try {
      var obj = JSON.parse(recortado);
      for (var clave in obj) {
        if (typeof obj[clave] === "number") {
          data[normalizarClave(clave)] = obj[clave];
        }
      }
    } catch (e) {
      // No era JSON válido: se queda solo como texto, sin error.
    }
  }

  // Caso 2: dos números separados por coma o punto y coma -> temp,hum
  var m = recortado.match(/^(-?\d+(?:\.\d+)?)\s*[,;]\s*(-?\d+(?:\.\d+)?)$/);
  if (m) {
    data.temperatura = parseFloat(m[1]);
    data.humedad = parseFloat(m[2]);
  }

  return { data: data };
}

// Unifica los nombres típicos para que el resultado siempre use
// "temperatura" y "humedad", se escriba como se escriba en el JSON.
function normalizarClave(clave) {
  var k = clave.toLowerCase();
  if (k === "temp" || k === "temperature" || k === "t") return "temperatura";
  if (k === "hum" || k === "humidity" || k === "rh" || k === "h") return "humedad";
  return clave;
}

/*
 * Downlink opcional: permite mandar texto al nodo desde ChirpStack
 * (Device → Queue) escribiendo {"texto": "hola nodo"} como payload JSON.
 * El firmware lo imprime por el puerto serie en lorawan_rx().
 */
function encodeDownlink(input) {
  var texto = (input.data && input.data.texto) ? String(input.data.texto) : "";
  var bytes = [];
  for (var i = 0; i < texto.length; i++) {
    bytes.push(texto.charCodeAt(i) & 0xFF);
  }
  return { bytes: bytes };
}
