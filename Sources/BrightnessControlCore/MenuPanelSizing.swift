import Foundation

public enum MenuPanelSizing {
    public static let width = 360.0

    public static func height(displayCount: Int, isLoading: Bool, hasError: Bool) -> Double {
        if isLoading || displayCount == 0 {
            return hasError ? 280 : 252
        }

        let rowHeight = 66.0
        let fixedChrome = 200.0
        let errorHeight = hasError ? 28.0 : 0.0
        let rawHeight = fixedChrome + Double(displayCount) * rowHeight + errorHeight
        return min(max(rawHeight, 252), 420)
    }
}
