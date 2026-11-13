import Foundation

/// Minimal S-expression tree, enough to read KiCad board files.
indirect enum SExpr {
    case atom(String)
    case list([SExpr])

    var items: [SExpr] {
        if case .list(let l) = self { return l }
        return []
    }

    var string: String? {
        if case .atom(let s) = self { return s }
        return nil
    }

    var head: String? { items.first?.string }

    /// Atoms following the head.
    var args: [String] { items.dropFirst().compactMap(\.string) }

    var numbers: [Double] { args.compactMap(Double.init) }

    func child(_ name: String) -> SExpr? {
        items.first { $0.head == name }
    }

    func children(_ name: String) -> [SExpr] {
        items.filter { $0.head == name }
    }
}

struct SExprScanner {
    private let b: [UInt8]
    private var i = 0
    /// Sub-lists that are large and irrelevant to us (pre-rendered text outlines).
    private static let skipped: [[UInt8]] = [Array("render_cache".utf8)]

    init(_ data: Data) {
        b = [UInt8](data)
    }

    /// Returns every direct child list of the root expression whose head is in `names`,
    /// skipping everything else without building a tree for it.
    /// `end` is the byte offset of each list's closing parenthesis in the source data.
    mutating func topLevelLists(named names: [String]) -> [(expr: SExpr, end: Int)] {
        let wanted = names.map { Array($0.utf8) }
        var out: [(expr: SExpr, end: Int)] = []
        skipWS()
        guard i < b.count, b[i] == 40 else { return out }
        i += 1
        skipWS()
        if i < b.count, b[i] != 40, b[i] != 41 { _ = atom() }
        while true {
            skipWS()
            guard i < b.count, b[i] != 41 else { break }
            if b[i] == 40 {
                if wanted.contains(where: { headEquals($0) }) {
                    let parsed = expr()
                    out.append((parsed, i - 1))
                } else {
                    skipList()
                }
            } else {
                _ = atom()
            }
        }
        return out
    }

    private func isDelimiter(_ c: UInt8) -> Bool {
        c == 32 || c == 10 || c == 9 || c == 13 || c == 40 || c == 41
    }

    private mutating func skipWS() {
        while i < b.count, b[i] == 32 || b[i] == 10 || b[i] == 9 || b[i] == 13 { i += 1 }
    }

    /// With `i` on an opening paren, checks whether the list's head atom equals `name`.
    private func headEquals(_ name: [UInt8]) -> Bool {
        var j = i + 1
        while j < b.count, b[j] == 32 || b[j] == 10 || b[j] == 9 || b[j] == 13 { j += 1 }
        guard j + name.count <= b.count else { return false }
        for k in 0..<name.count where b[j + k] != name[k] { return false }
        let end = j + name.count
        return end >= b.count || isDelimiter(b[end])
    }

    private mutating func atom() -> String {
        if b[i] == 34 {
            i += 1
            var out: [UInt8] = []
            while i < b.count, b[i] != 34 {
                if b[i] == 92, i + 1 < b.count {
                    i += 1
                    out.append(b[i] == 110 ? 10 : b[i])
                } else {
                    out.append(b[i])
                }
                i += 1
            }
            i += 1
            return String(decoding: out, as: UTF8.self)
        }
        let start = i
        while i < b.count, !isDelimiter(b[i]) { i += 1 }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    /// With `i` on an opening paren, moves past the matching closing paren.
    private mutating func skipList() {
        var depth = 0
        while i < b.count {
            let c = b[i]
            if c == 34 {
                i += 1
                while i < b.count, b[i] != 34 {
                    if b[i] == 92 { i += 1 }
                    i += 1
                }
            } else if c == 40 {
                depth += 1
            } else if c == 41 {
                depth -= 1
                if depth == 0 {
                    i += 1
                    return
                }
            }
            i += 1
        }
    }

    private mutating func expr() -> SExpr {
        guard b[i] == 40 else { return .atom(atom()) }
        i += 1
        var items: [SExpr] = []
        while true {
            skipWS()
            guard i < b.count else { break }
            if b[i] == 41 {
                i += 1
                break
            }
            if b[i] == 40, Self.skipped.contains(where: { headEquals($0) }) {
                skipList()
                continue
            }
            items.append(expr())
        }
        return .list(items)
    }
}
