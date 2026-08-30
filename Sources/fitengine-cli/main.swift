import Foundation
import FitEngine

func errExit(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// Hand-rolled --flag value parsing, no external argument-parsing library.
func parseOptions(_ args: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out[key] = args[i + 1]
                i += 2
            } else {
                out[key] = "true"
                i += 1
            }
        } else {
            i += 1
        }
    }
    return out
}

func writeFile(_ text: String, to path: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

func printLoaderNotes(_ panel: Panel) {
    print("kpi_name=\"\(panel.kpiName)\"")
    for w in panel.warnings { print("warning: \(w)") }
}

func runPrep(_ opts: [String: String]) {
    guard let drop = opts["drop"], let out = opts["out"] else {
        errExit("prep requires --drop <dir> --out <dir>")
    }
    do {
        let panel = try PanelLoader.load(dropDir: drop)
        let built = StanDataBuilder.build(panel: panel)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let outURL = URL(fileURLWithPath: out, isDirectory: true)
        try writeFile(built.full.toJSON().serialized(), to: outURL.appendingPathComponent("data_full.json").path)
        try writeFile(built.holdout.toJSON().serialized(), to: outURL.appendingPathComponent("data_holdout.json").path)
        try writeFile(built.meta.toJSON().serialized(), to: outURL.appendingPathComponent("panel_meta.json").path)
        print("wrote data_full.json, data_holdout.json, panel_meta.json to \(out)")
        print("T=\(panel.T) C=\(panel.C) K=\(panel.K) channels=\(panel.channels)")
        printLoaderNotes(panel)
    } catch {
        errExit("prep failed: \(error)")
    }
}

func runFit(_ opts: [String: String]) {
    guard let binary = opts["binary"], let data = opts["data"], let work = opts["work"] else {
        errExit("fit requires --binary <path> --data <json> --work <dir>")
    }
    let seed = Int(opts["seed"] ?? "42") ?? 42
    let timeout = Double(opts["timeout"] ?? "900") ?? 900
    do {
        let t0 = Date()
        let result = try StanRunner.run(binaryPath: binary, dataPath: data, workDir: work, seed: seed, timeout: timeout)
        let elapsed = Date().timeIntervalSince(t0)
        print("fit complete in \(elapsed)s, \(result.chainCSVPaths.count) chains")
        for p in result.chainCSVPaths { print(p) }
    } catch {
        errExit("fit failed: \(error)")
    }
}

func runGrade(_ opts: [String: String]) {
    guard let fullDir = opts["full-dir"], let metaPath = opts["meta"], let truthPath = opts["truth"] else {
        errExit("grade requires --full-dir <dir> --meta <panel_meta.json> --truth <truth.json> [--holdout-dir <dir>] [--out <file>] [--max-draws N]")
    }
    let holdoutDir = opts["holdout-dir"]
    // Default: all draws, no RNG subsampling (see Metrics.subsampleDraws).
    let maxDraws = opts["max-draws"].flatMap { Int($0) } ?? Int.max
    do {
        let result = try Grader.grade(fullDir: fullDir, holdoutDir: holdoutDir, metaPath: metaPath, truthPath: truthPath, maxDraws: maxDraws)
        let json = try result.toJSON().serialized()
        print(json)
        if let outPath = opts["out"] {
            try writeFile(json, to: outPath)
        }
    } catch {
        errExit("grade failed: \(error)")
    }
}

func runArtifacts(_ opts: [String: String]) {
    guard let fullDir = opts["full-dir"], let holdoutDir = opts["holdout-dir"], let metaPath = opts["meta"],
          let drop = opts["drop"], let out = opts["out"] else {
        errExit("artifacts requires --full-dir <dir> --holdout-dir <dir> --meta <panel_meta.json> --drop <dir> --out <dir> [--truth <truth.json>] [--unavailable-recovery] [--seed N] [--git-sha SHA] [--bench <bench.json>] [--date YYYY-MM-DD] [--label <name>]")
    }
    let unavailableRecovery = opts["unavailable-recovery"] != nil
    if opts["truth"] == nil && !unavailableRecovery {
        errExit("artifacts requires --truth <truth.json> unless --unavailable-recovery is passed")
    }
    let seed = Int(opts["seed"] ?? "42") ?? 42
    let gitSha = opts["git-sha"] ?? "uncommitted"
    let packageLabel = opts["label"] ?? ArtifactConstants.defaultPackageLabel

    var blendedCplPrior = ArtifactConstants.defaultBlendedCplPrior
    var blendedCplCalibrated = ArtifactConstants.defaultBlendedCplCalibrated
    if let benchPath = opts["bench"] {
        do {
            let text = try String(contentsOfFile: benchPath, encoding: .utf8)
            let json = try JSONParser.parse(text)
            if let prior = json["blended"]?["cpl_prior"]?.asDouble { blendedCplPrior = prior }
            if let calibrated = json["blended"]?["cpl_calibrated"]?.asDouble { blendedCplCalibrated = calibrated }
        } catch {
            errExit("artifacts failed to read --bench \(benchPath): \(error)")
        }
    }

    do {
        let bundle = try ArtifactsPipeline.run(
            fullDir: fullDir,
            holdoutDir: holdoutDir,
            metaPath: metaPath,
            truthPath: opts["truth"],
            dropDir: drop,
            seed: seed,
            gitSha: gitSha,
            blendedCplPrior: blendedCplPrior,
            blendedCplCalibrated: blendedCplCalibrated,
            memoDate: opts["date"],
            packageLabel: packageLabel,
            unavailableRecovery: unavailableRecovery
        )
        try ArtifactsPipeline.write(bundle, to: out)
        print("wrote " + bundle.files.map { $0.name }.joined(separator: ", ") + " to \(out)")
        for w in bundle.warnings { print("warning: \(w)") }
    } catch {
        errExit("artifacts failed: \(error)")
    }
}

func runE2E(_ opts: [String: String]) {
    guard let drop = opts["drop"], let binary = opts["binary"], let truth = opts["truth"], let work = opts["work"] else {
        errExit("e2e requires --drop <dir> --binary <path> --truth <path> --work <dir> [--seed N]")
    }
    let seed = Int(opts["seed"] ?? "42") ?? 42
    do {
        let panel = try PanelLoader.load(dropDir: drop)
        let built = StanDataBuilder.build(panel: panel)

        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let workURL = URL(fileURLWithPath: work, isDirectory: true)
        let dataFullPath = workURL.appendingPathComponent("data_full.json").path
        let dataHoldoutPath = workURL.appendingPathComponent("data_holdout.json").path
        let metaPath = workURL.appendingPathComponent("panel_meta.json").path
        try writeFile(built.full.toJSON().serialized(), to: dataFullPath)
        try writeFile(built.holdout.toJSON().serialized(), to: dataHoldoutPath)
        try writeFile(built.meta.toJSON().serialized(), to: metaPath)
        print("prep: T=\(panel.T) C=\(panel.C) K=\(panel.K)")
        printLoaderNotes(panel)

        let fullWork = workURL.appendingPathComponent("full").path
        let holdoutWork = workURL.appendingPathComponent("holdout").path

        print("fitting full model (4 chains)...")
        let t0 = Date()
        _ = try StanRunner.run(binaryPath: binary, dataPath: dataFullPath, workDir: fullWork, seed: seed)
        print("full fit done in \(Date().timeIntervalSince(t0))s")

        print("fitting holdout model (4 chains)...")
        let t1 = Date()
        _ = try StanRunner.run(binaryPath: binary, dataPath: dataHoldoutPath, workDir: holdoutWork, seed: seed)
        print("holdout fit done in \(Date().timeIntervalSince(t1))s")

        let result = try Grader.grade(fullDir: fullWork, holdoutDir: holdoutWork, metaPath: metaPath, truthPath: truth)
        print(try result.toJSON().serialized())
    } catch {
        errExit("e2e failed: \(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    errExit("usage: fitengine-cli <prep|fit|grade|e2e|artifacts> [options]")
}
let opts = parseOptions(Array(arguments.dropFirst()))

switch command {
case "prep": runPrep(opts)
case "fit": runFit(opts)
case "grade": runGrade(opts)
case "e2e": runE2E(opts)
case "artifacts": runArtifacts(opts)
default: errExit("unknown command: \(command); expected prep, fit, grade, e2e, or artifacts")
}
