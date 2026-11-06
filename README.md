# Charlado

Dictado local en español e inglés para macOS. Mantén pulsada **Fn (🌐)**, habla y suelta la tecla para pegar el texto donde está el cursor. Charlado vive en la barra de menú y muestra un pequeño indicador mientras graba y transcribe.

## Instalación desde el código

Necesitas macOS 26 o posterior y las herramientas de Xcode con el SDK de macOS 26.

```sh
git clone https://github.com/AsymmetricFrequency/charlado.app.git
cd charlado.app
./build.sh
open ~/Applications/Charlado.app
```

## Configurar el dictado en español

1. Abre **Charlado** y pulsa **Configurar permisos**. Concede **Micrófono** y **Reconocimiento de voz** cuando macOS lo solicite.
2. En **Ajustes del Sistema → Privacidad y seguridad**, habilita Charlado en **Accesibilidad** y **Monitorización de entrada**. Si no aparece, pulsa **+** en el panel correspondiente, abre `~/Applications` y selecciona `Charlado.app`.
3. Vuelve a abrir Charlado si macOS lo pide. En **Idioma del dictado**, selecciona **Español**. Si falta el modelo de Apple, macOS lo descarga en este paso. Espera a que Charlado indique que está listo.
4. Pulsa **Probar micrófono**, di «Mañana revisamos el proyecto a las tres» y pulsa **Terminar prueba**. El resultado aparece en la misma ventana.
5. Pulsa **Seguir en segundo plano**. Coloca el cursor en un campo de texto, mantén **Fn**, dicta y suelta la tecla. Si el texto queda en el portapapeles, pégalo con **⌘V**.

## Dictate in English

1. Build and open Charlado using the commands above. Click **Configurar permisos** and allow Microphone and Speech Recognition. Enable Charlado under **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**, then reopen it if prompted.
2. Choose **English** in **Idioma del dictado**. macOS downloads its local English model if needed. Charlado remembers your selection.
3. Click **Probar micrófono**, say “The meeting starts at nine,” then click **Terminar prueba** to see the text.
4. Click **Seguir en segundo plano**. In a text field, hold **Fn** to talk and release it to paste. Use **⌘V** if automatic paste fails.

Si Fn abre emojis o activa una función de macOS, elige **No hacer nada** para Fn/🌐 en **Ajustes del Sistema → Teclado**. También puedes mantener pulsado **Control + Opción + D**.

## Dictar y recuperar texto

Pon el cursor en un campo editable y mantén pulsado el atajo. El indicador muestra **Tomando nota** mientras hablas y **Preparando texto** cuando sueltas. Charlado pone el resultado en el portapapeles y solicita pegarlo si el campo sigue activo. Si el pegado automático no llega, pulsa **⌘V**.

Cerrar la ventana mantiene el atajo activo. Para detenerlo, elige **Salir** desde el icono de la barra de menú.

## Privacidad

La transcripción se realiza en el Mac con el modelo de Apple. Charlado usa archivos temporales de audio durante el procesamiento y los elimina cuando termina la sesión de dictado. El último texto queda en memoria hasta el siguiente dictado o hasta salir. El portapapeles de macOS conserva el resultado según su funcionamiento habitual.

## Desarrollo

`./build.sh /ruta/Charlado.app` permite compilar en una ubicación distinta e incluye una comprobación de limpieza de texto. Para usar una identidad de firma propia, establece `CHARLADO_SIGN_IDENTITY` al ejecutar el script. macOS puede volver a solicitar permisos después de reemplazar una compilación con firma ad hoc.

## Licencia

[MIT](LICENSE)

## Vocabulario y dictado mixto

En la ventana principal, abre **Vocabulario** y escribe hasta 30 términos breves
separados por comas, por ejemplo `deploy, staging, pull request, GitHub`. Charlado
conserva la grafía de las coincidencias y pasa los términos como contexto al motor
local. El vocabulario orienta el reconocimiento, pero algunos nombres o acentos
pueden requerir corrección.

Para alternar español e inglés dentro de un dictado o una reunión, instala el
motor opcional y su modelo multilingüe de aproximadamente 57 MiB:

```sh
brew install whisper-cpp
./setup-mixed.sh
```

El script comprueba la suma SHA-256 del modelo. Selecciona **Mixto ES + EN** en
**Idioma del dictado**. La detección inicial del idioma es automática. El motor
puede confundir palabras o perder precisión si cambias de idioma a mitad de frase.
Para grabaciones de un solo idioma puedes elegir el modelo de macOS directamente.

## Reuniones

1. Elige el idioma en Charlado. Desde su barra de menú, pulsa **Iniciar reunión**
   para grabar el micrófono o **Grabar llamada…** para elegir la aplicación de la llamada.
2. Avisa a los participantes. Para llamadas, concede a Charlado el permiso de
   **Grabación de pantalla y audio del sistema** cuando macOS lo pida. Charlado
   captura audio del micrófono y de la aplicación seleccionada. En un navegador,
   eso puede incluir audio de otras pestañas de la misma aplicación.
3. Usa **Pausar reunión**, **Reanudar reunión** o **Marcar momento** desde el mismo
   menú o desde el indicador flotante. El indicador muestra la duración, las
   marcas y el nivel del micrófono. Con Reducir movimiento activo, el medidor es fijo.
4. Pulsa **Terminar reunión**. La biblioteca guarda la transcripción con marcas de
   tiempo, y permite añadir notas, exportar Markdown o usar **Copiar para IA**.
   En llamadas las etiquetas **Micrófono** y **Llamada** identifican la fuente
   de audio. La etiqueta **Llamada** agrupa a los participantes remotos.

Charlado guarda las notas y transcripciones en
`~/Library/Application Support/Charlado/Meetings`. La app elimina los archivos
temporales de audio al terminar una sesión normal. **Copiar para IA** prepara el
texto y una solicitud de resumen para que decidas dónde pegarlo.

## Decisiones y tareas

Al terminar una reunión, Charlado guarda la transcripción y prepara un borrador
editable en **Decisiones y tareas**. Cada punto incluye el minuto inicial del
fragmento de origen. El borrador conserva los plazos relativos como se dijeron
y muestra **Sin asignar** o **Sin fecha** cuando faltan esos datos.

Charlado usa Apple Intelligence de forma local cuando está disponible y también
detecta expresiones explícitas como «acordamos» o «se encarga de». Si Apple
Intelligence no está disponible, esa detección sigue funcionando, aunque puede
dejar más puntos para revisión manual. El borrador se incluye al exportar o
compartir la reunión. Revísalo antes de usarlo como acta.

## Buscar en la biblioteca

Escribe una frase en **Buscar en todas las reuniones**. La búsqueda incluye
las transcripciones locales, tanto privadas como compartidas, e ignora
mayúsculas y tildes. Elige una coincidencia por reunión y minuto y pulsa
**Ir al fragmento** para abrir la transcripción y resaltar el texto. Si
editaste una transcripción, guarda los cambios para incluirlos en la búsqueda.

## MCP de reuniones

Abre **Conexiones MCP** en Charlado para ver cuántas reuniones has compartido
y copiar el comando de Claude Code o del túnel. La pantalla muestra el acceso
local. Verifica el estado de la conexión desde el cliente.

En la biblioteca selecciona una reunión y pulsa **Compartir con MCP**. El
servidor solo puede consultar las reuniones compartidas, mediante
`search_meetings` y `read_meeting`. Puedes retirar cada reunión en la biblioteca.

Para Claude Code, ejecuta:

```sh
claude mcp add --scope user --transport stdio charlado -- "$HOME/Applications/Charlado.app/Contents/MacOS/Charlado" --mcp
```

Para ChatGPT, usa el [túnel seguro de OpenAI](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
con el comando stdio `~/Applications/Charlado.app/Contents/MacOS/Charlado --mcp`
(expande `~` a tu ruta absoluta en la configuración). Crea o selecciona un túnel
para tu espacio de trabajo, configura el cliente del túnel con ese comando y
agrégalo como MCP personalizado en ChatGPT. Necesitas los permisos del espacio
de trabajo y una clave de ejecución del túnel. Mientras un cliente esté
conectado, podrá leer las reuniones que hayas compartido.
