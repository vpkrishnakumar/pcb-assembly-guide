import Foundation

/// What is printed on the physical part, where that can be worked out.
enum Marking {
    /// A short hint about the top marking to expect, or nil when nothing useful can be said.
    static func hint(for part: Component) -> String? {
        switch part.prefix {
        case "R":
            guard let ohms = ohms(part.value) else { return nil }
            if ohms == 0 { return "Marking: 0 or 000 (often unmarked at 0402 and below)." }
            let small = ["01005", "0201", "0402"].contains(part.chipSize ?? "")
            let codes = "\(code(ohms, digits: 2)) (5%) or \(code(ohms, digits: 3)) (1%)"
            return small ? "Usually unmarked at this size. If marked: \(codes)." : "Marking: \(codes)."
        case "RN":
            guard let ohms = ohms(part.value) else { return nil }
            return "Marking: \(code(ohms, digits: 2))."
        case "C":
            return part.polarity == nil ? "Ceramic capacitors are unmarked. Keep them in their labelled strip." : nil
        case "L", "FB":
            return nil
        default:
            return part.padCount > 2 || part.polarity != nil
                ? "The top marking is often a short code, not the part number. Check the datasheet." : nil
        }
    }

    /// Parses values such as "10k", "4k7", "100R", "2.2M", "0R (pads 1-2)" into ohms.
    static func ohms(_ value: String) -> Double? {
        guard let token = value.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "/" }).first else { return nil }
        let t = token.uppercased().replacingOccurrences(of: "Ω", with: "R").replacingOccurrences(of: "OHM", with: "R")
        let multipliers: [Character: Double] = ["R": 1, "K": 1e3, "M": 1e6]
        if let i = t.firstIndex(where: { multipliers[$0] != nil }) {
            let whole = String(t[..<i]), fraction = String(t[t.index(after: i)...])
            guard whole.allSatisfy(\.isNumber) || Double(whole) != nil, fraction.allSatisfy(\.isNumber) else { return nil }
            let number = fraction.isEmpty ? Double(whole.isEmpty ? "0" : whole) : Double("\(whole.isEmpty ? "0" : whole).\(fraction)")
            guard let number, !(whole.isEmpty && fraction.isEmpty) else { return nil }
            return number * multipliers[t[i]]!
        }
        return Double(t)
    }

    /// EIA code with `digits` significant figures followed by a multiplier digit, e.g. 10 kΩ → "103" / "1002".
    static func code(_ ohms: Double, digits: Int) -> String {
        guard ohms > 0 else { return "0" }
        var exponent = Int(floor(log10(ohms))) - (digits - 1)
        if exponent < 0 {
            // Below the smallest whole-number code, "R" marks the decimal point: 4.7 Ω → "4R7".
            let text = String(format: "%.\(digits)f", ohms).replacingOccurrences(of: ".", with: "R")
            return String((ohms < 1 ? String(text.dropFirst()) : text).prefix(digits + 1))
        }
        var mantissa = Int((ohms / pow(10, Double(exponent))).rounded())
        if mantissa >= Int(pow(10, Double(digits))) {
            mantissa /= 10
            exponent += 1
        }
        return "\(mantissa)\(exponent)"
    }
}
