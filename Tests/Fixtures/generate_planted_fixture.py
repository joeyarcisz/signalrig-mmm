#!/usr/bin/env python3
"""Generates planted_drop/ and planted_truth.json: a synthetic weekly panel
whose response parameters are known, so the recovery grading in `grade` and
`e2e` can be re-run by anyone.

The point of this fixture is reproducibility of the project's headline claim.
The KPI series is produced by the SAME two transforms the Stan model fits
(normalized geometric adstock, then Hill saturation), so asking the model to
recover the planted parameters is a like-for-like exam rather than a
favourable one.

Per channel the generator solves (kappa, asymptote) from two readable
targets, a cost per lead at a reference weekly spend and how saturated the
channel is at that spend:

    with x = spend / ref_weekly_spend,
    hill(1) = 1 / (1 + kappa**slope) = saturation
      =>  kappa     = ((1 - saturation) / saturation) ** (1 / slope)
          asymptote = (ref_weekly_spend / true_cpl) / saturation

Spend paths deliberately carry pulsing, a ramp, a dark month and a surge
month. Without that variation the response curves are not identifiable and
recovery is not a meaningful test.

Everything is stdlib only and driven by an explicit linear congruential
generator, so re-running this script on any Python 3 reproduces
byte-identical output. The generated files are committed as plain data; this
script is committed next to them as the record of how they were produced.

Usage: python3 generate_planted_fixture.py
"""
import csv
import datetime
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DROP_DIR = os.path.join(HERE, "planted_drop")
TRUTH_PATH = os.path.join(HERE, "planted_truth.json")

SEED = 20260904
WEEKS = 104
L_MAX = 8
GEO = "US"
KPI_NAME = "signups"
REVENUE_PER_KPI = 180.0
BASELINE_WEEKLY = 1400.0
BASELINE_TREND_YEARLY = 0.06
NOISE_FRAC = 0.04

# ref_weekly_spend and true_cpl set the scale; saturation and slope set the
# curve shape; alpha sets carryover (half life = ln(0.5) / ln(alpha)).
CHANNELS = [
    dict(key="paid_search",          label="Paid Search",          ref=30000.0, cpl=60.0,   sat=0.62, slope=1.10, alpha=0.15),
    dict(key="social_feed",          label="Social Feed",          ref=34000.0, cpl=50.0,   sat=0.55, slope=1.20, alpha=0.35),
    dict(key="short_form_video",     label="Short Form Video",     ref=16000.0, cpl=80.0,   sat=0.45, slope=1.30, alpha=0.40),
    dict(key="partner_email",        label="Partner Email",        ref=14000.0, cpl=100.0,  sat=0.40, slope=1.25, alpha=0.45),
    dict(key="connected_tv",         label="Connected TV",         ref=64000.0, cpl=400.0,  sat=0.35, slope=1.40, alpha=0.55),
    dict(key="display_programmatic", label="Display Programmatic", ref=78000.0, cpl=1000.0, sat=0.30, slope=1.50, alpha=0.50),
    dict(key="streaming_audio",      label="Streaming Audio",      ref=60000.0, cpl=900.0,  sat=0.28, slope=1.45, alpha=0.60),
    dict(key="podcast_sponsorship",  label="Podcast Sponsorship",  ref=80000.0, cpl=1200.0, sat=0.25, slope=1.50, alpha=0.65),
]


class Rng:
    """Explicit LCG plus Box-Muller, so output does not depend on the host
    Python's random module implementation."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def _next(self):
        self.state = (1664525 * self.state + 1013904223) & 0xFFFFFFFF
        return self.state

    def uniform(self):
        return self._next() / 4294967296.0

    def normal(self, mu=0.0, sigma=1.0):
        u1 = self.uniform()
        if u1 < 1e-12:
            u1 = 1e-12
        u2 = self.uniform()
        z = math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)
        return mu + sigma * z


def monday(t):
    # 2024-01-01 is a Monday; Monday-anchored ISO weeks mean lexicographic
    # sort of the date strings equals chronological order.
    return (datetime.date(2024, 1, 1) + datetime.timedelta(days=7 * t)).isoformat()


def solve_channel(spec):
    kappa = ((1.0 - spec["sat"]) / spec["sat"]) ** (1.0 / spec["slope"])
    asymptote = (spec["ref"] / spec["cpl"]) / spec["sat"]
    return kappa, asymptote


def geometric_adstock(x, alpha, l_max):
    """Normalized geometric adstock over a single channel column."""
    w = [alpha ** lag for lag in range(l_max)]
    total = sum(w)
    w = [v / total for v in w]
    T = len(x)
    out = [0.0] * T
    for lag in range(l_max):
        for t in range(lag, T):
            out[t] += w[lag] * x[t - lag]
    return out


def hill(x, kappa, slope):
    k = kappa ** slope
    out = []
    for v in x:
        v = max(v, 0.0)
        xs = v ** slope
        out.append(xs / (k + xs))
    return out


def spend_paths(rng):
    """Weekly spend per channel with seasonality, AR(1) wiggle and
    channel-specific flighting, so every response curve is identifiable."""
    paths = []
    for ci, spec in enumerate(CHANNELS):
        wiggle = [1.0] * WEEKS
        for t in range(1, WEEKS):
            wiggle[t] = 1.0 + 0.6 * (wiggle[t - 1] - 1.0) + rng.normal(0.0, 0.12)
        col = []
        for t in range(WEEKS):
            season = 1.0 + 0.15 * math.sin(2.0 * math.pi * t / 52.0 + ci * 0.9)
            flight = 1.0
            key = spec["key"]
            # The low-share channels contribute less per week than the
            # observation noise, so they are only identifiable if their spend
            # moves hard and on a schedule the other channels do not share.
            # Periods of 12, 8 and 10 weeks keep the three pulse patterns
            # mutually non-collinear.
            if key == "connected_tv":
                flight = 1.0 if (t // 6) % 2 == 0 else 0.20   # 6 on, 6 off
            if key == "streaming_audio":
                flight = 1.0 if (t // 4) % 2 == 0 else 0.18   # 4 on, 4 off
            if key == "podcast_sponsorship":
                flight = 1.0 if (t // 5) % 2 == 0 else 0.15   # 5 on, 5 off
            if key == "short_form_video":
                flight *= 0.6 + (1.3 - 0.6) * (t / (WEEKS - 1.0))  # ramps up
            if key == "social_feed" and 30 <= t < 34:
                flight = 0.10                                  # one dark month
            if key == "paid_search" and 60 <= t < 64:
                flight = 1.55                                  # one surge month
            if key == "partner_email" and (46 <= t < 50 or 98 <= t < 102):
                flight *= 1.8                                  # two pulses
            col.append(round(max(spec["ref"] * season * wiggle[t] * flight, 0.0)))
        paths.append(col)
    return paths


def main():
    rng = Rng(SEED)
    spends = spend_paths(rng)

    kappas, asymptotes = [], []
    for spec in CHANNELS:
        k, a = solve_channel(spec)
        kappas.append(k)
        asymptotes.append(a)

    # Media response through the same transforms the model fits.
    contributions = []
    for ci, spec in enumerate(CHANNELS):
        x_norm = [s / spec["ref"] for s in spends[ci]]
        adstocked = geometric_adstock(x_norm, spec["alpha"], L_MAX)
        saturated = hill(adstocked, kappas[ci], spec["slope"])
        contributions.append([v * asymptotes[ci] for v in saturated])

    # Controls and non-media treatments.
    promo = [1.0 if 18 < (t % 52) < 34 else 0.0 for t in range(WEEKS)]
    market = [3.9 + 0.4 * math.sin(t / 9.0) + rng.normal(0.0, 0.05) for t in range(WEEKS)]
    market_mean = sum(market) / WEEKS
    brand_weeks = {int(WEEKS * 0.38): 120.0, int(WEEKS * 0.67): 90.0, int(WEEKS * 0.92): 150.0}

    mu = []
    for t in range(WEEKS):
        trend = BASELINE_WEEKLY * BASELINE_TREND_YEARLY * (t / 52.0)
        fourier = (0.06 * BASELINE_WEEKLY * math.sin(2.0 * math.pi * t / 52.0 + 1.2)
                   + 0.04 * BASELINE_WEEKLY * math.cos(4.0 * math.pi * t / 52.0 + 0.4))
        controls = 30.0 * promo[t] + (-20.0) * (market[t] - market_mean)
        brand = brand_weeks.get(t, 0.0)
        media = sum(contributions[ci][t] for ci in range(len(CHANNELS)))
        mu.append(BASELINE_WEEKLY + trend + fourier + controls + brand + media)

    sigma = NOISE_FRAC * (sum(mu) / WEEKS)
    kpi = [max(int(round(m + rng.normal(0.0, sigma))), 0) for m in mu]

    os.makedirs(DROP_DIR, exist_ok=True)

    with open(os.path.join(DROP_DIR, "kpi.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date_week", "geo", "kpi_name", "kpi_value", "revenue_per_kpi"])
        for t in range(WEEKS):
            w.writerow([monday(t), GEO, KPI_NAME, kpi[t], REVENUE_PER_KPI])

    with open(os.path.join(DROP_DIR, "paid_media.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date_week", "geo", "channel", "spend"])
        for t in range(WEEKS):
            for ci, spec in enumerate(CHANNELS):
                w.writerow([monday(t), GEO, spec["key"], spends[ci][t]])

    with open(os.path.join(DROP_DIR, "controls.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date_week", "geo", "control_name", "control_value"])
        for t in range(WEEKS):
            w.writerow([monday(t), GEO, "promo_window", int(promo[t])])
            w.writerow([monday(t), GEO, "market_index", round(market[t], 4)])

    with open(os.path.join(DROP_DIR, "non_media_treatments.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date_week", "geo", "treatment_name", "treatment_value"])
        for t in range(WEEKS):
            w.writerow([monday(t), GEO, "brand_moment", 1 if t in brand_weeks else 0])

    totals = [sum(contributions[ci]) for ci in range(len(CHANNELS))]
    grand = sum(totals)
    channels_truth = []
    for ci, spec in enumerate(CHANNELS):
        channels_truth.append({
            "key": spec["key"],
            "label": spec["label"],
            "ref_weekly_spend": spec["ref"],
            "true_cpl_at_ref": spec["cpl"],
            "adstock_alpha": spec["alpha"],
            "adstock_half_life_weeks": math.log(0.5) / math.log(spec["alpha"]),
            "hill_kappa": kappas[ci],
            "hill_slope": spec["slope"],
            "saturation_at_ref": spec["sat"],
            "asymptote_weekly_leads": asymptotes[ci],
            "avg_weekly_contribution": totals[ci] / WEEKS,
            "contribution_share": totals[ci] / grand,
        })

    truth = {
        "seed": SEED,
        "weeks": WEEKS,
        "date_start": monday(0),
        "date_end": monday(WEEKS - 1),
        "kpi_name": KPI_NAME,
        "baseline_weekly": BASELINE_WEEKLY,
        "noise_sigma": sigma,
        "l_max": L_MAX,
        "channels": channels_truth,
    }
    with open(TRUTH_PATH, "w") as f:
        json.dump(truth, f, indent=2)
        f.write("\n")

    print("wrote %s (%d weeks x %d channels) and %s"
          % (DROP_DIR, WEEKS, len(CHANNELS), os.path.basename(TRUTH_PATH)))
    print("media share of mean KPI: %.1f%%"
          % (100.0 * (grand / WEEKS) / (sum(mu) / WEEKS)))


if __name__ == "__main__":
    main()
