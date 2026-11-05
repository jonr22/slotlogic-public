// MailPrint.swift
//
// Prints the message(s) selected in Apple Mail with PDF and image attachments
// laid out inline after the message text, the way Mail printed on Big Sur,
// but with every page of multi-page PDFs included.
//
// Usage:
//   open ~/Applications/MailPrint.app                  print the message(s) selected in Mail
//   .../MailPrint.app/Contents/MacOS/MailPrint x.eml   print a saved .eml / .emlx (for testing)

import AppKit
import ImageIO
import PDFKit
import WebKit

// MARK: - Settings

enum PDFRenderMode { case raster, vector }

enum Settings {
    /// Page margin on all four sides, in points (72 pt = 1 inch).
    static let margin: CGFloat = 36

    /// false: Big Sur behaviour. PDF pages flow straight on after the message text,
    ///        so a PDF page can be split across a page break.
    /// true:  each PDF page is shrunk to fit on one sheet; the first one moves to a
    ///        new sheet if it doesn't fit under the message text.
    static let keepPDFPagesWhole = false

    /// .raster always works. .vector keeps PDF text perfectly sharp but relies on
    /// WebKit drawing PDFs in <img> tags. Try it if you want; switch back if pages come out blank.
    static let pdfRenderMode: PDFRenderMode = .raster
    static let rasterDPI: CGFloat = 300

    /// Don't load remote images in HTML mail when printing.
    static let blockRemoteContent = false

    /// Stop after this many pages of any one PDF.
    static let maxPDFPages = 300
}

struct MailPrintError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Small helpers

enum Patterns {
    private static func make(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
    static let body = make(#"<body\b[^>]*>(.*?)(?:</body\s*>|\z)"#)
    static let head = make(#"<head\b[^>]*>.*?</head\s*>"#)
    static let style = make(#"<style\b[^>]*>.*?</style\s*>"#)
    static let docWrapper = make(#"<!doctype[^>]*>|</?html\b[^>]*>"#)
    static let unsafe = make(#"<script\b.*?</script\s*>|<meta\b[^>]*>|<base\b[^>]*>|<link\b[^>]*>"#)
    static let cid = make(#"cid:([^"'\s)>]+)"#)
    static let encodedWord = make(#"=\?([^?\s]+)\?([bq])\?([^?]*)\?="#)
}

func nsRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
    re.stringByReplacingMatches(in: s, range: nsRange(s), withTemplate: template)
}

func normalizeNewlines(_ s: String) -> String {
    s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func collapseWhitespace(_ s: String) -> String {
    s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x37
    case 0x61...0x66: return c - 0x57
    default: return nil
    }
}

func decodeString(_ data: Data, charset: String?) -> String {
    if let cs = charset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !cs.isEmpty {
        let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        if cf != CFStringEncoding(kCFStringEncodingInvalidId) {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(data: data, encoding: encoding) { return s }
        }
    }
    return String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .windowsCP1252)
        ?? String(decoding: data, as: UTF8.self)
}

func base64Decode(_ s: String) -> Data {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(s.utf8.count)
    for b in s.utf8 {
        switch b {
        case 65...90, 97...122, 48...57, 43, 47: bytes.append(b)
        default: break
        }
    }
    let remainder = bytes.count % 4
    if remainder == 1 { bytes.removeLast() } else if remainder > 0 { bytes += Array(repeating: 61, count: 4 - remainder) }
    return Data(base64Encoded: Data(bytes)) ?? Data()
}

func decodeQuotedPrintable(_ s: String) -> Data {
    let b = Array(s.utf8)
    var out = Data()
    out.reserveCapacity(b.count)
    var i = 0
    while i < b.count {
        let c = b[i]
        guard c == 0x3D else { out.append(c); i += 1; continue }        // "="
        var j = i + 1
        while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
        if j == b.count { i = j; continue }                               // trailing "="
        if b[j] == 0x0A { i = j + 1; continue }                           // soft line break
        if i + 2 < b.count, let h = hexValue(b[i + 1]), let l = hexValue(b[i + 2]) {
            out.append(h << 4 | l); i += 3; continue
        }
        out.append(c); i += 1
    }
    return out
}

func decodeQ(_ s: String) -> Data {
    let b = Array(s.utf8)
    var out = Data()
    var i = 0
    while i < b.count {
        if b[i] == 0x5F { out.append(0x20); i += 1 }                      // "_" is a space
        else if b[i] == 0x3D, i + 2 < b.count, let h = hexValue(b[i + 1]), let l = hexValue(b[i + 2]) {
            out.append(h << 4 | l); i += 3
        } else { out.append(b[i]); i += 1 }
    }
    return out
}

func percentDecode(_ s: String) -> Data {
    let b = Array(s.utf8)
    var out = Data()
    var i = 0
    while i < b.count {
        if b[i] == 0x25, i + 2 < b.count, let h = hexValue(b[i + 1]), let l = hexValue(b[i + 2]) {
            out.append(h << 4 | l); i += 3
        } else { out.append(b[i]); i += 1 }
    }
    return out
}

/// Decodes RFC 2047 encoded words ("=?utf-8?B?...?=") in header values.
func decodeEncodedWords(_ s: String) -> String {
    guard s.contains("=?") else { return s }
    let ns = s as NSString
    var result = ""
    var last = 0
    var pending = Data()
    var pendingCharset: String?
    func flush() {
        if let cs = pendingCharset { result += decodeString(pending, charset: cs) }
        pending = Data()
        pendingCharset = nil
    }
    for m in Patterns.encodedWord.matches(in: s, range: nsRange(s)) {
        var charset = ns.substring(with: m.range(at: 1)).lowercased()
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
        let text = ns.substring(with: m.range(at: 3))
        let bytes = ns.substring(with: m.range(at: 2)).lowercased() == "b" ? base64Decode(text) : decodeQ(text)
        let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
        if pendingCharset == charset && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pending.append(bytes)          // adjacent encoded words join with no space
        } else {
            flush()
            result += gap
            pending = bytes
            pendingCharset = charset
        }
        last = m.range.location + m.range.length
    }
    flush()
    result += ns.substring(from: last)
    return result
}

func normalizeCID(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("<") { t.removeFirst() }
    if t.hasSuffix(">") { t.removeLast() }
    return t.lowercased()
}

func normalizeCIDRef(_ s: String) -> String { normalizeCID(s.removingPercentEncoding ?? s) }

func formatDate(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
    s = collapseWhitespace(s)
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                   "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
        parser.dateFormat = format
        if let date = parser.date(from: s) {
            let out = DateFormatter()
            out.dateStyle = .long
            out.timeStyle = .short
            return out.string(from: date)
        }
    }
    return raw
}

// MARK: - MIME parsing

final class MIMEPart {
    let headers: [(name: String, value: String)]
    let body: String
    let contentType: String
    let typeParams: [String: String]
    let disposition: String?
    let dispositionParams: [String: String]
    private(set) var children: [MIMEPart] = []

    init(raw: String) {
        var headerText = ""
        var bodyText = raw
        if raw.hasPrefix("\n") {
            bodyText = String(raw.dropFirst())
        } else if let r = raw.range(of: "\n\n") {
            headerText = String(raw[..<r.lowerBound])
            bodyText = String(raw[r.upperBound...])
        } else if raw.contains(":") {
            headerText = raw
            bodyText = ""
        }
        let hdrs = MIMEPart.parseHeaders(headerText)
        headers = hdrs
        body = bodyText
        let ct = MIMEPart.parseParams(MIMEPart.find(hdrs, "content-type") ?? "text/plain")
        contentType = ct.value.isEmpty ? "text/plain" : ct.value
        typeParams = ct.params
        if let cd = MIMEPart.find(hdrs, "content-disposition") {
            let p = MIMEPart.parseParams(cd)
            disposition = p.value
            dispositionParams = p.params
        } else {
            disposition = nil
            dispositionParams = [:]
        }
        if contentType.hasPrefix("multipart/"), let boundary = typeParams["boundary"], !boundary.isEmpty {
            children = MIMEPart.splitMultipart(bodyText, boundary: boundary).map { MIMEPart(raw: $0) }
        }
    }

    func header(_ name: String) -> String? { MIMEPart.find(headers, name) }

    func decodedHeader(_ name: String) -> String? {
        header(name).map { collapseWhitespace(decodeEncodedWords($0)) }
    }

    var transferEncoding: String {
        header("content-transfer-encoding")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "7bit"
    }

    var filename: String? {
        guard let n = dispositionParams["filename"] ?? typeParams["name"] else { return nil }
        let decoded = decodeEncodedWords(n)
        return decoded.isEmpty ? nil : decoded
    }

    var contentID: String? {
        guard let id = header("content-id").map(normalizeCID), !id.isEmpty else { return nil }
        return id
    }

    var isPDF: Bool {
        if contentType == "application/pdf" || contentType == "application/x-pdf" { return true }
        let named = filename?.lowercased().hasSuffix(".pdf") == true
        return named && (contentType.hasPrefix("application/") || contentType == "binary/octet-stream")
    }

    var containsHTML: Bool { contentType == "text/html" || children.contains { $0.containsHTML } }

    func decodedData() -> Data {
        switch transferEncoding {
        case "base64": return base64Decode(body)
        case "quoted-printable": return decodeQuotedPrintable(body)
        default: return body.data(using: .isoLatin1) ?? Data(body.utf8)
        }
    }

    lazy var decodedText: String = {
        switch self.transferEncoding {
        case "base64", "quoted-printable": return decodeString(self.decodedData(), charset: self.typeParams["charset"])
        default: return self.body
        }
    }()

    static func find(_ headers: [(name: String, value: String)], _ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name.lowercased() == lower }?.value
    }

    static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                if !result.isEmpty {
                    result[result.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result.append((name: name, value: value))
            }
        }
        return result
    }

    /// Parses "type/subtype; key=value; key*=utf-8''..." including RFC 2231 continuations.
    static func parseParams(_ value: String) -> (value: String, params: [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if escaped { escaped = false; current.append(ch); continue }
            if ch == "\\" && inQuotes { escaped = true; current.append(ch); continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { segments.append(current); current = ""; continue }
            current.append(ch)
        }
        segments.append(current)

        let main = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var simple: [String: String] = [:]
        var extended: [String: [(index: Int, value: String, encoded: Bool)]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if let star = key.firstIndex(of: "*") {
                let base = String(key[..<star])
                let rest = key[key.index(after: star)...]
                let index = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                extended[base, default: []].append((index: index, value: val, encoded: key.hasSuffix("*")))
            } else {
                simple[key] = val
            }
        }
        for (base, pieces) in extended {
            var charset = "utf-8"
            var bytes = Data()
            for (i, piece) in pieces.sorted(by: { $0.index < $1.index }).enumerated() {
                var v = piece.value
                if piece.encoded {
                    if i == 0, let first = v.firstIndex(of: "'"),
                       let second = v[v.index(after: first)...].firstIndex(of: "'") {
                        charset = String(v[..<first])
                        v = String(v[v.index(after: second)...])
                    }
                    bytes.append(percentDecode(v))
                } else {
                    bytes.append(contentsOf: Array(v.utf8))
                }
            }
            simple[base] = decodeString(bytes, charset: charset)
        }
        return (main, simple)
    }

    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [Substring]?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(delimiter) {
                let rest = line.dropFirst(delimiter.count).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest == "--" {
                    if let c = current { parts.append(c.joined(separator: "\n")) }
                    if rest == "--" { current = nil; break }
                    current = []
                    continue
                }
            }
            current?.append(line)
        }
        if let c = current, !c.isEmpty { parts.append(c.joined(separator: "\n")) }
        return parts
    }
}

// MARK: - HTML layout

final class HTMLBuilder {
    private let dir: URL
    private let contentHeight: CGFloat
    private(set) var title = "Mail Message"
    private var counter = 0
    private var styles: [String] = []
    private var cidParts: [String: MIMEPart] = [:]
    private var referencedCIDs = Set<String>()
    private var written: [ObjectIdentifier: String] = [:]

    init(dir: URL, contentHeight: CGFloat) {
        self.dir = dir
        self.contentHeight = contentHeight
    }

    func build(sources: [String]) -> String {
        var sections: [String] = []
        for (index, source) in sources.enumerated() {
            let message = MIMEPart(raw: normalizeNewlines(source))
            if index == 0, let subject = message.decodedHeader("Subject"), !subject.isEmpty { title = subject }
            sections.append("<div class=\"mp-message\">\n\(renderMessage(message))\n</div>")
        }
        return document(body: sections.joined(separator: "\n"))
    }

    private func renderMessage(_ message: MIMEPart) -> String {
        prepareCIDs(message)
        var blocks = [headerBlock(message)]
        render(message, into: &blocks)
        return blocks.joined(separator: "\n")
    }

    // Find images referenced from HTML via cid: so they aren't printed twice.
    private func prepareCIDs(_ message: MIMEPart) {
        for leaf in leaves(of: message) {
            if let cid = leaf.contentID { cidParts[cid] = leaf }
            if leaf.contentType == "text/html" {
                let html = leaf.decodedText
                let ns = html as NSString
                for m in Patterns.cid.matches(in: html, range: nsRange(html)) {
                    referencedCIDs.insert(normalizeCIDRef(ns.substring(with: m.range(at: 1))))
                }
            }
        }
    }

    private func leaves(of part: MIMEPart) -> [MIMEPart] {
        part.children.isEmpty ? [part] : part.children.flatMap { leaves(of: $0) }
    }

    private func render(_ part: MIMEPart, into blocks: inout [String]) {
        let type = part.contentType
        guard type.hasPrefix("multipart/") else { renderLeaf(part, into: &blocks); return }
        switch type.dropFirst("multipart/".count) {
        case "alternative":
            let best = part.children.last(where: { $0.containsHTML })
                ?? part.children.last(where: { $0.contentType == "text/plain" })
                ?? part.children.last
            if let best { render(best, into: &blocks) }
        case "related":
            let start = part.typeParams["start"].map(normalizeCID)
            let root = part.children.first(where: { start != nil && $0.contentID == start }) ?? part.children.first
            if let root { render(root, into: &blocks) }
            for child in part.children where child !== root { render(child, into: &blocks) }
        case "signed":
            if let first = part.children.first { render(first, into: &blocks) }
        default:
            for child in part.children { render(child, into: &blocks) }
        }
    }

    private func renderLeaf(_ part: MIMEPart, into blocks: inout [String]) {
        let type = part.contentType
        let isAttachment = part.disposition == "attachment" && part.filename != nil

        if type == "message/rfc822" {
            let inner = MIMEPart(raw: normalizeNewlines(part.decodedText))
            blocks.append("<div class=\"mp-forwarded\">\n\(renderMessage(inner))\n</div>")
        } else if type == "text/html" && !isAttachment {
            blocks.append(htmlBlock(part.decodedText))
        } else if type == "text/plain" && !isAttachment {
            blocks.append(textBlock(part))
        } else if part.isPDF {
            blocks.append(pdfBlock(part))
        } else if type.hasPrefix("image/") {
            if let cid = part.contentID, referencedCIDs.contains(cid) { return }
            blocks.append(imageBlock(part))
        } else if ["application/pkcs7-signature", "application/x-pkcs7-signature",
                   "application/pgp-signature"].contains(type) {
            return
        } else {
            blocks.append(placeholder(part.filename ?? type))
        }
    }

    private func htmlBlock(_ html: String) -> String {
        let (style, body) = splitHTML(html)
        if !style.isEmpty { styles.append(style) }
        return "<div class=\"mp-part mp-html\">\(replaceCIDs(body))</div>"
    }

    private func splitHTML(_ html: String) -> (styles: String, body: String) {
        let ns = html as NSString
        var head = ""
        var body = html
        if let m = Patterns.body.firstMatch(in: html, range: nsRange(html)) {
            head = ns.substring(to: m.range.location)
            body = ns.substring(with: m.range(at: 1))
        } else if let m = Patterns.head.firstMatch(in: html, range: nsRange(html)) {
            head = ns.substring(with: m.range)
            body = ns.replacingCharacters(in: m.range, with: "")
        }
        body = replace(Patterns.docWrapper, in: body, with: "")
        body = replace(Patterns.unsafe, in: body, with: "")
        let hs = head as NSString
        let css = Patterns.style.matches(in: head, range: nsRange(head))
            .map { hs.substring(with: $0.range) }
            .joined(separator: "\n")
        return (css, body)
    }

    private func replaceCIDs(_ html: String) -> String {
        let ns = NSMutableString(string: html)
        for m in Patterns.cid.matches(in: html, range: nsRange(html)).reversed() {
            let key = normalizeCIDRef(ns.substring(with: m.range(at: 1)))
            guard let part = cidParts[key], let file = writeAttachment(part) else { continue }
            ns.replaceCharacters(in: m.range, with: file)
        }
        return ns as String
    }

    private func textBlock(_ part: MIMEPart) -> String {
        var text = part.decodedText
        if part.typeParams["format"]?.lowercased() == "flowed" {
            text = unflow(text, delsp: part.typeParams["delsp"]?.lowercased() == "yes")
        }
        text = text.trimmingCharacters(in: .newlines)
        return "<div class=\"mp-part mp-text\">\(escapeHTML(text))</div>"
    }

    private func unflow(_ text: String, delsp: Bool) -> String {
        var out = ""
        var paragraph = ""
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if line.hasPrefix(" ") { line.removeFirst() }               // space-stuffing
            if line.hasSuffix(" ") && line != "-- " {
                if delsp { line.removeLast() }
                paragraph += line
            } else {
                out += paragraph + line + "\n"
                paragraph = ""
            }
        }
        return out + paragraph
    }

    private func pdfBlock(_ part: MIMEPart) -> String {
        let name = part.filename ?? "Attachment.pdf"
        let data = part.decodedData()
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else {
            return placeholder(name, note: "couldn’t be read")
        }
        if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        guard doc.isUnlocked else { return placeholder(name, note: "password-protected") }

        var vectorDoc: PDFDocument?
        if Settings.pdfRenderMode == .vector {
            vectorDoc = PDFDocument(data: data)
            if vectorDoc?.isLocked == true { _ = vectorDoc?.unlock(withPassword: "") }
        }

        counter += 1
        let base = "pdf\(counter)"
        let pageCount = min(doc.numberOfPages, Settings.maxPDFPages)
        var images: [String] = []
        for i in 1...pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = displaySize(of: page)
            let file: String? = autoreleasepool {
                switch Settings.pdfRenderMode {
                case .raster: return rasterize(page, size: size, name: "\(base)-\(i).png")
                case .vector: return extractPage(vectorDoc, index: i - 1, name: "\(base)-\(i).pdf")
                }
            }
            guard let file else { continue }
            images.append("<img class=\"mp-pdfpage\" src=\"\(file)\" width=\"\(Int(size.width.rounded()))\" "
                + "height=\"\(Int(size.height.rounded()))\" alt=\"\(escapeHTML(name))\">")
        }
        var html = "<div class=\"mp-pdf\">\(images.joined())</div>"
        if doc.numberOfPages > pageCount {
            html += placeholder(name, note: "only the first \(pageCount) pages were printed")
        }
        return html
    }

    private func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        return rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    private func rasterize(_ page: CGPDFPage, size: CGSize, name: String) -> String? {
        let scale = Settings.rasterDPI / 72
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? name : nil
    }

    private func extractPage(_ doc: PDFDocument?, index: Int, name: String) -> String? {
        guard let doc, let page = doc.page(at: index)?.copy() as? PDFPage else { return nil }
        let single = PDFDocument()
        single.insert(page, at: 0)
        return single.write(to: dir.appendingPathComponent(name)) ? name : nil
    }

    private func imageBlock(_ part: MIMEPart) -> String {
        guard let file = writeAttachment(part) else { return placeholder(part.filename ?? part.contentType) }
        return "<img class=\"mp-image\" src=\"\(file)\" alt=\"\(escapeHTML(part.filename ?? ""))\">"
    }

    private func writeAttachment(_ part: MIMEPart) -> String? {
        if let existing = written[ObjectIdentifier(part)] { return existing }
        counter += 1
        let name = "att\(counter).\(fileExtension(for: part))"
        do { try part.decodedData().write(to: dir.appendingPathComponent(name)) } catch { return nil }
        written[ObjectIdentifier(part)] = name
        return name
    }

    private func fileExtension(for part: MIMEPart) -> String {
        if let ext = part.filename.map({ ($0 as NSString).pathExtension.lowercased() }),
           !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return ext
        }
        let sub = part.contentType.split(separator: "/").last.map(String.init) ?? "bin"
        switch sub {
        case "jpeg", "pjpeg": return "jpg"
        case "svg+xml": return "svg"
        case "x-png": return "png"
        default: return sub.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? sub : "bin"
        }
    }

    private func placeholder(_ name: String, note: String? = nil) -> String {
        let suffix = note.map { " — \($0)" } ?? ""
        return "<div class=\"mp-attachment\">📎 \(escapeHTML(name + suffix))</div>"
    }

    private func headerBlock(_ message: MIMEPart) -> String {
        var rows = ""
        for label in ["From", "Subject", "Date", "To", "Cc", "Reply-To"] {
            guard var value = message.decodedHeader(label), !value.isEmpty else { continue }
            if label == "Date" { value = formatDate(value) }
            rows += "<tr class=\"mp-h-\(label.lowercased())\"><th>\(label):</th><td>\(escapeHTML(value))</td></tr>"
        }
        return "<table class=\"mp-headers\">\(rows)</table><hr class=\"mp-rule\">"
    }

    private func document(body: String) -> String {
        let csp = Settings.blockRemoteContent
            ? "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; font-src file: data:\">"
            : ""
        let wholePages = Settings.keepPDFPagesWhole
            ? ".mp-pdfpage { break-inside: avoid; page-break-inside: avoid; width: auto; height: auto; max-height: \(Int(contentHeight) - 4)px; }"
            : ""
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">\(csp)
        <style>
        html, body { margin: 0; padding: 0; background: #fff; }
        body { font: 12px Helvetica, Arial, sans-serif; color: #000; -webkit-print-color-adjust: exact; }
        </style>
        \(styles.joined(separator: "\n"))
        <style>
        .mp-message + .mp-message { break-before: page; page-break-before: always; }
        .mp-headers { font: 12px Helvetica, Arial, sans-serif; color: #000; border-collapse: collapse; margin: 0; }
        .mp-headers th { text-align: right; vertical-align: top; font-weight: bold; padding: 1px 8px 1px 0; white-space: nowrap; }
        .mp-headers td { text-align: left; vertical-align: top; padding: 1px 0; }
        .mp-h-subject td { font-weight: bold; }
        .mp-rule { border: 0; border-top: 1px solid #c8c8c8; margin: 8px 0 14px; }
        .mp-text { white-space: pre-wrap; word-wrap: break-word; font: 12px Helvetica, Arial, sans-serif; }
        .mp-pdf { margin: 10px 0; }
        .mp-pdfpage, .mp-image { display: block; max-width: 100%; height: auto; margin: 0 0 8px 0; }
        .mp-attachment { margin: 8px 0; color: #555; font: 11px Helvetica, Arial, sans-serif; }
        .mp-forwarded { margin: 12px 0; padding-left: 10px; border-left: 2px solid #ccc; }
        \(wholePages)
        </style>
        </head><body>
        \(body)
        </body></html>
        """
    }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailPrint-" + UUID().uuidString, isDirectory: true)
    private var pdfURL: URL { workDir.appendingPathComponent("print.pdf") }
    private var webView: WKWebView?
    private var window: NSWindow?
    private var layoutInfo = NSPrintInfo()
    private var jobTitle = "Mail Message"
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let sources = try loadSources()
            layoutInfo = makeLayoutInfo()
            let width = layoutInfo.paperSize.width - layoutInfo.leftMargin - layoutInfo.rightMargin
            let height = layoutInfo.paperSize.height - layoutInfo.topMargin - layoutInfo.bottomMargin
            let builder = HTMLBuilder(dir: workDir, contentHeight: height)
            let html = builder.build(sources: sources)
            jobTitle = builder.title
            let htmlURL = workDir.appendingPathComponent("message.html")
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            load(htmlURL, width: width, height: height)
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Getting the message

    private func loadSources() throws -> [String] {
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !paths.isEmpty {
            return try paths.map { try readMessageFile(URL(fileURLWithPath: $0)) }
        }
        let script = """
        tell application "Mail"
            set msgs to selection
            set out to {}
            repeat with m in msgs
                set end of out to (source of m)
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            var message = (error?[NSAppleScript.errorMessage] as? String) ?? "Couldn’t get the message from Mail."
            if (error?[NSAppleScript.errorNumber] as? Int) == -1743 {
                message += "\n\nAllow MailPrint to control Mail in System Settings › Privacy & Security › Automation."
            }
            throw MailPrintError(message)
        }
        var sources: [String] = []
        if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let s = result.atIndex(i)?.stringValue, !s.isEmpty { sources.append(s) }
            }
        }
        guard !sources.isEmpty else { throw MailPrintError("Select a message in Mail first.") }
        return sources
    }

    private func readMessageFile(_ url: URL) throws -> String {
        var data = try Data(contentsOf: url)
        // .emlx files start with a byte count line, then the message, then a plist.
        if url.pathExtension.lowercased() == "emlx", let newline = data.firstIndex(of: 0x0A),
           let length = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
            let start = newline + 1
            data = data.subdata(in: start..<min(data.count, start + length))
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Laying out pages

    private func makeLayoutInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = Settings.margin
        info.bottomMargin = Settings.margin
        info.leftMargin = Settings.margin
        info.rightMargin = Settings.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    private func load(_ url: URL, width: CGFloat, height: CGFloat) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let web = WKWebView(frame: frame, configuration: config)
        web.navigationDelegate = self
        // Off-screen window: WebKit needs one to print, but nobody needs to see it.
        let win = NSWindow(contentRect: frame.offsetBy(dx: -30000, dy: -30000),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        win.orderFrontRegardless()
        webView = web
        window = win
        web.loadFileURL(url, allowingReadAccessTo: workDir)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in layOutPages() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    /// Paginates the message into a PDF exactly as it will print.
    private func layOutPages() {
        guard let webView, let window else { return }
        let info = layoutInfo.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdfURL
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: self,
                    didRun: #selector(pagesDidLayOut(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func pagesDidLayOut(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [self] in
            guard success, let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
                fail("Couldn’t lay out the message for printing.")
                return
            }
            showPrintPanel(for: doc)
        }
    }

    // MARK: Printing

    private func showPrintPanel(for doc: PDFDocument) {
        window?.orderOut(nil)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else {
            fail("Couldn’t start the print job.")
            return
        }
        op.jobTitle = jobTitle
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPreview])
        bringToFront()
        op.run()
        finish()
    }

    private func bringToFront() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func fail(_ message: String) {
        bringToFront()
        let alert = NSAlert()
        alert.messageText = "MailPrint couldn’t print this message"
        alert.informativeText = message
        alert.runModal()
        finish()
    }

    private func finish() {
        try? FileManager.default.removeItem(at: workDir)
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point (keep at the end of the file)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    withExtendedLifetime(controller) { app.run() }
}
