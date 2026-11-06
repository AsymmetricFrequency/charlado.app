# Charlado

Dictado local en español para macOS. Mantén pulsada **Fn (🌐)**, habla y suelta la tecla para pegar el texto donde está el cursor. Charlado vive en la barra de menú y muestra un pequeño indicador mientras graba y transcribe.

## Instalación desde el código

Necesitas macOS 26 o posterior y las herramientas de Xcode con el SDK de macOS 26.

```sh
git clone https://github.com/AsymmetricFrequency/charlado.app.git
cd charlado.app
./build.sh
open ~/Applications/Charlado.app
```

1. En Charlado, pulsa **Configurar permisos**. Concede Micrófono y Reconocimiento de voz. En **Ajustes del Sistema → Privacidad y seguridad**, habilita Charlado en **Accesibilidad** y **Monitorización de entrada**. Si la app no aparece, agrégala con **+** desde `~/Applications`.
2. Vuelve a abrir la app si macOS te lo pide. El primer arranque puede descargar el modelo local de español.
3. Pulsa **Probar micrófono** para ver una transcripción dentro de Charlado, o pulsa **Seguir en segundo plano** para usarlo en otras apps.

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
