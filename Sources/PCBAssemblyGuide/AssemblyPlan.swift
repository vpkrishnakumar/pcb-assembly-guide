import Foundation

/// Soldering stages.
enum Stage: Int, CaseIterable {
    case topSMD, bottomSMD, topTHT, bottomTHT

    var title: String {
        switch self {
        case .topSMD: return "Top · SMD"
        case .bottomSMD: return "Bottom · SMD"
        case .topTHT: return "Top · Through-hole"
        case .bottomTHT: return "Bottom · Through-hole"
        }
    }
}

/// Ready-made ways of ordering the stages.
enum OrderPreset: String, CaseIterable, Codable, Identifiable {
    case smdThenTHT, topThenBottom, bottomThenTop, smallestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smdThenTHT: return "SMD on both sides, then through-hole"
        case .topThenBottom: return "Finish the top side, then the bottom"
        case .bottomThenTop: return "Finish the bottom side, then the top"
        case .smallestFirst: return "Strictly smallest first (ICs not moved up)"
        }
    }

    fileprivate var stages: [Stage] {
        switch self {
        case .smdThenTHT, .smallestFirst: return [.topSMD, .bottomSMD, .topTHT, .bottomTHT]
        case .topThenBottom: return [.topSMD, .topTHT, .bottomSMD, .bottomTHT]
        case .bottomThenTop: return [.bottomSMD, .bottomTHT, .topSMD, .topTHT]
        }
    }

    fileprivate func rank(_ stage: Stage) -> Int { stages.firstIndex(of: stage) ?? 0 }
}

/// Identical parts (same value and footprint) that are placed back to back.
struct PartGroup: Identifiable {
    let id: Int
    /// Stable identity used to remember a hand-arranged order.
    let key: String
    let stage: Stage
    let value: String
    let footprint: String
    /// Package size shared by the group, e.g. "0402".
    let sizeLabel: String?
    let refs: [String]
    /// Index of this group's first part in `AssemblyPlan.steps`.
    let firstStep: Int
}

/// The order in which parts are placed, one per step, tuned for hand soldering with an iron:
/// ICs first while the pads are easy to reach, then smallest body to largest, identical parts together.
struct AssemblyPlan {
    var groups: [PartGroup] = []
    var steps: [String] = []
    var groupOfStep: [Int] = []

    init() {}

    /// `customOrder` lists group keys in the order the user dragged them into; it overrides the preset.
    init(components: [Component], preset: OrderPreset = .smdThenTHT, customOrder: [String]? = nil) {
        struct Key: Hashable {
            let stage: Stage
            let value: String
            let footprint: String
            var text: String { "\(stage.rawValue)|\(value)|\(footprint)" }
        }
        func stage(_ c: Component) -> Stage {
            if c.isTHT { return c.isBottom ? .bottomTHT : .topTHT }
            return c.isBottom ? .bottomSMD : .topSMD
        }

        let buckets = Dictionary(grouping: components) { Key(stage: stage($0), value: $0.value, footprint: $0.footprint) }
        var ordered = buckets.sorted { a, b in
            let ca = a.value[0], cb = b.value[0]
            if a.key.stage != b.key.stage { return preset.rank(a.key.stage) < preset.rank(b.key.stage) }
            if preset != .smallestFirst, ca.isIC != cb.isIC { return ca.isIC }
            if abs(ca.area - cb.area) > 0.01 { return ca.area < cb.area }
            if a.key.value != b.key.value {
                return a.key.value.compare(b.key.value, options: .numeric) == .orderedAscending
            }
            return a.key.footprint < b.key.footprint
        }
        if let customOrder {
            let position = Dictionary(customOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let indexed = ordered.enumerated().map { (offset: $0, element: $1) }
            // Groups the saved order does not know about (new parts) keep their place at the end.
            ordered = indexed.sorted {
                let a = position[$0.element.key.text] ?? Int.max, b = position[$1.element.key.text] ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        }

        for (key, members) in ordered {
            let refs = Self.walkOrder(members)
            groups.append(PartGroup(id: groups.count, key: key.text, stage: key.stage, value: key.value,
                                    footprint: key.footprint, sizeLabel: members[0].sizeLabel,
                                    refs: refs, firstStep: steps.count))
            steps.append(contentsOf: refs)
            groupOfStep.append(contentsOf: Array(repeating: groups.count - 1, count: refs.count))
        }
    }

    /// Orders identical parts so each one is next to the previous, starting top-left.
    private static func walkOrder(_ members: [Component]) -> [String] {
        var remaining = members
        guard let startIndex = remaining.indices.min(by: {
            remaining[$0].x + remaining[$0].y < remaining[$1].x + remaining[$1].y
        }) else { return [] }
        var current = remaining.remove(at: startIndex)
        var out = [current.ref]
        while !remaining.isEmpty {
            let next = remaining.indices.min {
                hypot(remaining[$0].x - current.x, remaining[$0].y - current.y)
                    < hypot(remaining[$1].x - current.x, remaining[$1].y - current.y)
            }!
            current = remaining.remove(at: next)
            out.append(current.ref)
        }
        return out
    }
}
