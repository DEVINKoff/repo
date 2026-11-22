import Foundation

/// Names compared the way the Hub's `catalog/merge.py` does: case, punctuation and script folded
/// («Моргенштерн» == «MORGENSHTERN», «Million Dollar: Happiness» == «MILLION DOLLAR HAPPINESS»).
enum Norm {
    private static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
        "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    static func key(_ s: String?) -> String {
        var out = ""
        for ch in (s ?? "").lowercased() {
            if let t = translit[ch] { out += t }
            else if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }
}
