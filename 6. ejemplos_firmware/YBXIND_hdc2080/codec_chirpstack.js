/*
 * Payload codec para ChirpStack v4 — YUBOX Industrial + sensor HDC2080.
 *
 * Dónde se pega:
 *   ChirpStack → Device profiles → (perfil del Yubox) → pestaña "Payload codec"
 *   Payload codec: JavaScript functions
 *
 * Qué envía este firmware (ver yubox-lorawan-hdc2080.ino, crearPayloadSensor):
 *   Un objeto JSON serializado como texto ASCII, por ejemplo:
 *
 *      {"ts":1753900000000,"temp":25.43,"hum":60.12}
 *
 *      ts   : hora UTC en milisegundos (epoch), obtenida por NTP
 *      temp : temperatura en °C leída del HDC2080
 *      hum  : humedad relativa en %
 *
 *   OJO: enviar JSON en texto es didáctico pero derrochador (~45 bytes para
 *   lo que cabría en 4). El ejemplo MKRWAN1310 del curso muestra el
 *   empaquetado binario eficiente; este muestra el extremo opuesto.
 *
 * Qué hace este decoder:
 *   - Publica data.temperatura y data.humedad como números (graficables y
 *     listos para las integraciones: InfluxDB, MQTT, etc.).
 *   - Convierte ts a fecha legible en data.fecha (ISO 8601, UTC).
 *   - Si el sensor no fue detectado al arrancar, el firmware manda un JSON
 *     vacío: en ese caso se lanza una excepción con un mensaje claro, que
 *     ChirpStack muestra como evento de error del dispositivo. (A diferencia
 *     de TTN, ChirpStack no usa los arreglos errors/warnings: solo lee
 *     "data" del objeto retornado, y los errores se reportan con throw.)
 */

function decodeUplink(input) {
  var b = input.bytes;

  // Bytes -> texto ASCII
  var texto = "";
  for (var i = 0; i < b.length; i++) {
    texto += String.fromCharCode(b[i]);
  }

  var obj;
  try {
    obj = JSON.parse(texto);
  } catch (e) {
    throw new Error("El payload no es JSON válido: [" + texto + "]");
  }

  // Sin sensor HDC2080 detectado, crearPayloadSensor() serializa un
  // documento vacío ("null" o "{}"): no hay lectura que reportar.
  if (!obj || typeof obj.temp !== "number" || typeof obj.hum !== "number") {
    throw new Error("JSON sin lecturas: ¿sensor HDC2080 no detectado en el nodo?");
  }

  var data = {
    temperatura: Math.round(obj.temp * 100) / 100,  // °C
    humedad: Math.round(obj.hum * 100) / 100        // %HR
  };

  if (typeof obj.ts === "number" && obj.ts > 0) {
    data.ts = obj.ts;
    data.fecha = new Date(obj.ts).toISOString();
  } else {
    // ts en 0: el nodo aún no sincroniza su reloj por NTP
    data.aviso = "Nodo sin hora NTP; usar la hora de recepción del servidor";
  }

  return { data: data };
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
