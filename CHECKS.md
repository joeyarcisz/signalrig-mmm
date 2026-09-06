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

## Interpretation limits

Numerical approval does not establish causal identification, practitioner acceptance, tail ESS, BFMI/energy or tree-depth acceptance, SBC across seeds, robustness to misspecification, forecasting-baseline performance, or independent real-account value. Bundled sample CPL priors are not calibrated to other accounts or KPIs. These remain priority review questions.

See [Stan's diagnostic guidance](https://mc-stan.org/docs/2_39/cmdstan-guide/diagnose_utility.html). Source/build fingerprints distinguish these runs from old artifacts and subsequent packaging work.
