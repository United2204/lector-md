# Lector MD

App sencilla para macOS que abre archivos Markdown y convierte documentos Word y PDF a Markdown para presentarlos en un formato cómodo de leer. Permite imprimir, exportar a PDF y guardar una copia como DOCX.

## Requisitos

- macOS 13 o posterior
- Swift 6

## Compilar

Desde esta carpeta, ejecutar:

```sh
swift build -c release
```

El ejecutable se genera en `.build/release/LectorMD`.

Para compilar y empaquetar la app macOS, ejecutar:

```sh
./Scripts/build-app.sh
```

El paquete `.app` se genera en `.build/Lector MD.app`.

## Funciones actuales

- Abrir `.md`, `.markdown`, `.mdown`, `.doc`, `.docx` y `.pdf` desde el selector de archivos o arrastrándolos a la ventana
- Extraer el texto de Word y PDF, convertirlo a Markdown y abrir el diálogo para guardarlo como `.md`
- Pegar texto copiado desde un archivo DOC/DOCX o PDF y convertirlo a Markdown, conservando el formato que exponga el portapapeles
- Mostrar títulos, párrafos, listas, citas, bloques de código, separadores y estilos en línea
- Guardar como `.md`, imprimir y exportar a PDF o DOCX
- Buscar actualizaciones publicadas en GitHub desde el botón de recarga o el menú de la app

Los PDF escaneados que no contienen texto seleccionable requieren OCR; esa función todavía no está disponible.

El buscador de actualizaciones revisa GitHub Releases. Para ofrecer una actualización descargable hay que publicar allí un paquete de la app; la instalación automática requerirá además firma y notarización.

Consulta [PENDIENTES.md](PENDIENTES.md) para la idea de próxima función.
