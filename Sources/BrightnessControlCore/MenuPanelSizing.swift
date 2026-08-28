import Foundation

public enum MenuPanelSizing {
    public static let width = 380.0

    public static func height(displayCount: Int, isLoading: Bool, hasError: Bool) -> Double {
        let errorHeight = hasError ? 42.0 : 0.0
        if isLoading || displayCount == 0 {
            return 322 + errorHeight
        }

        let rowHeight = 78.0
        let fixedChrome = 284.0
        let rawHeight = fixedChrome + Double(displayCount) * rowHeight + errorHeight
        return min(max(rawHeight, 322), 600)
    }
}
