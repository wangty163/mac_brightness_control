import Foundation

public enum SleepDisabledStateParser {
    public static func parse(_ output: String) -> Bool? {
        let pattern = #"\"SleepDisabled\"\s*=\s*(Yes|No|true|false|1|0)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard
            let match = expression.firstMatch(in: output, range: range),
            let valueRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }

        switch output[valueRange].lowercased() {
        case "yes", "true", "1":
            return true
        case "no", "false", "0":
            return false
        default:
            return nil
        }
    }
}
