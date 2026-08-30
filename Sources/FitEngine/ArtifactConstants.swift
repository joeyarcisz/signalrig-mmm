import Foundation

// Shared constants for the UI-artifact exporter (channels/curves/scenarios/
// diagnostics/recovery/manifest/memo.json), mirroring the read-only Python
// references at the Python reference implementation:
// engine/artifacts/export.py (DISCLOSURE, CONTRACT_FILES) and
// engine/__init__.py (__version__).
public enum ArtifactConstants {
    // engine/artifacts/export.py DISCLOSURE. Used verbatim in both
    // manifest.json (when is_synthetic) and recovery.json's available
    // variant (data_disclosure field) -- ported as data, not authored
    // prose, so it is reproduced exactly including its em dash, matching
    // the string already shipped in the app's committed sample artifacts.
    public static let disclosure = "Synthetic twin calibrated to the bundled sample brief. Drop a real export in Data Drop-In and this exact pipeline retrains on it."

    // engine/artifacts/export.py CONTRACT_FILES, fixed hashing order.
    public static let contractFiles = ["kpi.csv", "paid_media.csv", "organic_owned.csv",
                                        "non_media_treatments.csv", "controls.csv"]

    // engine_version in manifest.json. The task packet directs
    // engine_version/packages to become this package's own identity
    // rather than the Python engine's pymc/arviz/numpy versions.
    public static let engineVersion = "0.1.0"
    public static let packages: [String: String] = ["fitengine": "0.1.0", "cmdstan": "2.39.0"]

    // bench.json generation is explicitly out of scope for this port (see
    // task packet section 1), but engine/memo.py's build_memo() needs two
    // numbers from it: blended.cpl_prior and blended.cpl_calibrated. These
    // are the current values from the shipped, statically-generated
    // bench.json (src/artifacts/latest/bench.json), confirmed reproducible
    // by calling engine.bench.calculator.build_bench_artifact() directly
    // (pure deterministic arithmetic, no model/randomness -- see
    // goldens-artifacts/NOTES.md). Overridable via the CLI's --bench flag
    // for a real (non-default) benchmark run.
    public static let defaultBlendedCplPrior: Double = 82
    public static let defaultBlendedCplCalibrated: Double = 85

    // Minimum panel weeks and the holdout-refit window, in one place (not
    // scattered across the loader/builder/pipeline). Frozen design
    // decision: the no-holdout "diagnostics skipped" artifact variant is
    // removed entirely -- fitting always reserves the trailing
    // holdoutWeeks weeks for the holdout refit, so a panel must clear
    // minimumWeeks before PanelLoader will hand it back at all (see
    // PanelLoader.load's insufficientWeeks check). 52 - 12 = 40 weeks of
    // holdout-model training data at the floor, matching the packet's
    // "obs = T - 12 therefore always >= 40".
    public static let minimumWeeks = 52
    public static let holdoutWeeks = 12

    // Default package label used in memo.json's title/headline when the
    // caller (CLI --label flag, or ArtifactsPipeline.run's packageLabel
    // parameter) does not supply one. Never a fixture brand name: the
    // title is always "<packageLabel> \u{2014} <kpi title>: ...", so an
    // unset label reads as a neutral placeholder rather than borrowing any
    // one client's identity.
    public static let defaultPackageLabel = "Client package"

    // Default KPI display name when a package's kpi.csv has no kpi_name
    // column (see PanelLoader.resolveKPIName).
    public static let defaultKPIName = "kpi"
}
