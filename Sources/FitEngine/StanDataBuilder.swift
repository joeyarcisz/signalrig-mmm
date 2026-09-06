import Foundation

// Full-fit math matches the original Stan prep. Holdout normalization is
// fitted independently to its training window and recorded for rescaling.
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
    public let fullPreprocessing: PanelPreprocessing?
    public let holdout: PanelPreprocessing?
    // The transform applied to one PosteriorView. A loaded panel defaults
    // to the full fit; holdoutPanelMeta explicitly selects its own receipt.
    public let appliedPreprocessing: PanelPreprocessing?

    public init(
        channels: [String], dates: [String], xScale: [Double], yScale: Double,
        refSpend: [Double], xRaw: [[Double]], yRaw: [Double], holdoutWeeks: Int, lMax: Int,
        fullPreprocessing: PanelPreprocessing? = nil, holdout: PanelPreprocessing? = nil,
        appliedPreprocessing: PanelPreprocessing? = nil
    ) {
        self.channels = channels
        self.dates = dates
        self.xScale = xScale
        self.yScale = yScale
        self.refSpend = refSpend
        self.xRaw = xRaw
        self.yRaw = yRaw
        self.holdoutWeeks = holdoutWeeks
        self.lMax = lMax
        self.fullPreprocessing = fullPreprocessing
        self.holdout = holdout
        self.appliedPreprocessing = appliedPreprocessing ?? fullPreprocessing
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "channels": .stringArray(channels),
            "dates": .stringArray(dates),
            "x_scale": .doubleArray(xScale),
            "y_scale": .double(yScale),
            "ref_spend": .doubleArray(refSpend),
            "X_raw": .doubleMatrix(xRaw),
            "y_raw": .doubleArray(yRaw),
            "holdout_weeks": .int(holdoutWeeks),
            "l_max": .int(lMax),
        ]
        if let fullPreprocessing { object["full_preprocessing"] = fullPreprocessing.toJSON() }
        if let holdout { object["holdout"] = holdout.toJSON() }
        return .object(object)
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

        precondition(holdoutWeeks > 0 && holdoutWeeks < T, "holdout must leave a nonempty training window")
        let fullPreprocessing = PanelPreprocessing.fit(panel: panel, observedWeeks: T)
        let holdoutPreprocessing = PanelPreprocessing.fit(panel: panel, observedWeeks: T - holdoutWeeks)
        let Fx = fourier(T: T)
        let tNorm = (0..<T).map { Double($0) / 52.0 }

        func data(using preprocessing: PanelPreprocessing) -> StanData {
            let xNorm = panel.X.map { row in
                (0..<C).map { row[$0] / preprocessing.xScale[$0] }
            }
            // Stan only reads y_s[1:obs]. Exclude held-out outcomes from
            // the sampler input entirely; metadata retains them for scoring.
            let yS = (0..<T).map { $0 < preprocessing.observedWeeks ? panel.y[$0] / preprocessing.yScale : 0 }
            // Future spend and controls remain known conditional inputs.
            // Their values never contribute to the fitted scale or priors.
            return StanData(
                T: T, C: C, K: K, L: L, obs: preprocessing.observedWeeks,
                xNorm: xNorm, yS: yS, Z: preprocessing.standardizedControls(panel.rawControls),
                Fx: Fx, tNorm: tNorm, betaCenter: preprocessing.betaCenter
            )
        }

        let full = data(using: fullPreprocessing)
        let holdout = data(using: holdoutPreprocessing)
        let meta = PanelMeta(
            channels: panel.channels, dates: panel.dates,
            xScale: fullPreprocessing.xScale, yScale: fullPreprocessing.yScale,
            refSpend: fullPreprocessing.refSpend, xRaw: panel.X, yRaw: panel.y,
            holdoutWeeks: holdoutWeeks, lMax: L,
            fullPreprocessing: fullPreprocessing, holdout: holdoutPreprocessing
        )

        return Built(full: full, holdout: holdout, meta: meta)
    }
}
