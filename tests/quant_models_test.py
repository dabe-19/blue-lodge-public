#!/usr/bin/env python3
"""Synthetic-data validation of lib/tools/quant/models.py.
Run: .venv/bin/python -m unittest tests/quant_models_test.py"""
import math
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.tools.quant import models as M  # noqa: E402
from lib.tools.quant.market_data import regularize_bars  # noqa: E402


def random_walk(n=2000, sigma=0.01, seed=1):
    rng = np.random.default_rng(seed)
    return np.cumsum(sigma * rng.standard_normal(n)) + math.log(0.1)


def ou_path(n=3000, theta=0.05, mu=math.log(0.1), sd=0.01, seed=2):
    rng = np.random.default_rng(seed)
    b = math.exp(-theta)
    x = np.empty(n); x[0] = mu
    for i in range(1, n):
        x[i] = mu + (x[i - 1] - mu) * b + sd * rng.standard_normal()
    return x


class TestADF(unittest.TestCase):
    def test_pvalue_anchors(self):
        self.assertAlmostEqual(M.adf_pvalue(-2.86154), 0.05, delta=0.006)
        self.assertAlmostEqual(M.adf_pvalue(-3.43035), 0.01, delta=0.003)
        self.assertAlmostEqual(M.adf_pvalue(-2.56677), 0.10, delta=0.01)

    def test_coint_n2_anchors(self):
        self.assertAlmostEqual(M.adf_pvalue(-3.33613, n_variables=2), 0.05, delta=0.008)
        self.assertAlmostEqual(M.adf_pvalue(-3.89644, n_variables=2), 0.01, delta=0.006)
        self.assertAlmostEqual(M.adf_pvalue(-3.04445, n_variables=2), 0.10, delta=0.015)

    def test_adf_n_variables_parameter(self):
        x = ou_path(n=1000)
        res1 = M.adf_test(x, n_variables=1)
        res2 = M.adf_test(x, n_variables=2)
        self.assertEqual(res1["n_variables"], 1)
        self.assertEqual(res2["n_variables"], 2)
        self.assertLess(res2["critical_values"]["5%"], res1["critical_values"]["5%"])

    def test_random_walk_not_flagged(self):
        false_pos = 0
        for s in range(40):
            if M.adf_test(random_walk(seed=s))["rejects_unit_root_5pct"]:
                false_pos += 1
        # size should be ~5%; allow sampling noise
        self.assertLessEqual(false_pos, 6)

    def test_ou_detected(self):
        r = M.adf_test(ou_path())
        self.assertTrue(r["rejects_unit_root_5pct"])
        self.assertLess(r["pvalue"], 0.01)


class TestTLS(unittest.TestCase):
    def test_symmetry(self):
        rng = np.random.default_rng(42)
        x = np.linspace(1.0, 10.0, 100)
        y = 2.5 * x + 1.2 + 0.1 * rng.standard_normal(100)
        fit_yx = M.total_least_squares(y, x)
        fit_xy = M.total_least_squares(x, y)
        self.assertEqual(fit_yx["status"], "ok")
        self.assertEqual(fit_xy["status"], "ok")
        self.assertAlmostEqual(fit_yx["beta"], 1.0 / fit_xy["beta"], places=5)
        self.assertAlmostEqual(fit_xy["alpha"], -fit_yx["alpha"] / fit_yx["beta"], places=5)


class TestOU(unittest.TestCase):
    def test_recovers_theta(self):
        x = ou_path(n=5000, theta=0.05)
        fit = M.fit_ou(x, dt_hours=1.0)
        self.assertTrue(fit["actionable"])
        self.assertAlmostEqual(fit["theta_per_hour"], 0.05, delta=0.015)
        self.assertAlmostEqual(fit["mu_price"], 0.1, delta=0.005)
        lo, hi = fit["half_life_ci95_hours"]
        self.assertLess(lo, math.log(2) / 0.05)
        self.assertGreater(hi, math.log(2) / 0.05)

    def test_random_walk_not_actionable(self):
        fit = M.fit_ou(random_walk(seed=3), dt_hours=1.0)
        self.assertFalse(fit.get("actionable"))


class TestVarianceRatio(unittest.TestCase):
    def test_rw(self):
        self.assertEqual(M.variance_ratio_test(random_walk(seed=5))["verdict"], "consistent with random walk")

    def test_mean_reverting_noise(self):
        rng = np.random.default_rng(9)
        x = random_walk(seed=9, sigma=0.002) + 0.02 * rng.standard_normal(2000)
        self.assertIn("mean reversion", M.variance_ratio_test(x)["verdict"])


class TestHurst(unittest.TestCase):
    def test_white_noise_half(self):
        r = np.random.default_rng(4).standard_normal(4000)
        self.assertAlmostEqual(M.hurst_dfa(r)["hurst"], 0.5, delta=0.08)


class TestFirstPassage(unittest.TestCase):
    def test_reflection_principle(self):
        # driftless: P = 2*(1-Phi(a/(s sqrt T)))
        a, s, T = 0.05, 0.01, 24
        expected = 2 * (1 - float(M.norm_cdf(a / (s * math.sqrt(T)))))
        self.assertAlmostEqual(M.gbm_hit_probability(a, s, T), expected, places=9)
        self.assertAlmostEqual(M.gbm_hit_probability(-a, s, T), expected, places=9)

    def test_median_time(self):
        a, s = 0.05, 0.01
        t = M.gbm_median_hit_hours(a, s)
        self.assertAlmostEqual(M.gbm_hit_probability(a, s, t), 0.5, places=6)

    def test_bootstrap_agrees_with_closed_form_on_gaussian(self):
        rng = np.random.default_rng(12)
        n = 4000
        c = np.exp(np.cumsum(0.01 * rng.standard_normal(n)))
        o = np.concatenate([[c[0]], c[:-1]])
        h = np.maximum(o, c); l = np.minimum(o, c)
        bb = M.block_bootstrap_hit(o, h, l, c, 0.05, [24], mean_block=1)
        cf = M.gbm_hit_probability(0.05, 0.01, 24)
        # discrete monitoring makes bootstrap slightly lower than continuous closed form
        self.assertAlmostEqual(bb["p_by_horizon_bars"]["24"], cf, delta=0.07)


class TestCPMM(unittest.TestCase):
    def test_small_order_limit(self):
        r = M.cpmm_trigger_price("sell", 1.0, 0.1, 1e9, 1e8, fee=0.003)
        self.assertAlmostEqual(r["trigger_spot"], 0.1 / 0.997, places=6)

    def test_impact_raises_sell_trigger(self):
        small = M.cpmm_trigger_price("sell", 1_000, 0.1, 1e6, 1e5)["trigger_spot"]
        big = M.cpmm_trigger_price("sell", 100_000, 0.1, 1e6, 1e5)["trigger_spot"]
        self.assertGreater(big, small)

    def test_sell_trigger_exact(self):
        x, y, Q, P, f = 1e6, 1e5, 50_000, 0.1, 0.003
        trig = M.cpmm_trigger_price("sell", Q, P, x, y, f)["trigger_spot"]
        k = x * y
        xs, ys = math.sqrt(k / trig), math.sqrt(k * trig)
        out = ys * Q * (1 - f) / (xs + Q * (1 - f))
        self.assertAlmostEqual(out, Q * P, places=4)

    def test_buy_trigger_exact(self):
        x, y, Q, P, f = 1e6, 1e5, 50_000, 0.09, 0.003
        trig = M.cpmm_trigger_price("buy", Q, P, x, y, f)["trigger_spot"]
        k = x * y
        xs, ys = math.sqrt(k / trig), math.sqrt(k * trig)
        A = Q * P * (1 - f)
        self.assertAlmostEqual(xs * A / (ys + A), Q, places=4)


class TestRegularize(unittest.TestCase):
    def test_forward_fill_and_prev_close_range(self):
        bars = [[0, 1.0, 1.1, 0.9, 1.0, 5], [7200, 1.2, 1.3, 1.2, 1.25, 3]]
        g = regularize_bars(bars, 3600)
        self.assertEqual(len(g["c"]), 3)
        self.assertEqual(g["c"][1], 1.0)
        self.assertFalse(g["traded"][1])
        self.assertEqual(g["o"][2], 1.0)
        self.assertEqual(g["l"][2], 1.0)


if __name__ == "__main__":
    unittest.main()
