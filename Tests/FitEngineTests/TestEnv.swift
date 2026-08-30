import Foundation

// Fixture paths, overridable via environment (see task packet section 4).
// Tests using these must XCTSkip cleanly when the paths are absent.
enum TestEnv {
    static var dropDir: String {
        ProcessInfo.processInfo.environment["FITENGINE_DROP_DIR"]
            ?? ""
    }
    static var spikeDir: String {
        ProcessInfo.processInfo.environment["FITENGINE_SPIKE_DIR"]
            ?? ""
    }
    static var truthPath: String {
        ProcessInfo.processInfo.environment["FITENGINE_TRUTH"]
            ?? ""
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
