import Darwin
import Foundation

public protocol InternalBrightnessControlling: AnyObject {
    func readBrightness(displayID: UInt32) throws -> Int?
    func setBrightness(displayID: UInt32, percent: Int) throws
}

public final class DisplayServicesController: InternalBrightnessControlling {
    public static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias GetBrightnessFunction = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (UInt32, Float) -> Int32

    private let getBrightness: GetBrightnessFunction
    private let setBrightness: SetBrightnessFunction

    public init(frameworkPath: String = DisplayServicesController.frameworkPath) throws {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            throw BrightnessError.invalidOutput("Could not open DisplayServices.framework")
        }
        guard let getSymbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            throw BrightnessError.missingDisplayServicesSymbol("DisplayServicesGetBrightness")
        }
        guard let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            throw BrightnessError.missingDisplayServicesSymbol("DisplayServicesSetBrightness")
        }
        self.getBrightness = unsafeBitCast(getSymbol, to: GetBrightnessFunction.self)
        self.setBrightness = unsafeBitCast(setSymbol, to: SetBrightnessFunction.self)
    }

    public func readBrightness(displayID: UInt32) throws -> Int? {
        var value = Float(-1)
        let result = getBrightness(displayID, &value)
        guard result == 0 else {
            throw BrightnessError.displayServicesFailed(operation: "get brightness", code: result)
        }
        return Int((Double(value) * 100).rounded())
    }

    public func setBrightness(displayID: UInt32, percent: Int) throws {
        let clamped = max(0, min(100, percent))
        let result = setBrightness(displayID, Float(clamped) / 100.0)
        guard result == 0 else {
            throw BrightnessError.displayServicesFailed(operation: "set brightness", code: result)
        }
    }
}
