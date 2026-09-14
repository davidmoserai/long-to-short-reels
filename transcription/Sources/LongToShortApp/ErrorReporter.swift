import AppKit
import Foundation

enum ErrorReporter {
    private static let supportEmail = "david@getmatches.ai"

    @discardableResult
    static func record(error: Error, inputFile: String) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let report = """
        Armin's Long to Short Converter error report
        Time: \(ISO8601DateFormatter().string(from: Date()))
        App version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Input file: \(inputFile)
        Error: \(error.localizedDescription)

        This report never includes the user's Anthropic API key.
        """

        writeToLog(report)
        return report
    }

    static func email(report: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Long to Short Converter error report"),
            URLQueryItem(name: "body", value: report),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private static func writeToLog(_ report: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ArminsLongToShortConverter", isDirectory: true)
        let logURL = directory.appendingPathComponent("errors.log")
        let entry = "\n\n\(report)\n"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            handle.write(Data(entry.utf8))
            try handle.close()
        } catch {
            // Reporting must never hide or replace the original processing failure.
        }
    }
}
