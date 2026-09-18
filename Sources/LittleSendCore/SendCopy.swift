import Foundation

/// Wording for a finished send.
public enum SendCopy {

    /// - Parameters:
    ///   - destination: already phrased for a sentence — "your Kindle",
    ///     "someone@example.com", "your Kindle and 2 recipients".
    ///   - minutes: reading time, or nil for a file, which is sent as-is and
    ///     never opened here.
    public static func success(title: String, destination: String, minutes: Int?) -> String {
        let line = "Sent “\(title)” to \(destination)."
        guard let minutes else { return line }
        return line + " A \(minutes)-minute read."
    }
}
