import Foundation

public enum CoreBrightnessParser {
    public static func parseStatusInfo(_ text: String) -> [UInt32: BrightnessInfo] {
        var values: [UInt32: (brightness: Double?, canChange: Bool?)] = [:]
        var currentDisplayID: UInt32?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let textLine = String(line)
            if let displayID = firstMatch(in: textLine, pattern: #"CBDisplayInfoDisplayID\s*=\s*(\d+)"#)
                .flatMap(UInt32.init) {
                currentDisplayID = displayID
                values[displayID, default: (nil, nil)] = values[displayID, default: (nil, nil)]
                continue
            }

            if let rawBrightness = firstMatch(
                in: textLine,
                pattern: #"DisplayServicesBrightness\s*=\s*"?([0-9.]+)"?"#
            ).flatMap(Double.init), let currentDisplayID {
                var entry = values[currentDisplayID, default: (nil, nil)]
                entry.brightness = rawBrightness
                values[currentDisplayID] = entry
                continue
            }

            if let rawCanChange = firstMatch(
                in: textLine,
                pattern: #"DisplayServicesCanChangeBrightness\s*=\s*([01])"#
            ), let currentDisplayID {
                var entry = values[currentDisplayID, default: (nil, nil)]
                entry.canChange = rawCanChange == "1"
                values[currentDisplayID] = entry
            }
        }

        return values.mapValues { entry in
            BrightnessInfo(brightness: entry.brightness, canChange: entry.canChange ?? false)
        }
    }
}

func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
        return nil
    }
    guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[valueRange])
}
