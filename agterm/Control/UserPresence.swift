import CoreGraphics
import Foundation

/// Whether someone is at this Mac: its main display is awake and the login session is unlocked.
enum UserPresence {
    @MainActor
    static func isPresent() -> Bool {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
