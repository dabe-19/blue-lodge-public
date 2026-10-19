#!/usr/bin/env python3
"""
Statistically honest time-series models for DEX limit-order decisions.

Replaces the previous naive pipeline (USD-quoted CoinGecko candles, 6-12 bar
Parkinson estimates, AR(1) "mean reversion whenever b<0", drift extrapolated from
a 4h window, hard-coded fallbacks). Design rules:

* Work in log price quoted in ADA, the numeraire the orders are actually priced in.
* Every model reports its sample size and uncertainty; nothing is "actionable"
  unless a formal test supports it (ADF for mean reversion, t-stat for drift).
* Fill probability is reported from three independent methods (closed-form
  first passage, stationary block bootstrap of observed returns, and empirical
  historical hit-rate) so disagreement between them is visible.
* Pure numpy; no scipy/statsmodels dependency.
"""
from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence

import numpy as np

SQRT2 = math.sqrt(2.0)
Z975 = 1.959963984540054
Z75 = 0.6744897501960817


def norm_cdf(x):
    x = np.asarray(x, dtype=float)
    return 0.5 * (1.0 + np.vectorize(math.erf)(x / SQRT2))


def _ols(y: np.ndarray, X: np.ndarray) -> Dict[str, Any]:
    beta, _, rank, _ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ beta
    n, k = X.shape
    dof = max(n - k, 1)
    s2 = float(resid @ resid) / dof
    try:
        cov = s2 * np.linalg.inv(X.T @ X)
    except np.linalg.LinAlgError:
        cov = s2 * np.linalg.pinv(X.T @ X)
    se = np.sqrt(np.clip(np.diag(cov), 0, None))
    return {"beta": beta, "se": se, "resid": resid, "s2": s2, "n": n, "k": k,
            "rss": float(resid @ resid)}


def total_least_squares(y: Sequence[float], x: Sequence[float]) -> Dict[str, Any]:
    """Total Least Squares (Orthogonal Distance Regression) via 2D SVD/PCA.
    y = alpha + beta * x + eps.
    Minimizes orthogonal squared Euclidean errors, eliminating errors-in-variables
    directionality bias (beta_yx == 1.0 / beta_xy).
    Returns dict with alpha, beta, residuals, orthogonal_residuals, and n."""
    y_arr = np.asarray(y, dtype=float)
    x_arr = np.asarray(x, dtype=float)
    if len(y_arr) != len(x_arr) or len(y_arr) < 2:
        return {"status": "insufficient_data", "alpha": 0.0, "beta": 1.0, "residuals": np.zeros_like(y_arr)}
    x_mean = float(np.mean(x_arr))
    y_mean = float(np.mean(y_arr))
    Z = np.column_stack([x_arr - x_mean, y_arr - y_mean])
    _, _, vt = np.linalg.svd(Z, full_matrices=False)
    v1 = vt[0]
    if abs(v1[0]) < 1e-12:
        X = np.column_stack([np.ones_like(x_arr), x_arr])
        ols_res = _ols(y_arr, X)
        b0, b1 = float(ols_res["beta"][0]), float(ols_res["beta"][1])
        return {"status": "ok", "alpha": b0, "beta": b1, "residuals": y_arr - (b0 + b1 * x_arr)}
    beta = float(v1[1] / v1[0])
    alpha = float(y_mean - beta * x_mean)
    residuals = y_arr - (alpha + beta * x_arr)
    orth_residuals = residuals / math.sqrt(1.0 + beta ** 2)
    return {
        "status": "ok",
        "alpha": alpha,
        "beta": beta,
        "residuals": residuals,
        "orthogonal_residuals": orth_residuals,
        "n": len(y_arr),
    }


# ---------------------------------------------------------------------------
# Volatility estimators (per-bar sigma of log price)
# ---------------------------------------------------------------------------

def volatility_estimators(o, h, l, c, ewma_halflife_bars: float = 24.0) -> Dict[str, Any]:
    o, h, l, c = (np.asarray(a, dtype=float) for a in (o, h, l, c))
    n = len(c)
    if n < 10:
        return {"n_bars": n, "status": "insufficient_data"}
    r = np.diff(np.log(c))
    lo, lh, ll, lc = np.log(o), np.log(h), np.log(l), np.log(c)
    hl = lh - ll
    co = lc - lo
    cc = float(np.std(r, ddof=1))
    park = float(math.sqrt(np.mean(hl ** 2) / (4 * math.log(2))))
    gk_var = np.mean(0.5 * hl ** 2 - (2 * math.log(2) - 1) * co ** 2)
    gk = float(math.sqrt(max(gk_var, 0.0)))
    rs_terms = (lh - lc) * (lh - lo) + (ll - lc) * (ll - lo)
    rs = float(math.sqrt(max(np.mean(rs_terms), 0.0)))
    overnight = lo[1:] - lc[:-1]
    k = 0.34 / (1.34 + (n + 1) / max(n - 1, 1))
    yz_var = np.var(overnight, ddof=1) + k * np.var(co, ddof=1) + (1 - k) * np.mean(rs_terms)
    yz = float(math.sqrt(max(yz_var, 0.0)))
    lam = 0.5 ** (1.0 / max(ewma_halflife_bars, 1e-9))
    var = float(np.var(r[: min(len(r), 48)], ddof=1)) if len(r) > 2 else float(r[0] ** 2)
    for x in r:
        var = lam * var + (1 - lam) * x * x
    ewma = float(math.sqrt(var))
    # Standard error of close-to-close sigma (normal approx): sigma / sqrt(2(n-1))
    cc_se = cc / math.sqrt(2 * max(len(r) - 1, 1))
    zero_frac = float(np.mean(r == 0.0))
    return {
        "status": "ok",
        "n_bars": n,
        "close_to_close": cc,
        "close_to_close_ci95": [max(cc - Z975 * cc_se, 0.0), cc + Z975 * cc_se],
        "parkinson": park,
        "garman_klass": gk,
        "rogers_satchell": rs,
        "yang_zhang": yz,
        "ewma": ewma,
        "ewma_halflife_bars": ewma_halflife_bars,
        "zero_return_fraction": zero_frac,
        "note": ("Range estimators assume continuous trading; with "
                 f"{zero_frac:.0%} no-trade bars they understate risk. "
                 "close_to_close on the forward-filled grid is the primary estimate."),
    }


# ---------------------------------------------------------------------------
# Unit-root / random-walk tests
# ---------------------------------------------------------------------------

# MacKinnon (2010) response-surface coefficients, constant-only case:
# N=1 (univariate ADF) and N=2 (cointegration residuals of 2 I(1) variables).
# N=2 coefficients from MacKinnon (2010) Table 2 (with verified 1% beta_2 correction -22.527).
_ADF_CRIT_C_BY_N = {
    1: {
        "1%": (-3.43035, -6.5393, -16.786, -79.433),
        "5%": (-2.86154, -2.8903, -4.234, -40.040),
        "10%": (-2.56677, -1.5384, -2.809, 0.0),
    },
    2: {
        "1%": (-3.89644, -10.9519, -22.527, 0.0),
        "5%": (-3.33613, -6.1101, -6.823, 0.0),
        "10%": (-3.04445, -4.2412, -2.720, 0.0),
    },
}
_ADF_CRIT_C = _ADF_CRIT_C_BY_N[1]

# MacKinnon (1994) p-value polynomials, constant-only case:
_TAU_BOUNDS_BY_N = {
    1: {"max": 2.74, "min": -18.83, "star": -1.61},
    2: {"max": 0.92, "min": -18.86, "star": -2.62},
}
_TAU_SMALLP_BY_N = {
    1: (2.1659, 1.4412, 0.038269),
    2: (2.92, 1.5012, 0.039796),
}
_TAU_LARGEP_BY_N = {
    1: (1.7339, 0.93202, -0.12745, -0.010368),
    2: (2.1945, 0.64695, -0.29198, -0.042377),
}


def adf_pvalue(tau: float, n_variables: int = 1) -> float:
    """Return MacKinnon's approximate p-value for tau statistic.
    n_variables=1: univariate ADF. n_variables=2: Engle-Granger cointegration residuals."""
    n_v = 2 if n_variables >= 2 else 1
    bounds = _TAU_BOUNDS_BY_N[n_v]
    if tau > bounds["max"]:
        return 1.0
    if tau < bounds["min"]:
        return 0.0
    coef = _TAU_SMALLP_BY_N[n_v] if tau <= bounds["star"] else _TAU_LARGEP_BY_N[n_v]
    z = sum(cf * tau ** i for i, cf in enumerate(coef))
    return float(norm_cdf(z))


def adf_test(y: Sequence[float], maxlag: Optional[int] = None, n_variables: int = 1) -> Dict[str, Any]:
    """Augmented Dickey-Fuller with constant; lag order by AIC on a common sample.
    When n_variables >= 2, evaluates against MacKinnon (2010) cointegration critical values."""
    y = np.asarray(y, dtype=float)
    n = len(y)
    if n < 20:
        return {"status": "insufficient_data", "n": n}
    if maxlag is None:
        maxlag = int(math.ceil(12.0 * (n / 100.0) ** 0.25))
    maxlag = max(0, min(maxlag, n // 4))
    dy = np.diff(y)

    def design(p: int, start: int):
        idx = np.arange(start, len(dy))
        cols = [np.ones(len(idx)), y[idx]]
        for j in range(1, p + 1):
            cols.append(dy[idx - j])
        return dy[idx], np.column_stack(cols)

    best_p, best_aic = 0, np.inf
    for p in range(maxlag + 1):
        Y, X = design(p, maxlag)
        fit = _ols(Y, X)
        if fit["rss"] <= 0:
            continue
        aic = fit["n"] * math.log(fit["rss"] / fit["n"]) + 2 * fit["k"]
        if aic < best_aic:
            best_aic, best_p = aic, p
    Y, X = design(best_p, best_p)
    fit = _ols(Y, X)
    gamma, se = float(fit["beta"][1]), float(fit["se"][1])
    tau = gamma / se if se > 0 else 0.0
    nobs = fit["n"]
    n_v = 2 if n_variables >= 2 else 1
    crit_table = _ADF_CRIT_C_BY_N[n_v]
    crit = {k: b0 + b1 / nobs + b2 / nobs ** 2 + b3 / nobs ** 3 for k, (b0, b1, b2, b3) in crit_table.items()}
    p = adf_pvalue(tau, n_variables=n_v)
    return {
        "status": "ok",
        "statistic": tau,
        "pvalue": p,
        "lags": best_p,
        "nobs": nobs,
        "n_variables": n_v,
        "critical_values": crit,
        "rejects_unit_root_5pct": bool(tau < crit["5%"]),
        "interpretation": ("stationary / mean-reverting at 5%" if tau < crit["5%"]
                           else "cannot reject random walk (unit root)"),
    }


def variance_ratio_test(log_prices: Sequence[float], qs: Sequence[int] = (2, 4, 8, 16, 24)) -> Dict[str, Any]:
    """Lo-MacKinlay (1988) variance ratio with heteroskedasticity-robust z*."""
    x = np.asarray(log_prices, dtype=float)
    r = np.diff(x)
    T = len(r)
    if T < 50:
        return {"status": "insufficient_data", "n": T}
    mu = r.mean()
    d = r - mu
    s_a = float(d @ d) / (T - 1)
    out = []
    denom = float(d @ d) ** 2
    for q in qs:
        if q >= T // 2:
            continue
        rq = x[q:] - x[:-q] - q * mu
        m = q * (T - q + 1) * (1 - q / T)
        s_c = float(rq @ rq) / m
        vr = s_c / s_a if s_a > 0 else float("nan")
        theta = 0.0
        for j in range(1, q):
            delta = T * float((d[j:] ** 2) @ (d[:-j] ** 2)) / denom
            theta += (2.0 * (q - j) / q) ** 2 * delta
        z = (vr - 1) / math.sqrt(theta / T) if theta > 0 else float("nan")
        p = float(2 * (1 - norm_cdf(abs(z)))) if np.isfinite(z) else float("nan")
        out.append({"q": q, "vr": vr, "z_robust": z, "pvalue": p})
    alpha = 0.05 / max(len(out), 1)  # Bonferroni across horizons (family-wise 5%)
    sig = [o for o in out if o["pvalue"] < alpha]
    if not sig:
        verdict = "consistent with random walk"
    elif all(o["vr"] < 1 for o in sig):
        verdict = "short-horizon mean reversion (likely AMM arbitrage / bounce)"
    elif all(o["vr"] > 1 for o in sig):
        verdict = "short-horizon momentum"
    else:
        verdict = "mixed"
    return {"status": "ok", "ratios": out, "verdict": verdict}


def hurst_dfa(returns: Sequence[float], min_win: int = 8) -> Dict[str, Any]:
    """Detrended fluctuation analysis (DFA-1) exponent of the return series."""
    r = np.asarray(returns, dtype=float)
    N = len(r)
    if N < 4 * min_win:
        return {"status": "insufficient_data", "n": N}
    prof = np.cumsum(r - r.mean())
    wins = np.unique(np.floor(np.logspace(math.log10(min_win), math.log10(N // 4), 12)).astype(int))
    F, S = [], []
    for s in wins:
        nseg = N // s
        if nseg < 2:
            continue
        segs = prof[: nseg * s].reshape(nseg, s)
        t = np.arange(s)
        A = np.column_stack([t, np.ones(s)])
        coef, *_ = np.linalg.lstsq(A, segs.T, rcond=None)
        resid = segs.T - A @ coef
        f = math.sqrt(float(np.mean(resid ** 2)))
        if f > 0:
            F.append(f); S.append(s)
    if len(S) < 4:
        return {"status": "insufficient_data", "n": N}
    slope, _ = np.polyfit(np.log(S), np.log(F), 1)
    H = float(slope)
    label = "anti-persistent" if H < 0.45 else ("persistent / trending" if H > 0.55 else "random-walk-like")
    return {"status": "ok", "hurst": H, "label": label, "windows": [int(s) for s in S]}


# ---------------------------------------------------------------------------
# Drift and Ornstein-Uhlenbeck
# ---------------------------------------------------------------------------

def drift_estimate(returns: Sequence[float]) -> Dict[str, Any]:
    r = np.asarray(returns, dtype=float)
    n = len(r)
    if n < 10:
        return {"status": "insufficient_data"}
    mu = float(r.mean())
    se = float(r.std(ddof=1) / math.sqrt(n))
    t = mu / se if se > 0 else 0.0
    return {"status": "ok", "mean_per_bar": mu, "se": se, "t_stat": t,
            "significant_5pct": bool(abs(t) > Z975),
            "note": "Drift is used in forecasts only when |t| > 1.96; otherwise zero drift is assumed."}


def fit_ou(log_prices: Sequence[float], dt_hours: float, adf: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Exact-discretisation OU fit via AR(1) with Kendall bias correction and CIs.
    Marked actionable only if ADF rejects a unit root at 5% and >=4 half-lives fit in the sample."""
    x = np.asarray(log_prices, dtype=float)
    n = len(x) - 1
    if n < 30:
        return {"status": "insufficient_data", "n": n}
    fit = _ols(x[1:], np.column_stack([np.ones(n), x[:-1]]))
    a, b = float(fit["beta"][0]), float(fit["beta"][1])
    se_b = float(fit["se"][1])
    b_bc = min(b + (1 + 3 * b) / n, 0.999999)
    sd_e = math.sqrt(fit["s2"])
    adf = adf or adf_test(x)
    res: Dict[str, Any] = {"status": "ok", "n": n, "ar1_b": b, "ar1_b_bias_corrected": b_bc, "ar1_b_se": se_b,
                           "adf_pvalue": adf.get("pvalue"), "rejects_unit_root_5pct": adf.get("rejects_unit_root_5pct")}
    if not (0 < b_bc < 1):
        res.update({"mean_reverting": False, "actionable": False,
                    "reason": "AR(1) coefficient outside (0,1); no OU structure"})
        return res
    theta = -math.log(b_bc) / dt_hours
    mu_log = a / (1 - b)
    sigma_eq = sd_e / math.sqrt(max(1 - b_bc ** 2, 1e-12))
    hl = math.log(2) / theta
    b_hi = b_bc + Z975 * se_b
    b_lo = max(b_bc - Z975 * se_b, 1e-9)
    hl_lo = math.log(2) / (-math.log(b_lo) / dt_hours)
    hl_hi = float("inf") if b_hi >= 1 else math.log(2) / (-math.log(b_hi) / dt_hours)
    span_h = n * dt_hours
    actionable = bool(adf.get("rejects_unit_root_5pct")) and hl * 4 <= span_h
    res.update({
        "mean_reverting": bool(adf.get("rejects_unit_root_5pct")),
        "actionable": actionable,
        "theta_per_hour": theta,
        "half_life_hours": hl,
        "half_life_ci95_hours": [hl_lo, hl_hi],
        "mu_price": math.exp(mu_log),
        "band_1sd": [math.exp(mu_log - sigma_eq), math.exp(mu_log + sigma_eq)],
        "band_2sd": [math.exp(mu_log - 2 * sigma_eq), math.exp(mu_log + 2 * sigma_eq)],
        "sigma_eq_log": sigma_eq,
        "sigma_step_log": sd_e,
        "reason": ("ADF rejects unit root and sample spans >=4 half-lives" if actionable else
                   ("ADF cannot reject a random walk; OU parameters are descriptive only"
                    if not adf.get("rejects_unit_root_5pct") else
                    "half-life too long relative to sample to trust")),
    })
    return res


# ---------------------------------------------------------------------------
# Fill / first-passage probabilities
# ---------------------------------------------------------------------------

def gbm_hit_probability(log_distance: float, sigma_per_h: float, horizon_h: float, drift_per_h: float = 0.0) -> float:
    """P(max/min of arithmetic BM in log price reaches barrier within horizon).
    log_distance > 0 means barrier above spot; < 0 below."""
    if horizon_h <= 0 or sigma_per_h <= 0:
        return 0.0
    a, nu = log_distance, drift_per_h
    if a < 0:
        a, nu = -a, -nu
    if a == 0:
        return 1.0
    s = sigma_per_h * math.sqrt(horizon_h)
    t1 = float(norm_cdf((nu * horizon_h - a) / s))
    expo = 2 * nu * a / sigma_per_h ** 2
    t2 = 0.0 if expo > 700 else math.exp(expo) * float(norm_cdf((-a - nu * horizon_h) / s))
    return float(min(max(t1 + t2, 0.0), 1.0))


def gbm_median_hit_hours(log_distance: float, sigma_per_h: float) -> float:
    """Median first-passage time for driftless BM (mean is infinite)."""
    if sigma_per_h <= 0:
        return float("inf")
    return (abs(log_distance) / (Z75 * sigma_per_h)) ** 2


def _wilson(k: float, n: float) -> List[float]:
    if n <= 0:
        return [0.0, 1.0]
    p = k / n
    z2 = Z975 ** 2
    centre = (p + z2 / (2 * n)) / (1 + z2 / n)
    half = Z975 * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n)
    return [max(centre - half, 0.0), min(centre + half, 1.0)]


def empirical_hit_rate(o, h, l, c, log_distance: float, horizon_bars: int) -> Dict[str, Any]:
    """Fraction of historical start points from which price moved by log_distance within the horizon,
    using intrabar highs/lows. Overlapping windows -> effective n = n / horizon."""
    h, l, c = (np.log(np.asarray(a, dtype=float)) for a in (h, l, c))
    n = len(c) - horizon_bars
    if n < 10 or horizon_bars < 1:
        return {"status": "insufficient_data"}
    hits = 0
    for i in range(n):
        if log_distance >= 0:
            if np.max(h[i + 1: i + 1 + horizon_bars]) - c[i] >= log_distance:
                hits += 1
        else:
            if np.min(l[i + 1: i + 1 + horizon_bars]) - c[i] <= log_distance:
                hits += 1
    p = hits / n
    n_eff = max(n / horizon_bars, 1.0)
    return {"status": "ok", "p": p, "ci95": _wilson(p * n_eff, n_eff), "n_windows": n, "n_effective": n_eff}


def block_bootstrap_hit(o, h, l, c, log_distance: float, horizons_bars: Sequence[int],
                        n_paths: int = 4000, mean_block: int = 24, demean: bool = True,
                        seed: int = 7) -> Dict[str, Any]:
    """Politis-Romano stationary bootstrap of (return, intrabar high/low excursion) triples.
    Preserves volatility clustering and fat tails; zero drift by default."""
    lc = np.log(np.asarray(c, dtype=float))
    lh = np.log(np.asarray(h, dtype=float))
    ll = np.log(np.asarray(l, dtype=float))
    r = np.diff(lc)
    hx = lh[1:] - lc[:-1]
    lx = ll[1:] - lc[:-1]
    N = len(r)
    if N < 48:
        return {"status": "insufficient_data"}
    if demean:
        m = r.mean()
        r, hx, lx = r - m, hx - m, lx - m
    H = int(max(horizons_bars))
    rng = np.random.default_rng(seed)
    idx = np.empty((n_paths, H), dtype=np.int64)
    idx[:, 0] = rng.integers(0, N, n_paths)
    p_new = 1.0 / mean_block
    jumps = rng.random((n_paths, H)) < p_new
    fresh = rng.integers(0, N, (n_paths, H))
    for t in range(1, H):
        idx[:, t] = np.where(jumps[:, t], fresh[:, t], (idx[:, t - 1] + 1) % N)
    R = r[idx]
    X_prev = np.concatenate([np.zeros((n_paths, 1)), np.cumsum(R, axis=1)[:, :-1]], axis=1)
    if log_distance >= 0:
        ext = np.maximum.accumulate(X_prev + hx[idx], axis=1)
        hit = ext >= log_distance
    else:
        ext = np.minimum.accumulate(X_prev + lx[idx], axis=1)
        hit = ext <= log_distance
    out = {}
    for hb in horizons_bars:
        p = float(hit[:, hb - 1].mean())
        out[str(hb)] = p
    first = np.where(hit.any(axis=1), hit.argmax(axis=1) + 1, H + 1)
    med = float(np.median(first)) if (first <= H).mean() >= 0.5 else None
    return {"status": "ok", "p_by_horizon_bars": out, "median_hit_bars": med, "n_paths": n_paths,
            "mean_block": mean_block}


def ou_hit_probability(spot: float, barrier: float, ou: Dict[str, Any], horizons_h: Sequence[float],
                       dt_hours: float, n_paths: int = 6000, seed: int = 11) -> Dict[str, Any]:
    """Exact OU simulation with Broadie-Glasserman continuity correction."""
    if not ou.get("actionable"):
        return {"status": "skipped", "reason": ou.get("reason", "OU not actionable")}
    b = math.exp(-ou["theta_per_hour"] * dt_hours)
    mu = math.log(ou["mu_price"])
    sd = ou["sigma_step_log"]
    steps = int(math.ceil(max(horizons_h) / dt_hours))
    rng = np.random.default_rng(seed)
    x = np.full(n_paths, math.log(spot))
    up = barrier >= spot
    lb = math.log(barrier) + (-0.5826 * sd if up else 0.5826 * sd)
    hit = np.zeros(n_paths, dtype=bool)
    marks = {int(math.ceil(hh / dt_hours)): hh for hh in horizons_h}
    out = {}
    for s in range(1, steps + 1):
        x = mu + (x - mu) * b + sd * rng.standard_normal(n_paths)
        hit |= (x >= lb) if up else (x <= lb)
        if s in marks:
            out[str(marks[s])] = float(hit.mean())
    return {"status": "ok", "p_by_horizon_h": out}


# ---------------------------------------------------------------------------
# AMM execution: price at which a limit order can actually fill
# ---------------------------------------------------------------------------

def cpmm_trigger_price(direction: str, amount: float, limit_price: float,
                       reserve_token: float, reserve_ada: float, fee: float = 0.003) -> Dict[str, Any]:
    """Pool spot price (ADA per token) at which a batcher can execute the WHOLE order and still
    meet its minimum receive, accounting for pool fee and our own price impact.
    sell: give `amount` tokens, need >= amount*limit_price ADA -> pool spot must be >= trigger.
    buy : give `amount*limit_price` ADA, need >= amount tokens   -> pool spot must be <= trigger."""
    if reserve_token <= 0 or reserve_ada <= 0 or amount <= 0 or limit_price <= 0:
        return {"status": "unavailable", "reason": "missing reserves or order size"}
    k = reserve_token * reserve_ada
    rk = math.sqrt(k)
    if direction == "sell":
        Qf = amount * (1 - fee)
        R = amount * limit_price
        s = (R * Qf + math.sqrt((R * Qf) ** 2 + 4 * k * Qf * R)) / (2 * rk * Qf)
        trig = s * s
    else:
        Af = amount * limit_price * (1 - fee)
        Q = amount
        s = (-Q * Af + math.sqrt((Q * Af) ** 2 + 4 * k * Q * Af)) / (2 * rk * Q)
        trig = s * s
    return {"status": "ok", "trigger_spot": trig, "limit_price": limit_price,
            "premium_pct": (trig / limit_price - 1) * 100, "fee": fee,
            "pool_depth_ada": reserve_ada}


def json_safe(o: Any) -> Any:
    """Recursively replace NaN/±inf with None so strict JSON parsers (serde, browsers) accept output."""
    if isinstance(o, float):
        return o if math.isfinite(o) else None
    if isinstance(o, (np.floating,)):
        f = float(o)
        return f if math.isfinite(f) else None
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.bool_,)):
        return bool(o)
    if isinstance(o, dict):
        return {k: json_safe(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [json_safe(v) for v in o]
    return o
