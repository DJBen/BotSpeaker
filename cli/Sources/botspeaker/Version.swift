import Foundation

/// The CLI's own version. `scripts/release-macos.sh` rewrites this line to
/// match the app version it is releasing; commit the change with the release.
enum BotSpeakerCLIVersion {
    static let current = "0.4.0"

    /// Compares dotted numeric versions ("0.4.1" > "0.3.10"). Non-numeric
    /// components compare as 0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
