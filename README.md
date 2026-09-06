# SignalRig MMM: practitioner review candidate

September 6, 2026. Engine 0.2.0, quality policy 4. This candidate is prepared for independent review. The public repository and circulating Mac download are separate release surfaces; local changes do not update either one.

SignalRig is intended to help a planner turn aggregate weekly media and outcome history into one defensible measurement or budget decision, with inspectable inputs, assumptions, uncertainty, and explicit refusal when checks fail. This package contains the model, the Swift engine, synthetic fixtures, and repeatable checks. It contains no private agency correspondence or client datasets.

## Start here

1. Read `REVIEW_GUIDE.md` for the review questions and current limits.
2. Run `swift test`. These checks validate implementation behavior, not real-account predictive or causal performance.
3. Read `stan/mmm.stan`, `Sources/FitEngine/Panel.swift`, `StanDataBuilder.swift`, `ArtifactDiagnostics.swift`, and `Metrics.swift`.
4. Use the commands below for actual sampling. Record every seed and result, including held-back runs.
5. See `CHECKS.md` for evidence collected for this candidate.

## Model and changes

The national weekly model uses normalized geometric adstock with an eight-week carryover window, Hill saturation, trend, Fourier seasonality, and standardized controls under a Normal likelihood. Multiple geographies aggregate to national totals. The implementation does not estimate geography-level effects.

Full and holdout fits now learn separate preprocessing from their own observed windows. The holdout fit uses the first T-12 weeks to calculate spend/outcome scales, control means and population standard deviations, and reference spend for prior centers. Held-out outcomes are zeroed in its Stan input. Future spend and controls are retained as known inputs to a conditional forecast, not as an unconditional forecast of future marketing activity.

Each fit needs at least four chains, folded/rank-normalized R-hat below 1.01, bulk ESS of at least 100 per chain, and zero divergences. Holdout MAPE must be below 15%, R-squared above zero, and coverage of nominal 90% predictive intervals at least 80%. These short-window withholding thresholds are product rules to review, not a statistical calibration guarantee. These are necessary implementation checks, not a claim of causal identification. The sampler now explicitly uses acceptance target 0.97, matching the Python reference configuration rather than relying on CmdStan's default 0.8.

Malformed CSVs, non-finite values, negative spend/outcomes, mixed KPIs, irregular weekly calendars, and incompatible paid-media calendars are rejected. Fits without current preprocessing provenance require refitting. Reusing a full fit as the holdout is invalid.

## Reproduce

Requires macOS 13+, Swift 5.9+, and, for sampling, CmdStan 2.39.0 with its C++ toolchain. Tests do not need CmdStan. Build and run one job at a time.

```bash
swift test --jobs 1
swift build -c release --jobs 1
swift run -c release --skip-build fitengine-cli prep --drop Tests/Fixtures/foreign_drop --out /tmp/signalrig-review-prep
```

Compile with the installed CmdStan 2.39.0 toolchain, following the [official instructions](https://mc-stan.org/docs/2_39/cmdstan-guide/installation.html):

```bash
export SIGNALRIG_CMDSTAN=/absolute/path/to/cmdstan-2.39.0
make -C "$SIGNALRIG_CMDSTAN" -j1 CXX=clang++ "$(pwd)/stan/mmm"
```

Set `SIGNALRIG_MODEL` below to that executable's absolute path.

```bash
export SIGNALRIG_MODEL=/absolute/path/to/stan/mmm
swift run -c release --skip-build fitengine-cli fit --binary "$SIGNALRIG_MODEL" --data /tmp/signalrig-review-prep/data_full.json --work /tmp/signalrig-review-full --seed 42
swift run -c release --skip-build fitengine-cli fit --binary "$SIGNALRIG_MODEL" --data /tmp/signalrig-review-prep/data_holdout.json --work /tmp/signalrig-review-holdout --seed 42
swift run -c release --skip-build fitengine-cli artifacts --full-dir /tmp/signalrig-review-full --holdout-dir /tmp/signalrig-review-holdout --meta /tmp/signalrig-review-prep/panel_meta.json --drop Tests/Fixtures/foreign_drop --out /tmp/signalrig-review-artifacts --unavailable-recovery --seed 42
```

Inspect `diagnostics.json` and its gates. Artifact creation is not a passing model. The foreign fixture is synthetic but has no supplied ground-truth parameter key; it cannot establish parameter recovery.

To reproduce the observed UI smoke run, use `Tests/Fixtures/ui_smoke_drop` in the same prep/full-fit/holdout/artifacts sequence with seed `1651133753` and separate output directories. Its KPI is generated separately from media spend, so a predictive pass is not recovered-media-effect evidence. The foreign run used seed `871717982`. Exact input fingerprints are in `SAMPLE_RESULTS.json`.

For the committed planted fixture:

```bash
swift run -c release --skip-build fitengine-cli e2e --drop Tests/Fixtures/planted_drop --truth Tests/Fixtures/planted_truth.json --binary "$SIGNALRIG_MODEL" --work /tmp/signalrig-review-planted --seed 42
```

The planted generator uses the same model family. It is an implementation check, not independent validation. Historical 24/24 interval coverage and approximately 2.6% holdout error came from earlier synthetic runs and must not be represented as results for this candidate or for real customer data. Intervals can cover truth while being too wide to support a useful decision.

## Data contract

Required: `kpi.csv` with `date_week,geo,kpi_name,kpi_value`, and `paid_media.csv` with `date_week,channel,spend`. At least 52 consecutive weekly observations are required. `controls.csv` and `non_media_treatments.csv` are optional. `organic_owned.csv` is validated by the app but not used by the current model. The app expects canonical CSVs; arbitrary platform-export mapping, Excel/JSON import, and daily aggregation are not implemented.

## Scope and license

The channel CPL priors are bundled sample defaults, including a common fallback for unknown channels. They are not calibrated to another business or KPI. Prior sensitivity, omitted-variable bias, channel identifiability, simple forecasting baselines, interval calibration, and an independently reviewed real account remain open.

The public core is distributed under Apache-2.0; see `LICENSE`. This package preserves that existing license. It makes no determination about private contracts or rights outside these supplied technical files.
