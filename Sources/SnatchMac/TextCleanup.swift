import Foundation

/// Undoes the layout of the source: words hyphenated across lines are rejoined and
/// lines that were only wrapped are merged back into paragraphs. List items and lines
/// that end a sentence keep their breaks.
enum TextCleanup {
    static func merge(_ lines: [String]) -> [String] {
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Only a line that starts lowercase can be the continuation of the one above.
            guard let last = out.last, !last.isEmpty,
                  let first = line.first, first.isLowercase, !isListItem(line)
            else {
                out.append(line)
                continue
            }
            if last.hasSuffix("-"), last.dropLast().last?.isLetter == true {
                out[out.count - 1] = String(last.dropLast()) + line      // "exam-" + "ple"
            } else if !endsSentence(last) {
                out[out.count - 1] = last + " " + line                     // wrapped line
            } else {
                out.append(line)
            }
        }
        return out
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return ".!?:;\"”)]".contains(last)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^(\s*[-•*–▪◦]\s|\s*\d{1,3}[.)]\s|\s*[a-zA-Z][.)]\s)"#, options: .regularExpression) != nil
    }
}
