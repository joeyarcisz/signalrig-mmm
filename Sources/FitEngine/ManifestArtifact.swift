import CryptoKit
import Foundation

// Translates engine/artifacts/export.py's build_manifest() (:60-77) and
// _data_sha256() (:31-40), read-only reference at
// the Python reference implementation, verbatim.
//
// engine_version/packages are the one deliberate substitution the task
// packet calls for: Python's build_manifest reports its own pymc/arviz/
// numpy versions via package_versions() (export.py :52-57), which have no
// meaning for a Swift binary that never imports them. This port reports
// its own identity instead ({"fitengine": "0.1.0", "cmdstan": "2.39.0"}),
// per ArtifactConstants.
//
// seed and git_sha are accepted as plain parameters here rather than
// re-derived (Python's cfg.seed and a `git rev-parse --short HEAD` shell
// call at export.py :43-49) -- this package does not shell out to git.
public struct ManifestArtifact {
    public let runId: String
    public let createdAt: String
    public let engineVersion: String
    public let dataSha256: String
    public let seed: Int
    public let gitSha: String
    public let packages: [String: String]
    public let gates: Gates
    public let dataDisclosure: String
    public let kpiName: String
    public let weeks: Int
    public let dateStart: String
    public let dateEnd: String
    public let isSynthetic: Bool

    public func toJSON() -> JSONValue {
        .object([
            "run_id": .string(runId),
            "created_at": .string(createdAt),
            "engine_version": .string(engineVersion),
            "data_sha256": .string(dataSha256),
            "seed": .int(seed),
            "git_sha": .string(gitSha),
            "packages": .object(packages.mapValues { JSONValue.string($0) }),
            "gates": gates.toJSON(),
            "data_disclosure": .string(dataDisclosure),
            "kpi_name": .string(kpiName),
            "weeks": .int(weeks),
            "date_start": .string(dateStart),
            "date_end": .string(dateEnd),
            "is_synthetic": .bool(isSynthetic),
        ])
    }
}

public enum ManifestBuilder {
    // _data_sha256 (export.py :31-40): sha256 over exactly the contract
    // tables, each file preceded by its own filename bytes, in
    // ArtifactConstants.contractFiles order -- so stray files in the drop
    // directory never change the fingerprint.
    public static func dataSha256(dropDir: String, contractFiles: [String] = ArtifactConstants.contractFiles) -> String {
        var hasher = SHA256()
        for name in contractFiles {
            let path = (dropDir as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            hasher.update(data: Data(name.utf8))
            if let data = FileManager.default.contents(atPath: path) {
                hasher.update(data: data)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // run_id format copied verbatim from engine/run_all.py :79:
    // f"{datetime.now().strftime('%Y%m%d_%H%M')}_{cfg.seed}".
    public static func makeRunID(seed: Int, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d%02d%02d_%02d%02d_%d", c.year!, c.month!, c.day!, c.hour!, c.minute!, seed)
    }

    // datetime.now(timezone.utc).isoformat(timespec="seconds") (export.py
    // :64): e.g. "2026-08-30T08:23:11+00:00".
    public static func isoUTCNow(date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    public static func build(
        runId: String,
        createdAt: String,
        seed: Int,
        gitSha: String,
        gates: Gates,
        isSynthetic: Bool,
        dataSha256: String,
        kpiName: String,
        weeks: Int,
        dateStart: String,
        dateEnd: String
    ) -> ManifestArtifact {
        ManifestArtifact(
            runId: runId,
            createdAt: createdAt,
            engineVersion: ArtifactConstants.engineVersion,
            dataSha256: dataSha256,
            seed: seed,
            gitSha: gitSha,
            packages: ArtifactConstants.packages,
            gates: gates,
            dataDisclosure: isSynthetic ? ArtifactConstants.disclosure : "Fitted on the client data package.",
            kpiName: kpiName,
            weeks: weeks,
            dateStart: dateStart,
            dateEnd: dateEnd,
            isSynthetic: isSynthetic
        )
    }
}
