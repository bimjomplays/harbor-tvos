import Foundation
import Compression

// Stage 13 eBooks: upstream reads an EPUB with lib/unzip.ts (DecompressionStream) and
// lib/ebook/epub.ts (DOMParser). JavaScriptCore has neither, so the TV does both natively here:
// a ZIP reader over the Compression framework's raw DEFLATE, a small forgiving XML/HTML tree
// builder, and a line-for-line port of parseEpub / readEpubChapter on top of it. What comes out
// is the same as upstream's: chapter paths (with the nav fragment), titles, and each chapter's
// plain text with blank lines between blocks. The engine then applies upstream's cleanSourceText
// and paragraph split (engine/ebook.ts openChapter), so progress lines match the desktop's.

enum EPUBError: LocalizedError {
    case notZip, noPackage, unreadablePackage
    var errorDescription: String? {
        switch self {
        case .notZip: return "Not a valid zip file"
        case .noPackage: return "EPUB package document is missing"
        case .unreadablePackage: return "EPUB package document could not be read"
        }
    }
}

// MARK: - ZIP (lib/unzip.ts)

enum EPUBZip {
    /// Every file entry in the archive (directories skipped); stored and DEFLATE entries only,
    /// as upstream's unzip. The central directory's uncompressed size sizes each output.
    static func entries(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        let n = b.count
        guard n >= 22 else { throw EPUBError.notZip }
        func u16(_ i: Int) -> Int { i + 1 < n ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < n ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }
        var eocd = -1
        var i = n - 22
        while i >= 0 {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw EPUBError.notZip }
        let count = u16(eocd + 10)
        var cd = u32(eocd + 16)
        var out: [String: Data] = [:]
        // A real EPUB has a few hundred files and tens of MB; a crafted archive must not be able to
        // inflate its way past tvOS's memory limit through many entries (review 21).
        guard count <= 10_000 else { throw EPUBError.notZip }
        var totalOut = 0
        let totalBudget = 300 * 1024 * 1024
        for _ in 0..<count {
            guard cd + 46 <= n, u32(cd) == 0x0201_4b50 else { break }
            let method = u16(cd + 10)
            let compSize = u32(cd + 20)
            let size = u32(cd + 24)
            let fnLen = u16(cd + 28)
            let extraLen = u16(cd + 30)
            let commentLen = u16(cd + 32)
            let localOff = u32(cd + 42)
            guard cd + 46 + fnLen <= n else { break }
            let name = String(decoding: b[(cd + 46)..<(cd + 46 + fnLen)], as: UTF8.self)
            if !name.hasSuffix("/"), localOff + 30 <= n {
                let start = localOff + 30 + u16(localOff + 26) + u16(localOff + 28)
                let end = start + compSize
                if start <= end, end <= n {
                    let claimed = method == 8 ? size : compSize
                    if totalOut + claimed > totalBudget { break }
                    if method == 8 {
                        if let d = inflate(Array(b[start..<end]), size: size) { out[name] = d; totalOut += d.count }
                    } else if method == 0 {
                        out[name] = Data(b[start..<end]); totalOut += compSize
                    }
                }
            }
            cd += 46 + fnLen + extraLen + commentLen
        }
        return out
    }

    /// Raw DEFLATE (COMPRESSION_ZLIB is headerless DEFLATE, RFC 1951).
    private static func inflate(_ src: [UInt8], size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard !src.isEmpty, size < 256 * 1024 * 1024 else { return nil }
        var dst = [UInt8](repeating: 0, count: size)
        let written = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }
}

// MARK: - A forgiving document tree (what epub.ts asks of DOMParser)

final class EPUBNode {
    enum Kind { case document, element, text }
    let kind: Kind
    /// Lowercased local name (after any prefix); "" for text.
    let localName: String
    /// Attribute names as written (lowercased), with their decoded values.
    let attributes: [(name: String, value: String)]
    /// Text and CDATA content.
    let text: String
    private(set) var children: [EPUBNode] = []
    private(set) weak var parent: EPUBNode?

    init(kind: Kind, localName: String = "", attributes: [(name: String, value: String)] = [], text: String = "") {
        self.kind = kind
        self.localName = localName
        self.attributes = attributes
        self.text = text
    }

    func append(_ child: EPUBNode) {
        child.parent = self
        children.append(child)
    }

    var isElement: Bool { kind == .element }

    /// getAttribute, case-insensitive (HTML documents lowercase attribute names anyway).
    func attr(_ name: String) -> String? {
        let key = name.lowercased()
        return attributes.first { $0.name == key }?.value
    }

    /// Element.children.
    var elementChildren: [EPUBNode] { children.filter(\.isElement) }

    /// getElementsByTagName("*"): every element below this node, in document order.
    var descendants: [EPUBNode] {
        var out: [EPUBNode] = []
        func walk(_ n: EPUBNode) {
            for c in n.children where c.kind == .element {
                out.append(c)
                walk(c)
            }
        }
        walk(self)
        return out
    }

    /// Node.textContent: every text and CDATA descendant, concatenated.
    var textContent: String {
        if kind == .text { return text }
        var out = ""
        func walk(_ n: EPUBNode) {
            for c in n.children {
                if c.kind == .text { out += c.text } else { walk(c) }
            }
        }
        walk(self)
        return out
    }

    /// document.documentElement.
    var documentElement: EPUBNode? { kind == .document ? children.first(where: \.isElement) : self }

    /// The elements with this local name, in document order (epub.ts `elements`).
    func elements(_ name: String) -> [EPUBNode] {
        let key = name.lowercased()
        return descendants.filter { $0.localName == key }
    }

    /// The first of them (epub.ts `element`).
    func element(_ name: String) -> EPUBNode? {
        let key = name.lowercased()
        var found: EPUBNode?
        func walk(_ n: EPUBNode) {
            for c in n.children where c.kind == .element {
                if found != nil { return }
                if c.localName == key { found = c; return }
                walk(c)
            }
        }
        walk(self)
        return found
    }
}

/// Parses XML, XHTML and tag-soup HTML into EPUBNodes. It never fails: unknown entities stay as
/// written, stray end tags are ignored, unclosed elements close at the end, and a new block closes
/// an open paragraph the way an HTML parser would. That covers what epub.ts gets from DOMParser's
/// XML parse with its HTML fallback.
enum EPUBMarkup {
    private static let voidElements: Set<String> = ["br", "img", "hr", "meta", "link", "input", "col", "area", "base", "embed", "param", "source", "track", "wbr"]
    private static let rawText: Set<String> = ["script", "style"]
    private static let closesParagraph: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "blockquote", "pre", "section", "article", "header", "footer", "aside", "nav", "hr", "dl", "figure"]

    static func parse(_ data: Data) -> EPUBNode {
        var bytes = [UInt8](data)
        // epub.ts decode(): UTF-16 by its byte-order mark, UTF-8 otherwise.
        if bytes.count >= 2, (bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff) {
            let enc: String.Encoding = bytes[0] == 0xff ? .utf16LittleEndian : .utf16BigEndian
            let s = String(data: Data(bytes.dropFirst(2)), encoding: enc) ?? ""
            bytes = Array(s.utf8)
        } else if bytes.count >= 3, bytes[0] == 0xef, bytes[1] == 0xbb, bytes[2] == 0xbf {
            bytes.removeFirst(3)
        }
        var parser = Parser(bytes)
        return parser.run()
    }

    private struct Parser {
        let s: [UInt8]
        var i = 0
        let root: EPUBNode
        var stack: [EPUBNode]

        init(_ s: [UInt8]) {
            self.s = s
            let r = EPUBNode(kind: .document)
            root = r
            stack = [r]
        }

        mutating func run() -> EPUBNode {
            let n = s.count
            var textStart = 0
            while i < n {
                guard s[i] == 0x3c /* < */ else { i += 1; continue }
                if textStart < i { addText(textStart, i, decode: true) }
                if starts("<!--") {
                    i = find("-->", from: i + 4).map { $0 + 3 } ?? n
                } else if starts("<![CDATA[") {
                    let end = find("]]>", from: i + 9) ?? n
                    addText(i + 9, end, decode: false)
                    i = min(n, end + 3)
                } else if starts("<!") {
                    i = skipDeclaration(i + 2)
                } else if starts("<?") {
                    i = find("?>", from: i + 2).map { $0 + 2 } ?? n
                } else if starts("</") {
                    closeTag()
                } else if i + 1 < n, isNameStart(s[i + 1]) {
                    openTag()
                } else {
                    // A lone "<" in text.
                    addTextString("<")
                    i += 1
                }
                textStart = i
            }
            if textStart < n { addText(textStart, n, decode: true) }
            return root
        }

        func starts(_ lit: String) -> Bool {
            let u = Array(lit.utf8)
            guard i + u.count <= s.count else { return false }
            for k in 0..<u.count where s[i + k] != u[k] { return false }
            return true
        }

        func find(_ lit: String, from: Int) -> Int? {
            let u = Array(lit.utf8)
            guard !u.isEmpty, from <= s.count - u.count else { return nil }
            var j = from
            while j <= s.count - u.count {
                if s[j] == u[0] {
                    var ok = true
                    for k in 1..<u.count where s[j + k] != u[k] { ok = false; break }
                    if ok { return j }
                }
                j += 1
            }
            return nil
        }

        /// <!DOCTYPE …> including an internal subset in brackets.
        func skipDeclaration(_ from: Int) -> Int {
            var j = from
            var depth = 0
            while j < s.count {
                switch s[j] {
                case 0x5b: depth += 1
                case 0x5d: depth = max(0, depth - 1)
                case 0x3e where depth == 0: return j + 1
                default: break
                }
                j += 1
            }
            return s.count
        }

        func isNameStart(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x3a || c >= 0x80 }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c }

        mutating func readName() -> String {
            let start = i
            while i < s.count, !isSpace(s[i]), s[i] != 0x3e, s[i] != 0x2f, s[i] != 0x3d { i += 1 }
            return String(decoding: s[start..<i], as: UTF8.self)
        }

        static func local(_ qname: String) -> String {
            let lower = qname.lowercased()
            if let colon = lower.lastIndex(of: ":") { return String(lower[lower.index(after: colon)...]) }
            return lower
        }

        mutating func openTag() {
            i += 1
            let qname = readName()
            var attrs: [(name: String, value: String)] = []
            var selfClosing = false
            while i < s.count {
                while i < s.count, isSpace(s[i]) { i += 1 }
                guard i < s.count else { break }
                if s[i] == 0x3e { i += 1; break }
                if s[i] == 0x2f {
                    i += 1
                    if i < s.count, s[i] == 0x3e { selfClosing = true; i += 1; break }
                    continue
                }
                let aname = readName()
                if aname.isEmpty { i += 1; continue }
                while i < s.count, isSpace(s[i]) { i += 1 }
                var value = ""
                if i < s.count, s[i] == 0x3d {
                    i += 1
                    while i < s.count, isSpace(s[i]) { i += 1 }
                    if i < s.count, s[i] == 0x22 || s[i] == 0x27 {
                        let q = s[i]
                        i += 1
                        let start = i
                        while i < s.count, s[i] != q { i += 1 }
                        value = String(decoding: s[start..<min(i, s.count)], as: UTF8.self)
                        i = min(s.count, i + 1)
                    } else {
                        let start = i
                        while i < s.count, !isSpace(s[i]), s[i] != 0x3e { i += 1 }
                        value = String(decoding: s[start..<i], as: UTF8.self)
                    }
                }
                attrs.append((aname.lowercased(), EPUBEntities.decode(value)))
            }
            let name = Self.local(qname)
            // HTML's implied end tags: a block closes an open <p>, a list item an open <li>.
            if EPUBMarkup.closesParagraph.contains(name), let top = stack.last, top.localName == "p" { stack.removeLast() }
            if name == "li", let at = stack.lastIndex(where: { $0.localName == "li" }), !stack[at...].contains(where: { $0.localName == "ul" || $0.localName == "ol" }) {
                stack.removeSubrange(at...)
            }
            let node = EPUBNode(kind: .element, localName: name, attributes: attrs)
            stack.last!.append(node)
            if selfClosing || EPUBMarkup.voidElements.contains(name) { return }
            if EPUBMarkup.rawText.contains(name) {
                // Script and style content is text up to the matching end tag.
                let close = Array("</\(name)".utf8)
                var j = i
                var end = s.count
                while j + close.count <= s.count {
                    var ok = true
                    for k in 0..<close.count {
                        let c = s[j + k]
                        let lower = (c >= 0x41 && c <= 0x5a) ? c + 32 : c
                        if lower != close[k] { ok = false; break }
                    }
                    if ok { end = j; break }
                    j += 1
                }
                if i < end { node.append(EPUBNode(kind: .text, text: String(decoding: s[i..<end], as: UTF8.self))) }
                i = end
                if i < s.count { i = find(">", from: i).map { $0 + 1 } ?? s.count }
                return
            }
            // Past this depth nesting is flattened into the parent, so every recursive walk over the
            // tree (descendants, textContent, documentSections…) stays bounded (review 21).
            if stack.count < Self.maxDepth { stack.append(node) }
        }

        static let maxDepth = 256

        mutating func closeTag() {
            i += 2
            let name = Self.local(readName())
            i = find(">", from: i).map { $0 + 1 } ?? s.count
            guard let at = stack.lastIndex(where: { $0.localName == name }), at > 0 else { return }
            stack.removeSubrange(at...)
        }

        func addText(_ from: Int, _ to: Int, decode: Bool) {
            guard from < to else { return }
            let raw = String(decoding: s[from..<to], as: UTF8.self)
            stack.last!.append(EPUBNode(kind: .text, text: decode ? EPUBEntities.decode(raw) : raw))
        }

        func addTextString(_ t: String) {
            stack.last!.append(EPUBNode(kind: .text, text: t))
        }
    }
}

/// Character references: numeric ones, XML's five and the HTML names books actually use.
enum EPUBEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201c}", "rdquo": "\u{201d}", "sbquo": "\u{201a}", "bdquo": "\u{201e}", "laquo": "\u{00ab}", "raquo": "\u{00bb}",
        "copy": "\u{00a9}", "reg": "\u{00ae}", "trade": "\u{2122}", "deg": "\u{00b0}", "middot": "\u{00b7}", "bull": "\u{2022}",
        "sect": "\u{00a7}", "para": "\u{00b6}", "dagger": "\u{2020}", "Dagger": "\u{2021}", "prime": "\u{2032}", "Prime": "\u{2033}",
        "times": "\u{00d7}", "divide": "\u{00f7}", "frac12": "\u{00bd}", "frac14": "\u{00bc}", "frac34": "\u{00be}", "pound": "\u{00a3}",
        "euro": "\u{20ac}", "cent": "\u{00a2}", "yen": "\u{00a5}", "shy": "\u{00ad}", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "zwnj": "\u{200c}", "zwj": "\u{200d}", "iexcl": "\u{00a1}", "iquest": "\u{00bf}", "szlig": "\u{00df}",
        "agrave": "\u{00e0}", "aacute": "\u{00e1}", "acirc": "\u{00e2}", "atilde": "\u{00e3}", "auml": "\u{00e4}", "aring": "\u{00e5}", "aelig": "\u{00e6}",
        "ccedil": "\u{00e7}", "egrave": "\u{00e8}", "eacute": "\u{00e9}", "ecirc": "\u{00ea}", "euml": "\u{00eb}", "igrave": "\u{00ec}", "iacute": "\u{00ed}",
        "icirc": "\u{00ee}", "iuml": "\u{00ef}", "ntilde": "\u{00f1}", "ograve": "\u{00f2}", "oacute": "\u{00f3}", "ocirc": "\u{00f4}", "otilde": "\u{00f5}",
        "ouml": "\u{00f6}", "oslash": "\u{00f8}", "ugrave": "\u{00f9}", "uacute": "\u{00fa}", "ucirc": "\u{00fb}", "uuml": "\u{00fc}", "yacute": "\u{00fd}", "yuml": "\u{00ff}",
        "Agrave": "\u{00c0}", "Aacute": "\u{00c1}", "Acirc": "\u{00c2}", "Atilde": "\u{00c3}", "Auml": "\u{00c4}", "Aring": "\u{00c5}", "AElig": "\u{00c6}",
        "Ccedil": "\u{00c7}", "Egrave": "\u{00c8}", "Eacute": "\u{00c9}", "Ecirc": "\u{00ca}", "Euml": "\u{00cb}", "Igrave": "\u{00cc}", "Iacute": "\u{00cd}",
        "Icirc": "\u{00ce}", "Iuml": "\u{00cf}", "Ntilde": "\u{00d1}", "Ograve": "\u{00d2}", "Oacute": "\u{00d3}", "Ocirc": "\u{00d4}", "Otilde": "\u{00d5}",
        "Ouml": "\u{00d6}", "Oslash": "\u{00d8}", "Ugrave": "\u{00d9}", "Uacute": "\u{00da}", "Ucirc": "\u{00db}", "Uuml": "\u{00dc}", "Yacute": "\u{00dd}",
        "oelig": "\u{0153}", "OElig": "\u{0152}",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest.index(after: amp)
            if let semi = rest[after...].prefix(12).firstIndex(of: ";") {
                let name = String(rest[after..<semi])
                if let r = replacement(name) {
                    out += r
                    rest = rest[rest.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = rest[after...]
        }
        out += rest
        return out
    }

    private static func replacement(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let body = name.dropFirst()
            let value: UInt32? = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body, radix: 10)
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        return named[name]
    }
}

// MARK: - epub.ts

struct EPUBBook {
    struct Chapter: Hashable { var path: String; var title: String }
    var chapters: [Chapter]
    fileprivate var entries: [String: Data]
    fileprivate var chapterContents: [String: String]

    private static let ignoredNames: Set<String> = ["script", "style", "noscript", "nav", "form", "svg"]
    private static let blockNames: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "blockquote", "li", "pre", "div", "section", "article", "header", "footer", "aside", "table", "tr"]
    private static let leafBlockNames: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "blockquote", "li", "pre"]

    private struct Item { var path: String; var mediaType: String; var properties: String }
    private struct Link { var path: String; var fragment: String; var title: String }
    private struct Target { var path: String; var fragment: String; var title: String; var node: EPUBNode }

    // epub.ts entry(): exact name first, then case-insensitive.
    private static func entry(_ entries: [String: Data], _ path: String) -> Data? {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("./") { normalized.removeFirst(2) }
        if let d = entries[normalized] { return d }
        let lower = normalized.lowercased()
        return entries.first { $0.key.lowercased() == lower }?.value
    }

    private static func document(_ data: Data?) -> EPUBNode? { data.map(EPUBMarkup.parse) }

    private static let invalidBase = "https://epub.invalid/"
    private static let hrefAllowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "#%?"))

    /// `new URL(href, "https://epub.invalid/" + base)`, forgiving about unescaped characters.
    private static func resolve(_ href: String, against base: String) -> URL? {
        let b = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        guard let baseURL = URL(string: invalidBase + b) else { return nil }
        let h = URL(string: href) != nil ? href : (href.addingPercentEncoding(withAllowedCharacters: hrefAllowed) ?? href)
        return URL(string: h, relativeTo: baseURL)?.absoluteURL
    }

    /// epub.ts archivePath: the href (without its fragment) resolved against the base, decoded.
    private static func archivePath(_ base: String, _ href: String) -> String {
        let bare = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let url = resolve(bare, against: base) else { return bare }
        return String(url.path.drop(while: { $0 == "/" }))
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// epub.ts navigationLink.
    private static func navigationLink(_ base: String, _ href: String, _ title: String) -> [Link] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = resolve(href, against: base), target.host == "epub.invalid" else { return [] }
        let fragment = target.fragment.map { $0.removingPercentEncoding ?? $0 } ?? ""
        return [Link(path: String(target.path.drop(while: { $0 == "/" })), fragment: fragment, title: collapse(title))]
    }

    /// epub.ts navigationLinks: the NCX navPoints, or the EPUB 3 toc nav's links.
    private static func navigationLinks(_ document: EPUBNode?, _ path: String, ncx: Bool) -> [Link] {
        guard let document else { return [] }
        if ncx {
            return document.elements("navPoint").flatMap { point -> [Link] in
                let kids = point.elementChildren
                guard let href = kids.first(where: { $0.localName == "content" })?.attr("src") else { return [] }
                let title = kids.first(where: { $0.localName == "navlabel" })?.textContent ?? ""
                return navigationLink(path, href, title)
            }
        }
        return document.elements("nav")
            .filter { nav in
                let type = nav.attributes.first(where: { $0.name == "epub:type" || $0.name.hasSuffix(":type") })?.value ?? ""
                return type.split(whereSeparator: \.isWhitespace).contains("toc")
                    || (nav.attr("role") ?? "").split(whereSeparator: \.isWhitespace).contains("doc-toc")
            }
            .flatMap(\.descendants)
            .filter { $0.localName == "a" && $0.attr("href") != nil }
            .flatMap { navigationLink(path, $0.attr("href")!, $0.textContent) }
    }

    private static func chapterRoot(_ document: EPUBNode) -> EPUBNode {
        document.element("body") ?? document.documentElement ?? document
    }

    /// epub.ts targetNode: the element a nav link points at, lifted to its heading.
    private static func targetNode(_ document: EPUBNode, _ fragment: String) -> EPUBNode? {
        let root = chapterRoot(document)
        if fragment.isEmpty { return root }
        var target = ([root] + root.descendants).first {
            $0.attr("id") == fragment || $0.attr("xml:id") == fragment || ($0.localName == "a" && $0.attr("name") == fragment)
        }
        var node = target
        while let n = node {
            if ignoredNames.contains(n.localName) { return nil }
            if n.localName.count == 2, n.localName.hasPrefix("h"), let d = n.localName.last, ("1"..."6").contains(d) { target = n }
            if n === root { break }
            node = n.parent
        }
        return target
    }

    private static func tidySection(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// epub.ts documentSections: the body's text, split where a nav target starts.
    private static func documentSections(_ document: EPUBNode, _ targets: [ObjectIdentifier: Target]) -> [(target: Target?, text: String)] {
        var sections: [(target: Target?, text: String)] = []
        var target: Target?
        var chunks: [String] = []
        func flush() {
            sections.append((target, tidySection(chunks.joined())))
            chunks = []
        }
        func visit(_ node: EPUBNode, _ preserve: Bool) {
            if node.kind == .text {
                chunks.append(preserve ? node.text : node.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
                return
            }
            let name = node.localName
            if ignoredNames.contains(name) { return }
            if let next = targets[ObjectIdentifier(node)] {
                flush()
                target = next
            }
            let block = blockNames.contains(name)
            if block { chunks.append("\n\n") }
            if name == "br" { chunks.append("\n") } else { for c in node.children { visit(c, preserve || name == "pre") } }
            if block { chunks.append("\n\n") }
        }
        visit(chapterRoot(document), false)
        flush()
        return sections
    }

    /// epub.ts parseEpub, less the metadata the TV takes from the source instead (title, authors,
    /// cover): the reading order, the chapters the table of contents names, and their text.
    static func parse(_ data: Data) throws -> EPUBBook {
        let entries = try EPUBZip.entries(data)
        guard let container = document(entry(entries, "META-INF/container.xml")),
              let packagePath = container.element("rootfile")?.attr("full-path") else { throw EPUBError.noPackage }
        guard let packageDocument = document(entry(entries, packagePath)) else { throw EPUBError.unreadablePackage }
        let packageBase = packagePath.contains("/") ? String(packagePath[...packagePath.lastIndex(of: "/")!]) : ""
        var manifest: [String: Item] = [:]
        var manifestOrder: [Item] = []
        for item in packageDocument.elements("item") {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            let value = Item(path: archivePath(packageBase, href), mediaType: item.attr("media-type") ?? "", properties: item.attr("properties") ?? "")
            if manifest[id] == nil { manifestOrder.append(value) }
            manifest[id] = value
        }
        func hasProperty(_ item: Item, _ p: String) -> Bool { item.properties.split(whereSeparator: \.isWhitespace).contains(Substring(p)) }
        func isHTML(_ item: Item) -> Bool { item.mediaType.contains("xhtml") || item.mediaType.contains("html") }
        let nav = manifestOrder.first { hasProperty($0, "nav") }
        let ncx = manifestOrder.first { $0.mediaType == "application/x-dtbncx+xml" }
        let spine = packageDocument.elements("itemref")
            .filter { $0.attr("linear")?.lowercased() != "no" }
            .compactMap { manifest[$0.attr("idref") ?? ""] }
            .filter { isHTML($0) && !hasProperty($0, "nav") }
        let documents = spine.isEmpty ? manifestOrder.filter { isHTML($0) && !hasProperty($0, "nav") } : spine
        struct Scanned { var path: String; var title: String; var readable: Bool; var document: EPUBNode? }
        let scanned: [Scanned] = documents.enumerated().map { index, item in
            let doc = document(entry(entries, item.path))
            var heading: String?
            if let doc {
                for name in ["h1", "h2", "h3", "title"] {
                    if let hit = doc.elements(name).first(where: { !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        heading = hit.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
            let words = doc?.documentElement.map { collapse($0.textContent) } ?? ""
            return Scanned(path: item.path, title: heading ?? "Chapter \(index + 1)", readable: words.utf16.count > 24, document: doc)
        }
        func resolveTargets(_ links: [Link]) -> [Target] {
            var seen = Set<ObjectIdentifier>()
            return links.compactMap { link in
                guard let item = scanned.first(where: { $0.path.lowercased() == link.path.lowercased() }),
                      let doc = item.document, let node = targetNode(doc, link.fragment),
                      seen.insert(ObjectIdentifier(node)).inserted else { return nil }
                return Target(path: item.path, fragment: link.fragment, title: link.title, node: node)
            }
        }
        var targets: [Target] = []
        if let nav { targets = resolveTargets(navigationLinks(document(entry(entries, nav.path)), nav.path, ncx: false)) }
        if targets.isEmpty, let ncx { targets = resolveTargets(navigationLinks(document(entry(entries, ncx.path)), ncx.path, ncx: true)) }
        let readable = scanned.filter(\.readable)
        var chapters = (readable.isEmpty ? scanned : readable).map { Chapter(path: $0.path, title: $0.title) }
        var contents: [String: String] = [:]
        if !targets.isEmpty {
            var boundaries: [ObjectIdentifier: Target] = [:]
            for t in targets { boundaries[ObjectIdentifier(t.node)] = t }
            var drafts: [(path: String, title: String, parts: [String])] = []
            for item in scanned {
                guard let doc = item.document else { continue }
                for section in documentSections(doc, boundaries) {
                    if let t = section.target {
                        drafts.append((path: "\(t.path)#\(EPUBBook.encodeURIComponent(t.fragment))", title: t.title, parts: []))
                    }
                    if section.text.isEmpty { continue }
                    if drafts.isEmpty { drafts.append((path: "\(item.path)#", title: item.title, parts: [])) }
                    drafts[drafts.count - 1].parts.append(section.text)
                }
            }
            chapters = drafts.filter { !$0.parts.isEmpty }.map { draft in
                contents[draft.path] = draft.parts.joined(separator: "\n\n")
                return Chapter(path: draft.path, title: draft.title)
            }
        }
        return EPUBBook(chapters: chapters, entries: entries, chapterContents: contents)
    }

    /// JavaScript's encodeURIComponent: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ) is escaped.
    static func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? s
    }
    private static let uriComponentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// epub.ts readEpubChapter: the split text when the table of contents cut the book, else the
    /// document's innermost blocks, one per paragraph.
    func text(for path: String) -> String {
        if let content = chapterContents[path] { return content }
        guard let doc = Self.document(Self.entry(entries, path)) else { return "" }
        let root = Self.chapterRoot(doc)
        func leafText(_ node: EPUBNode) -> String {
            if node.kind == .text { return node.text }
            if Self.ignoredNames.contains(node.localName) { return "" }
            if node.localName == "br" { return "\n" }
            return node.children.map(leafText).joined()
        }
        let blocks = root.descendants
            .filter { Self.leafBlockNames.contains($0.localName) && !$0.descendants.contains(where: { Self.leafBlockNames.contains($0.localName) }) }
            .map { leafText($0)
                .replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\n\s*"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (blocks.isEmpty ? leafText(root) : blocks.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Download and cache

/// Gutendex EPUBs, downloaded once (gutendex.ts gutendexEpub, a 60-second budget) and kept in
/// Caches (the system may purge them), with the last few parsed books held in memory as
/// providers.ts gutendexPackage does (LOCAL_EPUB_CACHE_LIMIT).
actor EPUBLibrary {
    static let shared = EPUBLibrary()
    private var parsed: [(key: String, book: EPUBBook)] = []
    private var pending: [String: Task<EPUBBook, Error>] = [:]
    private static let memoryLimit = 3
    private static let diskLimit = 16

    private var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ebooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func book(key: String, url: String) async throws -> EPUBBook {
        if let i = parsed.firstIndex(where: { $0.key == key }) {
            let hit = parsed.remove(at: i)
            parsed.append(hit)
            return hit.book
        }
        if let task = pending[key] { return try await task.value }
        let file = folder.appendingPathComponent(EPUBBook.encodeURIComponent(key).replacingOccurrences(of: "%", with: "_") + ".epub")
        let task = Task.detached(priority: .userInitiated) { () throws -> EPUBBook in
            var data = try? Data(contentsOf: file)
            if data == nil {
                guard let remote = URL(string: url) else { throw URLError(.badURL) }
                var request = URLRequest(url: remote, timeoutInterval: 60)
                request.setValue("application/epub+zip, */*", forHTTPHeaderField: "Accept")
                let (body, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "EPUB", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                  userInfo: [NSLocalizedDescriptionKey: "Gutenberg download \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
                }
                try? body.write(to: file, options: .atomic)
                data = body
            }
            return try EPUBBook.parse(data!)
        }
        pending[key] = task
        defer { pending[key] = nil }
        let book = try await task.value
        parsed.append((key, book))
        if parsed.count > Self.memoryLimit { parsed.removeFirst(parsed.count - Self.memoryLimit) }
        trimDisk()
        return book
    }

    private func trimDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) , files.count > Self.diskLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.diskLimit) { try? fm.removeItem(at: url) }
    }
}
