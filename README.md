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
