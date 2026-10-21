import AppKit
import WebKit
import PDFKit
import UniformTypeIdentifiers

private struct InlineNode {
    enum Kind { case text, strong, emphasis, code, strike, link }
    let kind: Kind
    let text: String
    let children: [InlineNode]
    let href: String?

    init(_ kind: Kind, text: String = "", children: [InlineNode] = [], href: String? = nil) {
        self.kind = kind
        self.text = text
        self.children = children
        self.href = href
    }
}

private enum Block {
    case heading(Int, [InlineNode])
    case paragraph([InlineNode])
    case quote([InlineNode])
    case listItem(ordered: Bool, number: Int, [InlineNode])
    case code(String)
    case rule
}

private struct MarkdownDocument {
    let blocks: [Block]

    init(_ markdown: String) {
        self.blocks = Self.parse(markdown)
    }

    private static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var index = 0

        func heading(_ line: String) -> (Int, String)? {
            guard let match = line.range(of: #"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#, options: .regularExpression) else { return nil }
            let value = String(line[match]).trimmingCharacters(in: .whitespaces)
            let hashes = value.prefix(while: { $0 == "#" }).count
            let content = value.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return (max(1, min(6, hashes)), content)
        }

        func unorderedItem(_ line: String) -> String? {
            guard let range = line.range(of: #"^\s{0,3}[-+*]\s+(.+)$"#, options: .regularExpression) else { return nil }
            return String(line[range]).replacingOccurrences(of: #"^\s{0,3}[-+*]\s+"#, with: "", options: .regularExpression)
        }

        func orderedItem(_ line: String) -> (Int, String)? {
            guard let range = line.range(of: #"^\s{0,3}(\d+)[.)]\s+(.+)$"#, options: .regularExpression) else { return nil }
            let value = String(line[range])
            guard let numberRange = value.range(of: #"^\s*\d+"#, options: .regularExpression),
                  let number = Int(value[numberRange].trimmingCharacters(in: .whitespaces)) else { return nil }
            let text = value.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
            return (number, text)
        }

        func isRule(_ line: String) -> Bool {
            line.range(of: #"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#, options: .regularExpression) != nil
        }

        func isBlockStart(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return heading(line) != nil || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") ||
                isRule(line) || trimmed.hasPrefix(">") || unorderedItem(line) != nil || orderedItem(line) != nil
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if let (level, text) = heading(line) {
                blocks.append(.heading(level, InlineParser.parse(text)))
                index += 1
                continue
            }

            if isRule(line) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoteLines.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(InlineParser.parse(quoteLines.joined(separator: " "))))
                continue
            }

            if let item = unorderedItem(line) {
                blocks.append(.listItem(ordered: false, number: 0, InlineParser.parse(item)))
                index += 1
                while index < lines.count, let next = unorderedItem(lines[index]) {
                    blocks.append(.listItem(ordered: false, number: 0, InlineParser.parse(next)))
                    index += 1
                }
                continue
            }

            if let item = orderedItem(line) {
                blocks.append(.listItem(ordered: true, number: item.0, InlineParser.parse(item.1)))
                index += 1
                while index < lines.count, let next = orderedItem(lines[index]) {
                    blocks.append(.listItem(ordered: true, number: next.0, InlineParser.parse(next.1)))
                    index += 1
                }
                continue
            }

            var paragraph = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && !isBlockStart(lines[index]) {
                paragraph.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.paragraph(InlineParser.parse(paragraph.joined(separator: " "))))
        }
        return blocks
    }
}

private enum InlineParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"`([^`]+)`|\*\*(.+?)\*\*|__(.+?)__|~~(.+?)~~|\[([^\]]+)\]\(([^\s)]+)(?:\s+[^)]*)?\)|(?<!\*)\*([^*]+)\*(?!\*)|(?<!_)_([^_]+)_(?!_)"#,
        options: []
    )

    static func parse(_ text: String) -> [InlineNode] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = expression.matches(in: text, range: full)
        guard !matches.isEmpty else { return [InlineNode(.text, text: text)] }

        var nodes: [InlineNode] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                nodes.append(InlineNode(.text, text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            let selected = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound }
            guard let group = selected else { cursor = NSMaxRange(match.range); continue }
            let value = ns.substring(with: match.range(at: group))
            switch group {
            case 1: nodes.append(InlineNode(.code, text: value))
            case 2, 3: nodes.append(InlineNode(.strong, children: parse(value)))
            case 4: nodes.append(InlineNode(.strike, children: parse(value)))
            case 5:
                let href = ns.substring(with: match.range(at: 6))
                nodes.append(InlineNode(.link, children: parse(value), href: href))
            case 7, 8: nodes.append(InlineNode(.emphasis, children: parse(value)))
            default: nodes.append(InlineNode(.text, text: value))
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { nodes.append(InlineNode(.text, text: ns.substring(from: cursor))) }
        return nodes
    }
}

private enum DocumentOutput {
    static func html(_ document: MarkdownDocument, fileName: String?) -> String {
        let body: String
        if document.blocks.isEmpty {
            body = #"<section class="welcome"><div class="welcome-icon">✦</div><p class="eyebrow">LECTOR MD</p><h1>Tu Markdown, con espacio para respirar.</h1><p>Abre un archivo .md o arrástralo hasta aquí para ver una versión limpia, lista para leer, imprimir o compartir.</p></section>"#
        } else {
            body = document.blocks.map(Self.htmlBlock).joined(separator: "\n")
        }
        let caption = fileName.map { #"<div class="document-name">\#(escapeHTML($0))</div>"# } ?? ""
        return #"""
        <!doctype html>
        <html lang="es">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <title>\#(escapeHTML(fileName ?? "Lector MD"))</title>
        <style>
          :root { color-scheme: light; }
          * { box-sizing: border-box; }
          html { background: #f2f0eb; }
          body { margin: 0; padding: 42px 28px 54px; color: #222d39; background: #f2f0eb; font: 17px/1.78 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; -webkit-font-smoothing: antialiased; }
          .sheet { max-width: 850px; min-height: 680px; margin: 0 auto; padding: 72px 84px 86px; background: #fff; border: 1px solid rgba(35,48,62,.07); border-radius: 5px; box-shadow: 0 14px 46px rgba(37,47,56,.09), 0 2px 5px rgba(37,47,56,.04); }
          .document-name { margin: 0 0 34px; padding-bottom: 14px; border-bottom: 1px solid #e9edf0; color: #82909c; font: 11px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; letter-spacing: .11em; text-transform: uppercase; }
          h1,h2,h3,h4,h5,h6 { color: #183b56; line-height: 1.24; letter-spacing: -.025em; font-weight: 680; }
          h1 { margin: 0 0 25px; font-size: 2.25em; }
          h2 { margin: 1.9em 0 .55em; padding-bottom: .28em; border-bottom: 1px solid #edf0f2; font-size: 1.62em; }
          h3 { margin: 1.55em 0 .45em; font-size: 1.27em; }
          h4,h5,h6 { margin: 1.3em 0 .4em; font-size: 1.08em; }
          p { margin: 0 0 1.2em; }
          a { color: #1677a9; text-decoration-color: #9bc9dc; text-underline-offset: 3px; }
          strong { color: #193b53; font-weight: 700; }
          em { color: #425665; }
          del { color: #7d8993; }
          ul,ol { margin: .2em 0 1.35em; padding-left: 1.55em; }
          .list-row { display: flex; gap: .15em; margin: .3em 0; }
          .list-marker { flex: 0 0 1.5em; color: #2282a7; }
          blockquote { margin: 1.5em 0; padding: .1em 0 .1em 1.1em; color: #586775; border-left: 3px solid #6fb3c5; }
          blockquote p:last-child { margin-bottom: 0; }
          code { padding: .15em .38em; color: #8f3f50; background: #f4f1f0; border-radius: 4px; font: .88em/1.5 "SFMono-Regular", Menlo, Consolas, monospace; }
          pre { margin: 1.4em 0 1.65em; padding: 18px 20px; overflow: auto; color: #e7edf3; background: #1f2d3b; border: 1px solid #263b4d; border-radius: 7px; font: 13px/1.65 "SFMono-Regular", Menlo, Consolas, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
          pre code { padding: 0; color: inherit; background: transparent; border-radius: 0; font: inherit; }
          hr { height: 1px; margin: 2em 0; border: 0; background: #e7ecef; }
          .welcome { display: grid; place-content: center; min-height: 515px; max-width: 550px; margin: auto; text-align: center; }
          .welcome-icon { display: grid; place-items: center; width: 58px; height: 58px; margin: 0 auto 24px; color: #18779d; background: #e8f4f5; border: 1px solid #d6ebed; border-radius: 18px; font-size: 26px; }
          .eyebrow { margin: 0 0 12px; color: #5d8993; font: 11px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; font-weight: 700; letter-spacing: .16em; }
          .welcome h1 { margin: 0 auto 15px; font-size: 30px; }
          .welcome p:last-child { max-width: 430px; margin: 0 auto; color: #74818b; font-size: 15px; }
          @media print {
            @page { size: A4; margin: 20mm 21mm; }
            html, body { margin: 0; padding: 0; background: #fff; }
            body { color: #202830; font-size: 11pt; line-height: 1.6; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            .sheet { width: auto; max-width: none; min-height: 0; margin: 0; padding: 0; border: 0; border-radius: 0; box-shadow: none; }
            h1,h2,h3,h4,h5,h6 { break-after: avoid-page; }
            pre, blockquote, .list-row { break-inside: avoid; }
            a { color: #126c94; }
          }
        </style>
        </head>
        <body><main class="sheet">\#(caption)
        \#(body)
        </main></body></html>
        """#
    }

    static var pdfStyleScript: String {
        let css = #"""
        html, body { width: 100% !important; min-width: 0 !important; margin: 0 !important; padding: 0 !important; background: #fff !important; }
        body { color: #222d39 !important; font: 16px/1.62 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif !important; }
        .sheet { width: auto !important; max-width: none !important; min-height: 0 !important; margin: 0 !important; padding: 0 !important; background: #fff !important; border: 0 !important; border-radius: 0 !important; box-shadow: none !important; }
        .document-name { margin: 0 0 28px !important; padding-bottom: 10px !important; }
        """#
        let encoded = try! JSONSerialization.data(withJSONObject: css, options: [.fragmentsAllowed])
        let javascriptString = String(data: encoded, encoding: .utf8)!
        return "(() => { let style = document.getElementById('lectormd-pdf-export-style'); if (!style) { style = document.createElement('style'); style.id = 'lectormd-pdf-export-style'; document.head.appendChild(style); } style.textContent = \(javascriptString); return true; })()"
    }

    static let removePDFStyleScript = "document.getElementById('lectormd-pdf-export-style')?.remove(); true"

    static let pdfMetricsScript = #"""
    (() => {
      const sheet = document.querySelector('.sheet');
      if (!sheet) return null;
      const blocks = Array.from(sheet.children).map((node) => {
        const rect = node.getBoundingClientRect();
        return { top: rect.top + window.scrollY, bottom: rect.bottom + window.scrollY, tag: node.tagName };
      });
      return { height: Math.max(document.documentElement.scrollHeight, document.body.scrollHeight), blocks };
    })()
    """#

    private static func htmlBlock(_ block: Block) -> String {
        switch block {
        case .heading(let level, let nodes): return "<h\(level)>\(htmlInline(nodes))</h\(level)>"
        case .paragraph(let nodes): return "<p>\(htmlInline(nodes))</p>"
        case .quote(let nodes): return "<blockquote><p>\(htmlInline(nodes))</p></blockquote>"
        case .listItem(let ordered, let number, let nodes):
            let marker = ordered ? "\(number)." : "•"
            return "<div class=\"list-row\"><span class=\"list-marker\">\(marker)</span><span>\(htmlInline(nodes))</span></div>"
        case .code(let text): return "<pre><code>\(escapeHTML(text))</code></pre>"
        case .rule: return "<hr>"
        }
    }

    private static func htmlInline(_ nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node.kind {
            case .text: return escapeHTML(node.text)
            case .strong: return "<strong>\(htmlInline(node.children))</strong>"
            case .emphasis: return "<em>\(htmlInline(node.children))</em>"
            case .code: return "<code>\(escapeHTML(node.text))</code>"
            case .strike: return "<del>\(htmlInline(node.children))</del>"
            case .link:
                let href = node.href ?? ""
                return "<a href=\"\(escapeHTML(href))\">\(htmlInline(node.children))</a>"
            }
        }.joined()
    }

    static func docx(_ document: MarkdownDocument, to destination: URL) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LectorMD-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        var links: [String: String] = [:]
        let paragraphs = document.blocks.map { wordBlock($0, links: &links) }.joined()
        let relationships = links.sorted { $0.value < $1.value }.map { pair in
            let (href, id) = pair
            return #"<Relationship Id="\#(id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="\#(escapeXML(href))" TargetMode="External"/>"#
        }.joined()
        let documentXML = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\#(paragraphs)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1191" w:bottom="1134" w:left="1191" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """#
        let types = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """#
        let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#
        let docRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(relationships)</Relationships>"#
        try types.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try documentXML.write(to: root.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try docRels.write(to: root.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)

        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", destination.path, "[Content_Types].xml", "_rels", "word"]
        let errors = Pipe()
        zip.standardError = errors
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "No se pudo crear el archivo Word."
            throw NSError(domain: "LectorMD.Docx", code: Int(zip.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private struct TextStyle {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link = false
        var size = 22
        var color = "273743"
    }

    private static func wordBlock(_ block: Block, links: inout [String: String]) -> String {
        switch block {
        case .heading(let level, let nodes):
            var style = TextStyle()
            style.bold = true
            style.size = [1: 40, 2: 32, 3: 28, 4: 25, 5: 23, 6: 22][level] ?? 22
            style.color = level <= 2 ? "183B56" : "2F5065"
            let props = #"<w:pPr><w:keepNext/><w:spacing w:before="\#(level == 1 ? 180 : 260)" w:after="\#(level == 1 ? 160 : 120)"/><w:outlineLvl w:val="\#(max(0, level - 1))"/></w:pPr>"#
            return paragraph(props, inline: wordInline(nodes, style: style, links: &links))
        case .paragraph(let nodes):
            return paragraph(#"<w:pPr><w:spacing w:after="180" w:line="330" w:lineRule="auto"/></w:pPr>"#, inline: wordInline(nodes, style: TextStyle(), links: &links))
        case .quote(let nodes):
            var style = TextStyle(); style.italic = true; style.color = "5C6F7C"
            let props = #"<w:pPr><w:ind w:left="460"/><w:pBdr><w:left w:val="single" w:sz="20" w:space="8" w:color="6FB3C5"/></w:pBdr><w:spacing w:before="100" w:after="180"/></w:pPr>"#
            return paragraph(props, inline: wordInline(nodes, style: style, links: &links))
        case .listItem(let ordered, let number, let nodes):
            let marker = ordered ? "\(number). " : "• "
            var inline = wordRun(marker, style: TextStyle())
            inline += wordInline(nodes, style: TextStyle(), links: &links)
            return paragraph(#"<w:pPr><w:ind w:left="430"/><w:spacing w:after="80"/></w:pPr>"#, inline: inline)
        case .code(let value):
            var style = TextStyle(); style.code = true; style.size = 19; style.color = "E8EDF2"
            let content = value.components(separatedBy: "\n").enumerated().map { index, line in
                (index == 0 ? "" : "<w:br/>") + wordRun(line, style: style)
            }.joined()
            return paragraph(#"<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="263746"/><w:ind w:left="180" w:right="180"/><w:spacing w:before="120" w:after="170"/></w:pPr>"#, inline: content)
        case .rule:
            return paragraph(#"<w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="4" w:color="DDE4E9"/></w:pBdr><w:spacing w:after="180"/></w:pPr>"#, inline: wordRun(" ", style: TextStyle()))
        }
    }

    private static func paragraph(_ properties: String, inline: String) -> String {
        "<w:p>\(properties)\(inline)</w:p>"
    }

    private static func wordInline(_ nodes: [InlineNode], style: TextStyle, links: inout [String: String]) -> String {
        nodes.map { node in
            switch node.kind {
            case .text: return wordRun(node.text, style: style)
            case .code:
                var next = style; next.code = true; next.color = "9A4355"
                return wordRun(node.text, style: next)
            case .strong:
                var next = style; next.bold = true
                return wordInline(node.children, style: next, links: &links)
            case .emphasis:
                var next = style; next.italic = true
                return wordInline(node.children, style: next, links: &links)
            case .strike:
                var next = style; next.strike = true
                return wordInline(node.children, style: next, links: &links)
            case .link:
                var next = style; next.link = true; next.color = "1677A9"
                let inner = wordInline(node.children, style: next, links: &links)
                guard let href = node.href else { return inner }
                let id: String
                if let found = links[href] { id = found }
                else { id = "rId\(links.count + 1)"; links[href] = id }
                return #"<w:hyperlink r:id="\#(id)" w:history="1">\#(inner)</w:hyperlink>"#
            }
        }.joined()
    }

    private static func wordRun(_ value: String, style: TextStyle) -> String {
        let fonts = style.code ? "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/>" : "<w:rFonts w:ascii=\"Aptos\" w:hAnsi=\"Aptos\"/>"
        let bold = style.bold ? "<w:b/>" : ""
        let italic = style.italic ? "<w:i/>" : ""
        let strike = style.strike ? "<w:strike/>" : ""
        let underline = style.link ? #"<w:u w:val="single"/>"# : ""
        let color = "<w:color w:val=\"\(style.color)\"/>"
        let size = "<w:sz w:val=\"\(style.size)\"/><w:szCs w:val=\"\(style.size)\"/>"
        let properties = "<w:rPr>\(fonts)\(bold)\(italic)\(strike)\(underline)\(color)\(size)</w:rPr>"
        let pieces = value.components(separatedBy: "\n")
        let text = pieces.enumerated().map { index, piece in
            (index == 0 ? "" : "<w:br/>") + "<w:t xml:space=\"preserve\">\(escapeXML(piece))</w:t>"
        }.joined()
        return "<w:r>\(properties)\(text)</w:r>"
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class DropWebView: WKWebView {
    var onMarkdownDrop: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let file = urls.first(where: { ["md", "markdown", "mdown"].contains($0.pathExtension.lowercased()) }) else { return false }
        onMarkdownDrop?(file)
        return true
    }
}

private struct PDFBlockMetric {
    let top: CGFloat
    let bottom: CGFloat
    let tag: String
}

private enum PDFPageComposer {
    struct Metrics {
        let documentHeight: CGFloat
        let blocks: [PDFBlockMetric]
    }

    struct Output {
        let data: Data
        let pageCount: Int
    }

    static func metrics(from value: Any?) -> Metrics? {
        guard let object = value as? [String: Any],
              let height = (object["height"] as? NSNumber)?.doubleValue,
              height > 0,
              let rawBlocks = object["blocks"] as? [[String: Any]] else { return nil }

        let blocks = rawBlocks.compactMap { item -> PDFBlockMetric? in
            guard let top = (item["top"] as? NSNumber)?.doubleValue,
                  let bottom = (item["bottom"] as? NSNumber)?.doubleValue else { return nil }
            return PDFBlockMetric(top: CGFloat(top), bottom: CGFloat(bottom), tag: item["tag"] as? String ?? "")
        }
        return Metrics(documentHeight: CGFloat(height), blocks: blocks)
    }

    static func compose(_ data: Data, metrics: Metrics?) throws -> Output {
        guard let provider = CGDataProvider(data: data as CFData),
              let sourceDocument = CGPDFDocument(provider),
              sourceDocument.numberOfPages > 0 else {
            throw pdfError("WebKit no generó un PDF válido.")
        }

        if sourceDocument.numberOfPages > 1 {
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                throw pdfError("El PDF generado no se pudo leer.")
            }
            return Output(data: data, pageCount: document.pageCount)
        }

        guard let sourcePage = sourceDocument.page(at: 1) else {
            throw pdfError("El PDF generado no contiene páginas.")
        }
        let sourceBox = sourcePage.getBoxRect(.mediaBox).standardized
        guard sourceBox.width > 0, sourceBox.height > 0 else {
            throw pdfError("El tamaño del documento no es válido.")
        }

        let paperSize = CGSize(width: 595.28, height: 841.89)
        let margin: CGFloat = 56.7
        let contentRect = CGRect(x: margin, y: margin, width: paperSize.width - margin * 2, height: paperSize.height - margin * 2)
        let scale = min(1, contentRect.width / sourceBox.width)
        let maximumSliceHeight = contentRect.height / scale
        let ranges = pageRanges(height: sourceBox.height, maximumSliceHeight: maximumSliceHeight, sourceBox: sourceBox, metrics: metrics)

        let outputBuffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputBuffer as CFMutableData) else {
            throw pdfError("No se pudo preparar el PDF de salida.")
        }
        var pageMediaBox = CGRect(origin: .zero, size: paperSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &pageMediaBox, nil) else {
            throw pdfError("No se pudo preparar el PDF de salida.")
        }

        for range in ranges {
            context.beginPDFPage(nil)
            context.saveGState()
            let visibleHeight = (range.upperBound - range.lowerBound) * scale
            let pageContentRect = CGRect(x: contentRect.minX, y: contentRect.maxY - visibleHeight, width: contentRect.width, height: visibleHeight)
            context.clip(to: pageContentRect)

            let sourceTop = sourceBox.maxY - range.lowerBound
            context.translateBy(x: contentRect.minX - sourceBox.minX * scale, y: contentRect.maxY - sourceTop * scale)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(sourcePage)

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        let result = outputBuffer as Data
        guard let outputPDF = PDFDocument(data: result), outputPDF.pageCount == ranges.count, outputPDF.pageCount > 0 else {
            throw pdfError("macOS no pudo validar el PDF paginado.")
        }
        while outputPDF.pageCount > 1 {
            let lastPageIndex = outputPDF.pageCount - 1
            let lastPageText = outputPDF.page(at: lastPageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lastPageText?.isEmpty ?? true else { break }
            outputPDF.removePage(at: lastPageIndex)
        }
        guard let finalData = outputPDF.dataRepresentation(),
              let finalPDF = PDFDocument(data: finalData), finalPDF.pageCount > 0 else {
            throw pdfError("macOS no pudo completar el PDF paginado.")
        }
        return Output(data: finalData, pageCount: finalPDF.pageCount)
    }

    private static func pageRanges(height: CGFloat, maximumSliceHeight: CGFloat, sourceBox: CGRect, metrics: Metrics?) -> [ClosedRange<CGFloat>] {
        guard maximumSliceHeight > 0 else { return [0...height] }
        let jsToPDFScale = metrics.map { sourceBox.height / $0.documentHeight } ?? 1
        let blockTops = (metrics?.blocks ?? []).map { min(height, max(0, $0.top * jsToPDFScale)) }.sorted()
        let groupTops: [CGFloat] = {
            let blocks = metrics?.blocks ?? []
            guard !blocks.isEmpty else { return blockTops }
            var groups: [CGFloat] = []
            var index = 0
            while index < blocks.count {
                let block = blocks[index]
                let isHeading = block.tag.count == 2 && block.tag.first == "H" && block.tag.last?.isNumber == true
                groups.append(min(height, max(0, block.top * jsToPDFScale)))
                index += (isHeading && index + 1 < blocks.count) ? 2 : 1
            }
            return groups.sorted()
        }()

        var ranges: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        while start < height {
            let limit = min(start + maximumSliceHeight, height)
            let earliestPreferred = start + maximumSliceHeight * 0.62
            let preferred = groupTops.last(where: { $0 > earliestPreferred && $0 < limit })
            let end = preferred ?? limit
            ranges.append(start...end)
            start = end
        }
        return ranges
    }

    private static func pdfError(_ description: String) -> NSError {
        NSError(domain: "LectorMD.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

private final class MainController: NSViewController, WKNavigationDelegate {
    private let webView = DropWebView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Abre un archivo .md para empezar")
    private var markdown = ""
    private var currentFile: URL?
    private var exportButtons: [NSButton] = []
    private var isDocumentReady = false

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.949, green: 0.945, blue: 0.925, alpha: 1).cgColor

        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        header.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Markdown") ?? NSImage())
        icon.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.55, alpha: 1)
        let title = NSTextField(labelWithString: "Lector MD")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        let subtitle = NSTextField(labelWithString: "Una lectura más cómoda")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NSColor.secondaryLabelColor
        let brandLabels = NSStackView(views: [title, subtitle])
        brandLabels.orientation = .vertical
        brandLabels.alignment = .leading
        brandLabels.spacing = 2
        let brand = NSStackView(views: [icon, brandLabels])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 10

        let spacer = NSView()
        let open = button("Abrir", symbol: "folder", action: #selector(openDocument))
        let print = button("Imprimir", symbol: "printer", action: #selector(printDocument))
        let pdf = button("PDF", symbol: "arrow.down.to.line", action: #selector(exportPDF))
        let docx = button("DOCX", symbol: "doc.richtext", action: #selector(exportDOCX))
        exportButtons = [print, pdf, docx]
        exportButtons.forEach { $0.isEnabled = false }

        let controls = NSStackView(views: [open, print, pdf, docx])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        let headerStack = NSStackView(views: [brand, spacer, controls])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 18
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = NSColor(calibratedRed: 0.949, green: 0.945, blue: 0.925, alpha: 1)
        webView.onMarkdownDrop = { [weak self] url in self?.open(url) }

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)

        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(webView)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 68),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 23), headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22), headerStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 26),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor), separator.leadingAnchor.constraint(equalTo: view.leadingAnchor), separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: separator.bottomAnchor), webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor), webView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor), footer.bottomAnchor.constraint(equalTo: view.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 23), statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        let footerLine = NSBox(); footerLine.boxType = .separator; footerLine.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerLine)
        NSLayoutConstraint.activate([footerLine.topAnchor.constraint(equalTo: footer.topAnchor), footerLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor), footerLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor)])

        render()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.49, alpha: 1)
        return button
    }

    @objc func openDocument() {
        let panel = NSOpenPanel()
        panel.title = "Abrir Markdown"
        panel.message = "Elige un archivo para leerlo con formato."
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            markdown = content
            currentFile = url
            view.window?.title = "\(url.lastPathComponent) — Lector MD"
            render()
            let lines = content.components(separatedBy: .newlines).count
            statusLabel.stringValue = "\(url.lastPathComponent)  ·  \(lines) líneas"
        } catch {
            showError("No se pudo abrir el archivo", detail: error.localizedDescription)
        }
    }

    private func render() {
        isDocumentReady = false
        setExportButtonsEnabled(false)
        webView.loadHTMLString(DocumentOutput.html(MarkdownDocument(markdown), fileName: currentFile?.lastPathComponent), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let currentFile else { return }
        isDocumentReady = true
        setExportButtonsEnabled(true)
        statusLabel.stringValue = "\(currentFile.lastPathComponent)  ·  Listo para exportar"
    }

    private func setExportButtonsEnabled(_ enabled: Bool) {
        exportButtons.forEach { $0.isEnabled = enabled }
    }

    @objc private func exportPDF() {
        guard currentFile != nil, isDocumentReady else { return }
        let panel = NSSavePanel()
        panel.title = "Guardar como PDF"
        panel.nameFieldStringValue = currentFile!.deletingPathExtension().lastPathComponent + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        setExportButtonsEnabled(false)
        statusLabel.stringValue = "Preparando PDF…"
        webView.evaluateJavaScript(DocumentOutput.pdfStyleScript) { [weak self] _, styleError in
            guard let self else { return }
            if let styleError {
                self.setExportButtonsEnabled(self.isDocumentReady)
                self.showError("No se pudo preparar el PDF", detail: styleError.localizedDescription)
                return
            }
            self.webView.evaluateJavaScript(DocumentOutput.pdfMetricsScript) { [weak self] metricsValue, _ in
                guard let self else { return }
                let metrics = PDFPageComposer.metrics(from: metricsValue)
                self.statusLabel.stringValue = "Creando PDF…"
                self.webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
                    guard let self else { return }
                    self.webView.evaluateJavaScript(DocumentOutput.removePDFStyleScript) { [weak self] _, _ in
                        guard let self else { return }
                        self.finishPDFExport(result, metrics: metrics, to: url)
                    }
                }
            }
        }
    }

    private func finishPDFExport(_ result: Result<Data, Error>, metrics: PDFPageComposer.Metrics?, to url: URL) {
        switch result {
        case .failure(let error):
            setExportButtonsEnabled(isDocumentReady)
            showError("No se pudo crear el PDF", detail: error.localizedDescription)
        case .success(let sourceData):
            statusLabel.stringValue = "Preparando páginas…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let output = try PDFPageComposer.compose(sourceData, metrics: metrics)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        defer { self.setExportButtonsEnabled(self.isDocumentReady) }
                        do {
                            try output.data.write(to: url, options: .atomic)
                            self.statusLabel.stringValue = "PDF guardado · \(url.lastPathComponent) · \(output.pageCount) páginas"
                        } catch {
                            self.showError("No se pudo guardar el PDF", detail: error.localizedDescription)
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.setExportButtonsEnabled(self.isDocumentReady)
                        self.showError("No se pudo crear el PDF", detail: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc private func printDocument() {
        guard currentFile != nil, isDocumentReady else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.printPanel.options.insert(.showsPaperSize)
        operation.run()
    }

    @objc private func exportDOCX() {
        guard currentFile != nil, isDocumentReady else { return }
        let panel = NSSavePanel()
        panel.title = "Guardar como Word"
        panel.nameFieldStringValue = currentFile!.deletingPathExtension().lastPathComponent + ".docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DocumentOutput.docx(MarkdownDocument(markdown), to: url)
            statusLabel.stringValue = "Word guardado · \(url.lastPathComponent)"
        } catch {
            showError("No se pudo guardar el DOCX", detail: error.localizedDescription)
        }
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var menuCreated = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.setActivationPolicy(.regular)
        ensureWindow()
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let url = urls.first {
            (window.contentViewController as? MainController)?.open(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func ensureWindow() {
        if window == nil {
            let controller = MainController()
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            newWindow.center()
            newWindow.title = "Lector MD"
            newWindow.minSize = NSSize(width: 760, height: 560)
            newWindow.contentViewController = controller
            newWindow.titlebarAppearsTransparent = false
            window = newWindow
        }
        if !menuCreated {
            makeMenu()
            menuCreated = true
        }
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Acerca de Lector MD", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Salir de Lector MD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "Archivo")
        let openItem = fileMenu.addItem(withTitle: "Abrir…", action: #selector(openDocument), keyEquivalent: "o")
        openItem.target = self
        fileItem.submenu = fileMenu
        NSApp.mainMenu = menu
    }

    @objc private func openDocument() {
        ensureWindow()
        (window?.contentViewController as? MainController)?.openDocument()
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
