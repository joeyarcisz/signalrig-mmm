import Foundation

// Mirrors the local spike workspace/scripts/prep_data.py
// (read-only reference).
public struct StanData {
    public let T: Int
    public let C: Int
    public let K: Int
    public let L: Int
    public let obs: Int
    public let xNorm: [[Double]]   // (T, C)
    public let yS: [Double]        // (T,)
    public let Z: [[Double]]       // (T, K), or empty rows if K == 0
    public let Fx: [[Double]]      // (T, 4)
    public let tNorm: [Double]     // (T,)
    public let betaCenter: [Double] // (C,)

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "T": .int(T),
            "C": .int(C),
            "K": .int(K),
            "L": .int(L),
            "obs": .int(obs),
            "x_norm": .doubleMatrix(xNorm),
            "y_s": .doubleArray(yS),
            "Fx": .doubleMatrix(Fx),
            "t_norm": .doubleArray(tNorm),
            "beta_center": .doubleArray(betaCenter),
        ]
        // Z is emitted as a bare [] when K == 0, matching prep_data.py's
        // `Z.tolist() if K > 0 else []` (not T rows of zero-length arrays).
        obj["Z"] = K > 0 ? .doubleMatrix(Z) : .array([])
        return .object(obj)
    }
}

public struct PanelMeta {
    public let channels: [String]
    public let dates: [String]
    public let xScale: [Double]
    public let yScale: Double
    public let refSpend: [Double]
    public let xRaw: [[Double]]
    public let yRaw: [Double]
    public let holdoutWeeks: Int
    public let lMax: Int

    public func toJSON() -> JSONValue {
        .object([
            "channels": .stringArray(channels),
            "dates": .stringArray(dates),
            "x_scale": .doubleArray(xScale),
            "y_scale": .double(yScale),
            "ref_spend": .doubleArray(refSpend),
            "X_raw": .doubleMatrix(xRaw),
            "y_raw": .doubleArray(yRaw),
            "holdout_weeks": .int(holdoutWeeks),
            "l_max": .int(lMax),
        ])
    }
}

public enum StanDataBuilder {
    // Fourier design: columns sin1, cos1, sin2, cos2 for modes 1...2, period 52 weeks.
    public static func fourier(T: Int, modes: Int = 2) -> [[Double]] {
        var Fx = Array(repeating: [Double](repeating: 0, count: modes * 2), count: T)
        for t in 0..<T {
            var cols = [Double]()
            cols.reserveCapacity(modes * 2)
            for m in 1...modes {
                let angle = 2.0 * Double.pi * Double(m) * Double(t) / 52.0
                cols.append(sin(angle))
                cols.append(cos(angle))
            }
            Fx[t] = cols
        }
        return Fx
    }

    public struct Built {
        public let full: StanData
        public let holdout: StanData
        public let meta: PanelMeta
    }

    public static func build(panel: Panel, holdoutWeeks: Int = ArtifactConstants.holdoutWeeks) -> Built {
        let T = panel.T
        let C = panel.C
        let K = panel.K
        let L = ChannelRegistry.lMax

        let xScale = panel.xScale
        let yScale = panel.yScale
        let refSpend = panel.refSpend

        var xNorm = Array(repeating: [Double](repeating: 0, count: C), count: T)
        for t in 0..<T {
            for c in 0..<C {
                xNorm[t][c] = panel.X[t][c] / xScale[c]
            }
        }
        let yS = panel.y.map { $0 / yScale }
        let Fx = fourier(T: T)
        let tNorm = (0..<T).map { Double($0) / 52.0 }

        var betaCenter = [Double](repeating: 0, count: C)
        for c in 0..<C {
            let key = panel.channels[c]
            let priorCpl = ChannelRegistry.priorCPL(forKey: key)
            let priorLeads = refSpend[c] / priorCpl
            betaCenter[c] = max((priorLeads / 0.5) / yScale, 1e-4)
        }

        let full = StanData(
            T: T, C: C, K: K, L: L, obs: T,
            xNorm: xNorm, yS: yS, Z: panel.Z, Fx: Fx, tNorm: tNorm, betaCenter: betaCenter
        )
        let holdout = StanData(
            T: T, C: C, K: K, L: L, obs: T - holdoutWeeks,
            xNorm: xNorm, yS: yS, Z: panel.Z, Fx: Fx, tNorm: tNorm, betaCenter: betaCenter
        )
        let meta = PanelMeta(
            channels: panel.channels, dates: panel.dates, xScale: xScale, yScale: yScale,
            refSpend: refSpend, xRaw: panel.X, yRaw: panel.y, holdoutWeeks: holdoutWeeks, lMax: L
        )

        return Built(full: full, holdout: holdout, meta: meta)
    }
}
