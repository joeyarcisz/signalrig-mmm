import Foundation

// Registry of channels this package ships display metadata for, mirroring
// engine/config.py CHANNEL_KEYS and engine/model/mmm.py PRIOR_CPL (read-only
// Python reference at the Python reference implementation). Values
// copied by hand, not computed, since the Python source is out of scope for
// this package.
//
// This is a DISPLAY registry, not a validity gate: PanelLoader accepts any
// channel key it finds in a package's paid_media.csv, known or not (see
// ChannelRegistry.label(forKey:)/platform(forKey:)/priorCPL(forKey:) below
// for the fallback rules an unrecognized channel gets). Real client
// packages routinely use channels this list has never heard of.
public enum ChannelRegistry {
    public static let channelKeys: [String] = [
        "google_search",
        "meta",
        "tiktok",
        "military_publishers",
        "youtube",
        "programmatic_display",
        "streaming_audio",
        "mntn_ctv",
    ]

    public static let priorCPL: [String: Double] = [
        "google_search": 64,
        "meta": 48,
        "tiktok": 62,
        "military_publishers": 95,
        "youtube": 267,
        "programmatic_display": 694,
        "streaming_audio": 1000,
        "mntn_ctv": 2525,
    ]

    // Precomputed median of the 8 values above, matching Python's
    // np.median(list(PRIOR_CPL.values())): sorted [48,62,64,95,267,694,1000,2525],
    // even count, median = (95 + 267) / 2 = 181.0. Also the prior CPL for
    // any channel outside this registry (see priorCPL(forKey:) below).
    public static let fallbackCPL: Double = 181.0

    public static let lMax = 8

    // T-floor and holdout-window constants now live in ArtifactConstants
    // (see ArtifactConstants.minimumWeeks/holdoutWeeks) so both are defined
    // in exactly one place; this registry only owns channel display/prior
    // metadata.
}

// Label/platform registry mirroring engine/config.py CHANNELS (label,
// platform fields only; the other ChannelSpec fields there -- ref spend,
// true CPL, saturation, etc. -- are synthetic-generator inputs out of
// scope here, since this package never generates synthetic data). Used by
// channels.json and curves.json for display strings via
// ChannelRegistry.label(forKey:)/platform(forKey:) below, NOT by direct
// dictionary lookup with a sample-registry fallback -- a channel key this
// registry has never seen (any real client package will have several)
// gets a generated label/platform instead of silently borrowing this
// fixture's own display strings.
public struct ChannelSpec {
    public let key: String
    public let label: String
    public let platform: String
}

public extension ChannelRegistry {
    static let specs: [ChannelSpec] = [
        ChannelSpec(key: "google_search", label: "Google Search", platform: "Google Ads"),
        ChannelSpec(key: "meta", label: "Meta (FB/IG)", platform: "Meta"),
        ChannelSpec(key: "tiktok", label: "TikTok", platform: "TikTok"),
        ChannelSpec(key: "military_publishers", label: "Military Publishers", platform: "Niche audience publishers"),
        ChannelSpec(key: "youtube", label: "YouTube", platform: "YouTube"),
        ChannelSpec(key: "programmatic_display", label: "Programmatic Display", platform: "DV360"),
        ChannelSpec(key: "streaming_audio", label: "Streaming Audio", platform: "Spotify \u{b7} Pandora"),
        ChannelSpec(key: "mntn_ctv", label: "MNTN CTV", platform: "MNTN"),
    ]

    static let specByKey: [String: ChannelSpec] = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0) })

    // Title-cases an underscored key ("out_of_home" -> "Out Of Home"), the
    // generated label for any channel key (or KPI name) outside this
    // registry. Deterministic, no locale dependency.
    static func titleCase(_ key: String) -> String {
        key.split(separator: "_")
            .map { word -> String in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    // Display label for a channel key: the registered label if this is a
    // known channel, otherwise the key's own title-cased form. Never falls
    // back to another channel's label.
    static func label(forKey key: String) -> String {
        specByKey[key]?.label ?? titleCase(key)
    }

    // Display platform for a channel key: the registered platform if known,
    // otherwise an empty string (not the old em-dash placeholder, and never
    // a known channel's platform) -- an unknown channel simply has no
    // platform on file yet.
    static func platform(forKey key: String) -> String {
        specByKey[key]?.platform ?? ""
    }

    // Prior CPL for a channel key: the registered prior if known, otherwise
    // the fallback median (same value Python's own PRIOR_CPL.get(key,
    // fallback) would use).
    static func priorCPL(forKey key: String) -> Double {
        priorCPL[key] ?? fallbackCPL
    }
}
