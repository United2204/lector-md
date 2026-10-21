# Estado de funciones

## Implementado

### Importar directamente DOC/DOCX/PDF

Se pueden abrir documentos DOC y DOCX, y PDF, desde el selector de archivos o arrastrándolos a la ventana. El texto extraído se convierte a Markdown y se ofrece guardar con el nombre del documento original. Los PDF escaneados sin texto seleccionable muestran un aviso porque todavía no tienen OCR.

### Convertir texto copiado de documentos a Markdown

La acción **Pegar** lee el portapapeles y convierte el contenido a Markdown. Cuando hay HTML o RTF, conserva títulos, párrafos, listas, enlaces y estilos en línea disponibles; si solo hay texto plano, organiza saltos de línea y viñetas comunes. Al terminar, abre el diálogo para guardar un archivo `.md`; si se cancela, el contenido sigue disponible para guardarlo después.

Esta opción complementa la importación directa descrita arriba: sirve para convertir el contenido seleccionado en cualquier otra aplicación.

## Pendiente

- Añadir OCR para extraer texto de PDF escaneados.
- Publicar versiones instalables firmadas y notarizadas para habilitar la descarga e instalación automática desde la app.
