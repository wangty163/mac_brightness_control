import Foundation

@objc public protocol SleepProtectionServiceProtocol {
    func beginProtection(withReply reply: @escaping (String?, String?) -> Void)
    func endProtection(sessionID: String, withReply reply: @escaping (Bool, String?) -> Void)
    func protectionStatus(sessionID: String, withReply reply: @escaping (Bool, String?) -> Void)
}
