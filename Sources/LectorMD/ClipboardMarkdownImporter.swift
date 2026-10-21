import AppKit
import WebKit

@MainActor
enum ClipboardMarkdownSource {
    case html(String, fallbackText: String?)
    case plainText(String)

    static func read(from pasteboard: NSPasteboard = .general) -> ClipboardMarkdownSource? {
        let plainText = pasteboard.string(forType: .string)

        if let html = pasteboard.string(forType: .html),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .html(html, fallbackText: plainText)
        }
        if let data = pasteboard.data(forType: .html),
           let html = String(data: data, encoding: .utf8),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .html(html, fallbackText: plainText)
        }

        if let rtf = pasteboard.data(forType: .rtf) {
            do {
                let attributed = try NSAttributedString(
                    data: rtf,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
                let range = NSRange(location: 0, length: attributed.length)
                let html = try attributed.data(
                    from: range,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
                )
                if let html = String(data: html, encoding: .utf8),
                   !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .html(html, fallbackText: plainText)
                }
            } catch {
                // Fall back to plain text if AppKit cannot read or convert the RTF.
            }
        }

        guard let plainText,
              !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return .plainText(plainText)
    }
}

enum PlainTextMarkdownConverter {
    static func convert(_ source: String) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [String] = []
        var paragraphLines: [String] = []
        var listLines: [String] = []
        var codeLines: [String] = []
        var codeFence: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !paragraph.isEmpty { blocks.append(paragraph) }
            paragraphLines.removeAll()
        }

        func flushList() {
            guard !listLines.isEmpty else { return }
            blocks.append(listLines.joined(separator: "\n"))
            listLines.removeAll()
        }

        func flushProse() {
            flushParagraph()
            flushList()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let activeCodeFence = codeFence {
                codeLines.append(line)
                if trimmed.hasPrefix(activeCodeFence) {
                    blocks.append(codeLines.joined(separator: "\n"))
                    codeLines.removeAll()
                    codeFence = nil
                }
                continue
            }

            if trimmed.hasPrefix("~~~") || trimmed.hasPrefix(String(repeating: "\u{0060}", count: 3)) {
                flushProse()
                codeFence = trimmed.hasPrefix("~~~") ? "~~~" : String(repeating: "\u{0060}", count: 3)
                codeLines = [trimmed]
                continue
            }

            guard !trimmed.isEmpty else {
                flushProse()
                continue
            }

            if let bullet = bulletItem(trimmed) {
                flushParagraph()
                listLines.append("- \(bullet)")
                continue
            }
            if isListItem(trimmed) {
                flushParagraph()
                listLines.append(trimmed)
                continue
            }

            flushList()
            if isMarkdownBlock(trimmed) {
                flushParagraph()
                blocks.append(trimmed)
            } else {
                paragraphLines.append(trimmed)
            }
        }

        if !codeLines.isEmpty { blocks.append(codeLines.joined(separator: "\n")) }
        flushProse()
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletItem(_ line: String) -> String? {
        guard let range = line.range(of: #"^[•◦▪‣∙●]\s*(.+)$"#, options: .regularExpression) else { return nil }
        return String(line[range])
            .replacingOccurrences(of: #"^[•◦▪‣∙●]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}[-+*]\s+\S"#, options: .regularExpression) != nil ||
            line.range(of: #"^\s{0,3}\d+[.)]\s+\S"#, options: .regularExpression) != nil
    }

    private static func isMarkdownBlock(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}#{1,6}\s+\S"#, options: .regularExpression) != nil ||
            line.range(of: #"^\s{0,3}>"#, options: .regularExpression) != nil ||
            line.range(of: #"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#, options: .regularExpression) != nil
    }
}

private enum ClipboardHTMLImportError: LocalizedError {
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .noReadableText:
            return "El portapapeles no contiene texto que se pueda convertir."
        }
    }
}

@MainActor
final class ClipboardHTMLToMarkdownConverter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: ((Result<String, Error>) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func convert(_ html: String, completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        webView.loadHTMLString(Self.safeDocument(from: html), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.conversionScript) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let markdown = result as? String,
                  !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.finish(.failure(ClipboardHTMLImportError.noReadableText))
                return
            }
            self.finish(.success(markdown))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }

    private static func safeDocument(from source: String) -> String {
        var fragment = source
        let removedElements = ["script", "style", "iframe", "object", "embed", "svg", "math", "noscript", "video", "audio", "canvas"]
        for tag in removedElements {
            fragment = replacing(#"<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)\s*>"#, in: fragment)
            fragment = replacing(#"</?\#(tag)\b[^>]*>"#, in: fragment)
        }
        fragment = replacing(#"<!--[\s\S]*?-->"#, in: fragment)
        fragment = replacing(#"<!doctype[^>]*>"#, in: fragment)
        fragment = replacing(#"</?(?:html|head|body)\b[^>]*>"#, in: fragment)
        fragment = replacing(#"<(?:meta|link|base)\b[^>]*>"#, in: fragment)
        fragment = replacing(#"\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, in: fragment)
        fragment = replacing(#"\s+(?:src|srcset|background|poster|action|formaction)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, in: fragment)
        fragment = replacing(#"\s+style\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, in: fragment)
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(fragment)</body></html>"
    }

    private static func replacing(_ pattern: String, in source: String) -> String {
        source.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static let conversionScript = #"""
    (() => {
      const tick = String.fromCharCode(96);
      const brToken = "\u0001";
      const blockTags = new Set(["body", "div", "article", "section", "header", "footer", "main", "nav", "aside", "table", "tbody", "thead", "tfoot", "tr", "td", "th", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "hr"]);
      const ignoredTags = new Set(["script", "style", "head", "noscript", "iframe", "object", "embed", "svg", "math"]);

      function inline(node) {
        if (node.nodeType === Node.TEXT_NODE) return (node.nodeValue || "").replace(/\u00a0/g, " ");
        if (node.nodeType !== Node.ELEMENT_NODE) return "";
        const tag = node.tagName.toLowerCase();
        if (ignoredTags.has(tag)) return "";
        if (tag === "br") return brToken;
        if (tag === "img") return node.getAttribute("alt") || "";
        const content = Array.from(node.childNodes).map(inline).join("");
        if ((tag === "strong" || tag === "b") && content.trim()) return "**" + content.trim() + "**";
        if ((tag === "em" || tag === "i") && content.trim()) return "*" + content.trim() + "*";
        if (tag === "del" || tag === "s" || tag === "strike") return "~~" + content.trim() + "~~";
        if (tag === "code" && content.trim()) return tick + content.trim().split(tick).join("\\" + tick) + tick;
        if (tag === "a") {
          const href = (node.getAttribute("href") || "").trim();
          const safeHref = /^(https?:|mailto:)/i.test(href) ? href : "";
          if (safeHref && content.trim()) {
            const escapedHref = safeHref.replace(/[()]/g, character => "\\" + character);
            return "[" + content.trim() + "](" + escapedHref + ")";
          }
        }
        return content;
      }

      function normalizedInline(node) {
        return inline(node)
          .replace(/[\s\u00a0]+/g, " ")
          .trim()
          .replace(new RegExp(brToken, "g"), "\n");
      }

      function headingLevel(element) {
        const tagMatch = element.tagName.toLowerCase().match(/^h([1-6])$/);
        if (tagMatch) return Number(tagMatch[1]);
        const classes = element.getAttribute("class") || "";
        const match = classes.match(/(?:mso)?heading[_\s-]*([1-6])/i);
        if (match) return Number(match[1]);
        return /\b(?:mso)?title\b/i.test(classes) ? 1 : 0;
      }

      function listMarkdown(list, depth) {
        const ordered = list.tagName.toLowerCase() === "ol";
        const parsedStart = Number.parseInt(list.getAttribute("start") || "1", 10);
        const start = Number.isFinite(parsedStart) ? parsedStart : 1;
        const items = Array.from(list.children).filter(child => child.tagName.toLowerCase() === "li");
        return items.map((item, index) => {
          let text = "";
          const nested = [];
          for (const child of Array.from(item.childNodes)) {
            if (child.nodeType === Node.ELEMENT_NODE && ["ul", "ol"].includes(child.tagName.toLowerCase())) {
              nested.push(listMarkdown(child, depth + 1));
            } else {
              text += inline(child);
            }
          }
          let content = text.replace(/[\s\u00a0]+/g, " ").trim().replace(new RegExp(brToken, "g"), " ");
          const marker = ordered ? String(start + index) + ". " : "- ";
          const line = "  ".repeat(depth) + marker + content;
          return [line, ...nested].filter(Boolean).join("\n");
        }).join("\n");
      }

      function renderChildren(parent) {
        const chunks = [];
        let pendingInline = "";
        const flushInline = () => {
          const value = pendingInline.replace(/[\s\u00a0]+/g, " ").trim().replace(new RegExp(brToken, "g"), "\n");
          if (value) chunks.push(value);
          pendingInline = "";
        };
        for (const child of Array.from(parent.childNodes)) {
          const tag = child.nodeType === Node.ELEMENT_NODE ? child.tagName.toLowerCase() : "";
          if (blockTags.has(tag)) {
            flushInline();
            const value = renderBlock(child);
            if (value) chunks.push(value);
          } else {
            pendingInline += inline(child);
          }
        }
        flushInline();
        return chunks.join("\n\n");
      }

      function renderBlock(node) {
        if (node.nodeType === Node.TEXT_NODE) {
          return (node.nodeValue || "").replace(/[\s\u00a0]+/g, " ").trim();
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return "";
        const tag = node.tagName.toLowerCase();
        if (ignoredTags.has(tag)) return "";
        if (tag === "ul" || tag === "ol") return listMarkdown(node, 0);
        if (tag === "pre") {
          const content = (node.textContent || "").replace(/\r\n?/g, "\n").replace(/\n+$/g, "");
          if (!content.trim()) return "";
          const fence = content.includes(tick.repeat(3)) ? "~~~" : tick.repeat(3);
          return fence + "\n" + content + "\n" + fence;
        }
        if (tag === "blockquote") {
          const content = renderChildren(node) || normalizedInline(node);
          return content.split("\n").map(line => line ? "> " + line : ">").join("\n");
        }
        if (tag === "hr") return "---";
        if (tag === "p" || /^h[1-6]$/.test(tag)) {
          const content = normalizedInline(node);
          if (!content) return "";
          const level = headingLevel(node);
          if (level) return "#".repeat(level) + " " + content;
          if (/MsoListParagraph/i.test(node.getAttribute("class") || "")) {
            const numbered = content.match(/^(\d+[.)])\s+(.+)$/);
            if (numbered) return numbered[1] + " " + numbered[2];
            const item = content.replace(/^[•◦▪‣∙●]\s*/, "");
            return "- " + item;
          }
          return content;
        }
        if (blockTags.has(tag)) return renderChildren(node);
        return normalizedInline(node);
      }

      const result = renderChildren(document.body);
      return result
        .replace(/\r\n?/g, "\n")
        .replace(/[ \t]+\n/g, "\n")
        .replace(/\n[ \t]+/g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .trim();
    })()
    """#
}
