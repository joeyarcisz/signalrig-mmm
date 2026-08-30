import Foundation

// Top-level orchestration for the `artifacts` CLI subcommand: wires
// DrawsReader + PosteriorView + the per-artifact builders above into the
// seven UI-artifact JSONs engine/run_all.py's own pipeline produces
// (:47-93, read-only reference at the Python reference implementation),
// minus bench.json and narratives.json (out of scope, static content
// handled elsewhere per the task packet).
public struct ArtifactsBundle {
    public let channels: JSONValue
    public let curves: JSONValue
    public let scenarios: JSONValue
    public let diagnostics: JSONValue
    public let recovery: JSONValue
    public let manifest: JSONValue
    public let memo: JSONValue

    // Loader-style notes about this run worth surfacing to whoever ran the
    // CLI (e.g. "kpi_name column absent; defaulting to \"kpi\""); empty
    // when nothing of note happened. Not written into any artifact file.
    public let warnings: [String]

    // File name -> JSONValue, in the same write order engine/artifacts/
    // export.py's ARTIFACT_FILES uses for the artifacts this port covers.
    public var files: [(name: String, value: JSONValue)] {
        [
            ("manifest.json", manifest),
            ("channels.json", channels),
            ("curves.json", curves),
            ("scenarios.json", scenarios),
            ("diagnostics.json", diagnostics),
            ("recovery.json", recovery),
            ("memo.json", memo),
        ]
    }
}

public enum ArtifactsPipelineError: Error, CustomStringConvertible {
    case missingTruth(String)

    public var description: String {
        switch self {
        case .missingTruth(let path): return "recovery requires a truth file at \(path) unless --unavailable-recovery is passed"
        }
    }
}

public enum ArtifactsPipeline {
    // holdoutDir is required, not optional (frozen design decision 1: the
    // no-holdout artifact variant is removed -- every artifacts run always
    // loads and grades the holdout-model fit; DrawsReader.readDirectory
    // throws its own descriptive error if that directory has no chain
    // CSVs). unavailableRecovery is still the correct way to build
    // real-data artifacts with no synthetic ground truth (frozen design
    // decision 6/recovery-unavailable variant STAYS for real data) --
    // that only changes recovery.json's shape and manifest.is_synthetic,
    // never whether holdout diagnostics run.
    public static func run(
        fullDir: String,
        holdoutDir: String,
        metaPath: String,
        truthPath: String?,
        dropDir: String,
        seed: Int = 42,
        gitSha: String = "uncommitted",
        blendedCplPrior: Double = ArtifactConstants.defaultBlendedCplPrior,
        blendedCplCalibrated: Double = ArtifactConstants.defaultBlendedCplCalibrated,
        memoDate: String? = nil,
        packageLabel: String = ArtifactConstants.defaultPackageLabel,
        unavailableRecovery: Bool = false
    ) throws -> ArtifactsBundle {
        let meta = try Grader.loadPanelMeta(path: metaPath)

        let fitFull = try DrawsReader.readDirectory(dir: fullDir)
        let viewFull = PosteriorView(fit: fitFull, meta: meta, seed: UInt64(seed))

        let fitHoldout = try DrawsReader.readDirectory(dir: holdoutDir)
        let viewHoldout = PosteriorView(fit: fitHoldout, meta: meta, seed: UInt64(seed))

        let channelsArt = ChannelsArtifactBuilder.build(view: viewFull)
        let curvesArt = CurvesArtifactBuilder.build(view: viewFull)
        let scenariosArt = ScenariosArtifactBuilder.build(view: viewFull)
        let diagnosticsArt = ArtifactDiagnosticsBuilder.build(fitFull: fitFull, viewFull: viewFull, viewHoldout: viewHoldout, holdoutWeeks: meta.holdoutWeeks)

        let recoveryJSON: JSONValue
        if unavailableRecovery {
            recoveryJSON = RecoveryArtifactBuilder.buildUnavailable().toJSON()
        } else {
            guard let truthPath = truthPath else {
                throw ArtifactsPipelineError.missingTruth("<none provided>")
            }
            let truth = try Grader.loadTruth(path: truthPath)
            recoveryJSON = RecoveryArtifactBuilder.build(view: viewFull, truth: truth).toJSON()
        }

        // kpi_name comes from the data (frozen design decision 4), read
        // straight from the drop directory (panel_meta.json intentionally
        // does not carry it -- see PanelLoader.readKPIName). Never
        // ChannelRegistry's old hardcoded "caregiver_signups".
        let (kpiName, kpiNameWarning) = try PanelLoader.readKPIName(dropDir: dropDir)
        var warnings: [String] = []
        if let w = kpiNameWarning { warnings.append(w) }

        let dataSha = ManifestBuilder.dataSha256(dropDir: dropDir)
        let runId = ManifestBuilder.makeRunID(seed: seed)
        let createdAt = ManifestBuilder.isoUTCNow()
        let isSynthetic = !unavailableRecovery
        let manifestArt = ManifestBuilder.build(
            runId: runId, createdAt: createdAt, seed: seed, gitSha: gitSha,
            gates: diagnosticsArt.gates, isSynthetic: isSynthetic, dataSha256: dataSha,
            kpiName: kpiName, weeks: meta.dates.count,
            dateStart: meta.dates.first ?? "", dateEnd: meta.dates.last ?? ""
        )

        let today: String = memoDate ?? {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "UTC")
            return df.string(from: Date())
        }()
        let memoArt = MemoBuilder.build(
            channels: channelsArt, scenarios: scenariosArt, diagnostics: diagnosticsArt,
            blendedCplPrior: blendedCplPrior, blendedCplCalibrated: blendedCplCalibrated, date: today,
            packageLabel: packageLabel, kpiName: kpiName, isSynthetic: isSynthetic
        )

        return ArtifactsBundle(
            channels: channelsArt.toJSON(),
            curves: curvesArt.toJSON(),
            scenarios: scenariosArt.toJSON(),
            diagnostics: diagnosticsArt.toJSON(),
            recovery: recoveryJSON,
            manifest: manifestArt.toJSON(),
            memo: memoArt.toJSON(),
            warnings: warnings
        )
    }

    public static func write(_ bundle: ArtifactsBundle, to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let outURL = URL(fileURLWithPath: dir, isDirectory: true)
        for (name, value) in bundle.files {
            try value.serialized().write(to: outURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}
