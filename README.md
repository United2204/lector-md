# Lector MD

App sencilla para macOS que abre archivos Markdown y los presenta en un formato cómodo de leer. Permite imprimir, exportar a PDF y guardar una copia como DOCX.

## Requisitos

- macOS 13 o posterior
- Swift 6

## Compilar

Desde esta carpeta, ejecutar:

```sh
swift build -c release
```

El ejecutable se genera en `.build/release/LectorMD`.

## Funciones actuales

- Abrir `.md`, `.markdown` y `.mdown` desde la app o Finder
- Mostrar títulos, párrafos, listas, citas, bloques de código, separadores y estilos en línea
- Imprimir y exportar a PDF o DOCX

Consulta [PENDIENTES.md](PENDIENTES.md) para la idea de próxima función.
