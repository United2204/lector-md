import AppKit
import PDFKit
import UniformTypeIdentifiers

enum DocumentInputType {
    case markdown
    case word
    case pdf

    static func classify(_ url: URL) -> DocumentInputType? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown": return .markdown
        case "doc", "docx": return .word
        case "pdf": return .pdf
        default: return nil
        }
    }

    static var allowedContentTypes: [UTType] {
        return ["md", "markdown", "mdown", "doc", "docx", "pdf"]
            .compactMap { UTType(filenameExtension: $0) }
    }
}

struct ImportedWordContent {
    let html: String
    let plainText: String
}

private enum DirectDocumentImportError: LocalizedError {
    case unreadablePDF
    case lockedPDF
    case pdfHasNoText
    case wordHasNoText
    case unsupportedWordFormat

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "No se pudo leer el archivo PDF. Comprueba que no esté dañado."
        case .lockedPDF:
            return "El PDF está protegido con contraseña. Desbloquéalo y vuelve a intentarlo."
        case .pdfHasNoText:
            return "No se encontró texto seleccionable en el PDF. Si es un escaneo, necesitará OCR, que todavía no está disponible."
        case .wordHasNoText:
            return "El documento de Word no contiene texto para convertir."
        case .unsupportedWordFormat:
            return "No se pudo convertir el formato de Word en Markdown."
        }
    }
}

enum DirectDocumentImporter {
    static func markdownFromPDF(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw DirectDocumentImportError.unreadablePDF
        }
        if document.isEncrypted && document.isLocked {
            throw DirectDocumentImportError.lockedPDF
        }

        let extractedText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
        let markdown = PlainTextMarkdownConverter.convert(extractedText)
        guard !markdown.isEmpty else {
            throw DirectDocumentImportError.pdfHasNoText
        }
        return markdown
    }

    static func wordContent(at url: URL) throws -> ImportedWordContent {
        let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "doc"
            ? .docFormat
            : .officeOpenXML
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: type],
            documentAttributes: nil
        )
        guard attributed.length > 0 else {
            throw DirectDocumentImportError.wordHasNoText
        }

        let htmlData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )
        guard let html = String(data: htmlData, encoding: .utf8), !html.isEmpty else {
            throw DirectDocumentImportError.unsupportedWordFormat
        }
        return ImportedWordContent(html: html, plainText: attributed.string)
    }
}
