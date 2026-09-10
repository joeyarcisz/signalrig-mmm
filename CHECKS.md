# Candidate checks

September 6, 2026. Results apply to the local review candidate, not a public release or Joe's installation.

| Check | Observed result |
|---|---|
| Standalone Swift source | 98 passed, 0 skipped, 0 failed |
| Shipping Swift suite | 99 passed, 10 historical skips, 0 failed |
| Python research engine | 50 passed, 0 failed |
| Web unit checks | 61 passed: 20 input, 26 approval/migration, 15 consent/privacy |
| Native fit flow | Passed: real UI, sandbox, helper, progress, successful reload, rejected second fit preserving prior model |
| Web UI checks | Passed: 11 injection/gate, 5 bridge, 12 desktop/mobile view checks; no document or in-card control overflow |
| Native refresh/origin proof | Passed: model A to B, sample toggles, external-document rejection, local main-frame acceptance |
| Stan helper | Rebuilt from checked-in source with CmdStan 2.39.0, Apple clang 21.0.0, arm64 |

Ten historical shipping tests require external artifact/draw golden files and are excluded from this self-contained package. Their absence is not counted as a pass. A retained full-preprocessing comparison checked 2,729 floating-point values with zero relative error on its historical input. That does not validate the revised holdout, which has dedicated invariance, prior-center, fit-independence, and rescaling tests.

## Actual sampling under quality policy 4

Each dataset used separate full and holdout fits, four chains each, 1,000 warmup and 1,000 post-warmup draws per chain, target acceptance 0.97, and 12 held-out weeks. The sandboxed harness uses shipping sources. CSV fingerprints match the included fixtures byte-for-byte. Exact receipts and helper hashes are in SAMPLE_RESULTS.json.

| Synthetic fixture | Seed | Max R-hat | Min bulk ESS | Divergences | Holdout MAPE | Holdout R-squared | 90% interval coverage | Outcome |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| UI smoke, 104 weeks | 1651133753 | 1.0051 | 1,380 | 0 | 3.58% | 0.399 | 100% | Gates passed; model reloaded |
| Foreign demo, 64 weeks | 871717982 | 1.0044 | 2,309 | 0 | 14.37% | -8.362 | 41.7% | Held back; prior model preserved |

The UI smoke fixture generates its seasonal KPI separately from media spend. It has no planted media-effect recovery claim. Its predictive pass is a prompt to examine false attribution and prior-driven scenarios. The separate planted fixture has known truth but shares the fit's model family; fixture tests are not a new MCMC recovery study.

The foreign fixture is the same three CSV files previously supplied for review. An earlier candidate allowed it through on MAPE alone (14.09%, R-squared -8.048, coverage 41.7%). That exposed an approval gap. Policy 4 also requires positive holdout R-squared and at least 80% coverage of nominal 90% intervals. These are product withholding rules for review, not a calibration guarantee. The demo is now correctly held back.

The first harness attempt lost completion events on reload. Its receipt was preserved and event delivery/recording corrected. The final run above verified both completion and refusal paths. These results use generated data, not independent real-client data.

## Prior-center change, 2026-09-09

The channel-coefficient prior center is now a blended cost per outcome learned from each fit's own training window (total reference spend over half of the mean outcome), shared by every channel. The per-channel-name prior table and its $181 fallback for unrecognized names are removed. Receipts carry `reference_mean_kpi` and preprocessing version 2; fits recorded under version 1 must be refit. `SAMPLE_RESULTS.json` predates this change. The three documented fixtures were rerun on the changed engine with the same seeds and sampler settings, one fit at a time:

| Synthetic fixture | Seed | Max R-hat | Min bulk ESS | Divergences | Holdout MAPE | Holdout R-squared | 90% interval coverage | Outcome |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| UI smoke, 104 weeks | 1651133753 | 1.0052 | 1,904 | 0 | 3.79% | 0.339 | 100% | Gates passed |
| Foreign demo, 64 weeks | 871717982 | 1.0033 | 2,631 | 0 | 18.6% | -13.801 | 8.3% | Held back |
| Planted, 104 weeks (e2e) | 42 | 1.0029 | 750 | 0 | 2.72% | 0.555 | 91.7% | 24 of 24 planted truths inside their 90% intervals |

What motivated the change: a 16-fit recovery sweep (the planted generator truncated to 52, 65, 78, and 104 weeks, two seeds, 4% and 10% noise) showed that a channel whose name the table did not know was anchored at $181 and, when its signal sat below the noise floor, stayed there: display was recovered at roughly $133 against a planted $1,000, outside its own interval in 16 of 16 runs, while a single run with names mapped onto the table's keys moved it inside and lifted recovery to 23 of 24.

What the change does not do: for this fixture the blended center evaluates to about $182, so the sweep rerun on the changed engine is nearly unchanged on seven of eight channels. Channels whose contribution is below the noise floor remain prior-dominated under any uniform center, and one high-spend, low-variance channel is recovered with a narrow, wrong cost interval in every run, consistent with its contribution trading off against the intercept. Informative per-channel prior centers supplied with the data, and a diagnostic that reports when a channel's posterior has not moved from its prior, are the open items this evidence points to. The sweep scripts and raw results live outside this package.

## Sampler acceptance target, 2026-09-10

A platform-reported-cost fit run through the Mac app's engine showed 7 divergences in 4,000 draws. The cause was not the priors: that engine had never passed an acceptance target to CmdStan and was sampling at the 0.8 default, while this package runs at 0.97. The app engine now uses 0.97 as well, and both engines record the target the chains actually ran with in `diagnostics.json` (`adapt_delta`, parsed from CmdStan's output header) so a receipt can no longer silently reflect a different setting. Verification on the planted 104-week fixture with reported costs set 20% below truth (seeds 42, 7, 99) and 50% below truth (seed 42), full fits at 0.97: 0 divergences in each, maximum tree depth 9, recovery 23 of 24 in each.

## Interpretation limits

Numerical approval does not establish causal identification, practitioner acceptance, tail ESS, BFMI/energy or tree-depth acceptance, SBC across seeds, robustness to misspecification, forecasting-baseline performance, or independent real-account value. The blended spend-proportional prior center is learned from the training window; it is not a per-channel calibration. These remain priority review questions.

See [Stan's diagnostic guidance](https://mc-stan.org/docs/2_39/cmdstan-guide/diagnose_utility.html). Source/build fingerprints distinguish these runs from old artifacts and subsequent packaging work.
