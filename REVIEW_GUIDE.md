# Practitioner review guide

The intended job is narrow: use one account's aggregate weekly media and outcome history to support one defensible planning decision, with uncertainty and explicit reasons to withhold advice. Please identify what is worth retaining, what needs correction, and what evidence would justify practitioner use.

## A 20-minute reading path

1. **Minutes 0-4:** Read `README.md`, especially the data contract and evidence boundaries. Inspect `Sources/FitEngine/PanelLoader.swift` for aggregation and validation.
2. **Minutes 4-10:** Read `stan/mmm.stan` and `Sources/FitEngine/Channels.swift`: likelihood, adstock, saturation, controls, and prior assumptions.
3. **Minutes 10-15:** Read `Sources/FitEngine/StanDataBuilder.swift` and `PosteriorView.swift`: training-window preprocessing, holdout inputs, and rescaling.
4. **Minutes 15-20:** Read `Sources/FitEngine/ArtifactDiagnostics.swift`, `Diagnostics.swift`, `Metrics.swift`, and `Optimizer.swift`. Inspect relevant fixtures/tests, then record your highest-impact findings before running additional experiments.

## Candidate changes and limits

Quality policy 4 learns holdout scaling, control standardization, and reference spend from training weeks only; held-out outcomes are excluded from Stan input. Both full and holdout fits require at least four chains, folded/rank-normalized R-hat below 1.01, bulk ESS of at least 100 per chain, and zero divergences. Holdout MAPE must be below 15%, R-squared above zero, and coverage of nominal 90% intervals at least 80%. These checks are necessary, not sufficient for trustworthy recommendations.

The companion native candidate uses a source-built Stan helper and exports diagnostic receipts for held-back runs. Check source/build fingerprints and recorded outcomes separately. Fresh sampler results and exact fixture hashes are in SAMPLE_RESULTS.json and CHECKS.md. They do not establish what is installed or publicly released.

- **Synthetic versus real:** planted fixtures use the same model family as the fit. The foreign fixture is also synthetic. The passing UI smoke fixture generates KPI separately from media spend; use it to probe false media attribution. Historical recovery and holdout figures are not independent client validation or results for this candidate. Wide intervals can cover truth without supporting a useful decision.
- **Inputs:** canonical weekly CSVs are required. Arbitrary platform-export mapping, Excel/JSON ingestion, and daily aggregation are not implemented.
- **Priors:** the channel-coefficient prior center is the platform-reported cost per outcome when `platform_costs.csv` supplies one, otherwise a spend-proportional blended cost learned from the training window (media assumed to drive half of the outcome). `channels.json` flags channels whose posterior barely moved from that center (`prior.dominated`); the half-share assumption and the prior width deserve sensitivity review.
- **Coverage gaps:** 52 weeks leaves only 40 training weeks for a model with annual seasonality. Missing control cells are filled with zero. Future-only channels or controls can remain prior-driven.
- **Holdout:** future spend and controls remain known inputs. This is conditional outcome prediction, not an unconditional forecast or proof of causal lift.

## Highest-value questions

- Does preprocessing exclude all held-out outcome information, including indirect paths through prior centers and rescaling?
- Can the model withhold causal channel claims on the no-planted-media-effect UI smoke fixture? Which channels are identifiable under correlated spend, limited variation, and omitted confounders? How sensitive are results to the sample priors?
- Do intervals and errors remain useful against simple baselines, alternative splits, different seeds, and independent datasets?
- Do scenario bounds and withholding rules prevent unsupported extrapolation? What additional evidence is needed before interpreting an allocation change causally?

## Acceptance for one account

Agree on one planning question, a baseline, data limitations, and review criteria before fitting. Deliver a traceable normalization map, diagnostics, uncertainty, and one bounded decision artifact reviewed by its intended planner. A documented refusal with exact data or model gaps is an acceptable outcome. Numerical gates alone do not make a recommendation suitable for causal interpretation. Full platform replacement is outside this test.
