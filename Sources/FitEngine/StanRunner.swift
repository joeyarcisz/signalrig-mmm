import Foundation

// Runs the precompiled CmdStan binary as 4 concurrent chains. The binary at
// the local spike workspace/dist/mmm is rpath-fixed with a
// sibling lib/ directory, so no environment variables are set here.
public enum StanRunnerError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case chainFailed(chain: Int, exitCode: Int32, stdoutPath: String)
    case timeout(seconds: Double)

    public var description: String {
        switch self {
        case .binaryNotFound(let path):
            return "stan binary not found at \(path)"
        case .chainFailed(let chain, let exitCode, let stdoutPath):
            return "chain \(chain) exited with code \(exitCode), see \(stdoutPath)"
        case .timeout(let seconds):
            return "stan run exceeded timeout of \(seconds) seconds, chains were terminated"
        }
    }
}

public struct StanRunResult {
    public let chainCSVPaths: [String]   // in chain order, id 1...chains
    public let stdoutPaths: [String]
}

public enum StanRunner {
    public static func run(
        binaryPath: String,
        dataPath: String,
        workDir: String,
        seed: Int = 42,
        chains: Int = 4,
        numSamples: Int = 1000,
        numWarmup: Int = 1000,
        timeout: TimeInterval = 900
    ) throws -> StanRunResult {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw StanRunnerError.binaryNotFound(binaryPath)
        }
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        let workURL = URL(fileURLWithPath: workDir, isDirectory: true)
        var processes: [Process] = []
        var handles: [FileHandle] = []
        var outputPaths: [String] = []
        var stdoutPaths: [String] = []

        for i in 1...chains {
            let outputPath = workURL.appendingPathComponent("mmm_\(i).csv").path
            let stdoutPath = workURL.appendingPathComponent("mmm_\(i)-stdout.txt").path
            outputPaths.append(outputPath)
            stdoutPaths.append(stdoutPath)

            FileManager.default.createFile(atPath: stdoutPath, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: stdoutPath) else {
                throw StanRunnerError.chainFailed(chain: i, exitCode: -1, stdoutPath: stdoutPath)
            }
            handles.append(handle)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = [
                "sample",
                "num_samples=\(numSamples)",
                "num_warmup=\(numWarmup)",
                "data", "file=\(dataPath)",
                "output", "file=\(outputPath)",
                "random", "seed=\(seed)",
                "id=\(i)",
            ]
            process.standardOutput = handle
            process.standardError = handle
            processes.append(process)
        }

        for p in processes {
            try p.run()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while processes.contains(where: { $0.isRunning }) {
            if Date() > deadline {
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if timedOut {
            for p in processes where p.isRunning {
                p.terminate()
            }
            Thread.sleep(forTimeInterval: 0.5)
            for handle in handles { try? handle.close() }
            throw StanRunnerError.timeout(seconds: timeout)
        }

        for handle in handles { try? handle.close() }

        for (idx, p) in processes.enumerated() {
            let code = p.terminationStatus
            if code != 0 {
                throw StanRunnerError.chainFailed(chain: idx + 1, exitCode: code, stdoutPath: stdoutPaths[idx])
            }
        }

        return StanRunResult(chainCSVPaths: outputPaths, stdoutPaths: stdoutPaths)
    }
}
