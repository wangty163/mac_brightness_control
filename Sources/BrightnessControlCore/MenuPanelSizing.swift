import Foundation

public enum MenuPanelSizing {
    public static let width = 380.0

    public static func height(displayCount: Int, isLoading: Bool, hasError: Bool) -> Double {
        _ = hasError
        if isLoading || displayCount == 0 {
            return 304
        }

        let rowHeight = 78.0
        let fixedChrome = 266.0
        let rawHeight = fixedChrome + Double(displayCount) * rowHeight
        return min(max(rawHeight, 304), 540)
    }
}
