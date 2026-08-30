// mmm.stan — precompiled-binary spike port of SignalRig's PyMC MMM.
//
// Reference implementation ported 1:1 (functional form + priors):
//   engine/model/transforms.py  (geometric_adstock_np / hill_np)
//   engine/model/mmm.py         (build_and_fit)
// from the Python reference implementation (NOT
// shipped, NOT imported at runtime — Python there is used only to prepare
// this spike's data.json files, exactly the way an in-app Swift data-prep
// step would normalize spend/KPI before calling this binary).
//
// Deliberate deviations from the Python engine (all additive/harmless to
// the ported math, documented per PORT step 2):
//   1. Data normalization (x_norm = spend / per-channel max spend,
//      y_s = KPI / max KPI, Fourier design, standardized controls,
//      beta_center prior anchor) is computed in Python BEFORE this file
//      ever runs, identically to engine/model/mmm.py lines 137-162 (which
//      is itself plain numpy, not part of the PyMC graph). Stan receives
//      already-normalized arrays as `data`. This is a harness-parity
//      choice, not a math change — the shipping app would do the same
//      normalization in Swift.
//   2. mu (transformed parameter, not generated quantity) is computed over
//      the FULL T-week window regardless of how many weeks are in the
//      likelihood (`obs`), mirroring engine/model/mmm.py's
//      observe_weeks=None/holdout split: adstock/seasonality run on the
//      whole panel, only the Normal likelihood is truncated to the first
//      `obs` weeks. This lets one compiled binary serve both the full fit
//      and the 92-week holdout refit.
//   3. Posterior-derived metrics (CPL at reference spend, adstock
//      half-life, contribution share, holdout MAPE/R2/coverage) are
//      computed OUTSIDE Stan in the grading script, reusing the exact
//      formulas from engine/model/posterior.py against Stan's raw
//      parameter draws (alpha, kappa, slope, beta, sigma, mu). Nothing
//      about the math differs; only where it's computed (Stan gives you
//      draws, not derived business metrics, by design).
//   4. No changes to L_MAX (8), the adstock normalization, the Hill form,
//      or any prior family/hyperparameter. Beta(2,4)/Gamma(2,4)/Gamma(6,4)
//      use Stan's (shape, rate) parameterization, which is the same
//      parameterization PyMC's Beta(alpha,beta)/Gamma(alpha,beta) use —
//      no translation needed.

functions {
  // Normalized geometric adstock for one channel's spend series.
  // out[t] = sum_{lag=0}^{L-1} w[lag] * x[t-lag]   (w normalized to sum to 1)
  // Matches transforms.py geometric_adstock_np exactly (single-alpha branch).
  vector geo_adstock(vector x, real alpha, int L) {
    int T = num_elements(x);
    vector[L] w;
    vector[T] out;
    real wsum = 0;
    for (l in 1:L) {
      w[l] = alpha ^ (l - 1);
      wsum += w[l];
    }
    for (l in 1:L) {
      w[l] /= wsum;
    }
    for (t in 1:T) {
      real acc = 0;
      for (l in 1:L) {
        int idx = t - l + 1;   // 1-indexed translation of python's x[:len-lag]
        if (idx >= 1) {
          acc += w[l] * x[idx];
        }
      }
      out[t] = acc;
    }
    return out;
  }

  // Hill saturation: x^slope / (kappa^slope + x^slope). Matches hill_np.
  vector hill_sat(vector x, real kappa, real slope) {
    int T = num_elements(x);
    vector[T] out;
    for (t in 1:T) {
      real xv = fmax(x[t], 0);
      real xs = xv ^ slope;
      out[t] = xs / (kappa ^ slope + xs);
    }
    return out;
  }
}

data {
  int<lower=1> T;                  // weeks in panel
  int<lower=1> C;                  // channels
  int<lower=0> K;                  // control/treatment columns
  int<lower=1> L;                  // adstock carryover window (L_MAX)
  int<lower=1, upper=T> obs;       // likelihood window (T for full fit, T-12 for holdout)
  matrix[T, C] x_norm;             // spend / per-channel max spend (data-side normalize)
  vector[T] y_s;                   // KPI / max KPI (data-side normalize)
  matrix[T, K] Z;                  // standardized controls + non_media_treatments
  matrix[T, 4] Fx;                 // Fourier design, 2 modes (sin1,cos1,sin2,cos2), period 52wk
  vector[T] t_norm;                // arange(T)/52, for the trend term
  vector[C] beta_center;           // LogNormal prior center per channel (CPL-anchored)
}

parameters {
  vector<lower=0, upper=1>[C] adstock_alpha;
  vector<lower=0>[C] hill_kappa;
  vector<lower=0>[C] hill_slope;
  vector<lower=0>[C] channel_beta;
  real intercept;
  real trend;
  vector[4] fourier_beta;
  vector[K] control_gamma;
  real<lower=0> sigma;
}

transformed parameters {
  vector[T] media_scaled = rep_vector(0, T);
  vector[T] mu_scaled;

  for (c in 1:C) {
    vector[T] adstocked = geo_adstock(x_norm[:, c], adstock_alpha[c], L);
    vector[T] saturated = hill_sat(adstocked, hill_kappa[c], hill_slope[c]);
    media_scaled += saturated * channel_beta[c];
  }

  mu_scaled = intercept + trend * t_norm + Fx * fourier_beta + media_scaled;
  if (K > 0) {
    mu_scaled += Z * control_gamma;
  }
}

model {
  // Priors — identical families/hyperparameters to engine/model/mmm.py.
  adstock_alpha ~ beta(2.0, 4.0);
  hill_kappa ~ gamma(2.0, 4.0);
  hill_slope ~ gamma(6.0, 4.0);
  channel_beta ~ lognormal(log(beta_center), 0.75);
  intercept ~ normal(0.5, 0.25);
  trend ~ normal(0.0, 0.15);
  fourier_beta ~ normal(0.0, 0.08);
  if (K > 0) {
    control_gamma ~ normal(0.0, 0.1);
  }
  sigma ~ normal(0.0, 0.05);      // declared <lower=0> -> half-normal, matches pm.HalfNormal(0.05)

  // Likelihood over the first `obs` weeks only (holdout support).
  y_s[1:obs] ~ normal(mu_scaled[1:obs], sigma);
}
