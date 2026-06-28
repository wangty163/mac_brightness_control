import Foundation

public enum MenuPanelSizing {
    public static let width = 380.0

    public static func height(displayCount: Int, isLoading: Bool, hasError: Bool) -> Double {
        if isLoading || displayCount == 0 {
            return hasError ? 304 : 274
        }

        let rowHeight = 76.0
        let fixedChrome = 236.0
        let errorHeight = hasError ? 34.0 : 0.0
        let rawHeight = fixedChrome + Double(displayCount) * rowHeight + errorHeight
        return min(max(rawHeight, 274), 520)
    }
}
