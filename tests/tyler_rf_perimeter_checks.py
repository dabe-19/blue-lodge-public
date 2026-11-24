#!/usr/bin/env python3
"""
Unit & Integration Verification Suite for:
1. Pure Linux (`nl80211` `iw` / `nmcli`) & WSL2 (`netsh`) wireless parsers (zero C# / .dll)
2. Co-located Dual-VAP 0.5 dB fusion & single-beacon collision rejection
3. Bessel (N - 1) sample variance & 0.25 dB^2 quantization deadband
4. Gated Workstation Common-Mode Cancellation (preserving WORKSTATION_NEAR_FIELD)
5. Hampel spike filter with 2-sweep step persistence & instant return-to-baseline pass-through
6. Unsmoothed Leaky Page-Hinkley CUSUM & IE 11 QBSS interference gating
7. Compass calibration (configured North anchor, South-Wall peripheral) & +/- 8 dB triangulation
8. Single-chord neighbor-internal suppression vs. corroborated perimeter approach/departure alerts
9. Non-blocking Soft-AP Airlock radio mutex (_wifi_airlock_radio_lock)
"""

import multiprocessing
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))

import lib.tools.tyler_guardian as tg  # noqa: E402


def test_bessel_and_quantization_deadband() -> None:
    # 2-tick 1 dB step [-69, -70]: Bessel s^2 = 0.50 -> raw_std = 0.71, deadband std = sqrt(0.50 - 0.25) = 0.50
    stats = tg._compute_chord_sample_stats([-69.0, -70.0], quant_deadband_var=0.25)
    assert stats["p2p_swing_db"] == 1.0, stats
    assert abs(stats["raw_std_db"] - 0.71) <= 0.02, stats
    assert abs(stats["std_db"] - 0.50) <= 0.02, stats


def test_colocated_vap_fusion_and_collision_rejection() -> None:
    # Co-located primary + guest within 4 dB -> fused at 0.5 dB resolution
    fused, collided = tg._fuse_colocated_vap_rssi(-64.0, -65.0)
    assert fused == -64.5 and collided is False
    # Single-beacon collision drop > 4 dB -> rejects deep fade, takes stronger beacon
    fused2, collided2 = tg._fuse_colocated_vap_rssi(-64.0, -75.0)
    assert fused2 == -64.0 and collided2 is True


def test_gated_common_mode_cancellation() -> None:
    # Uniform -1.5 dB receiver AGC shift across 5 quiet chords -> common_mode_db = -1.5, near_field = False
    cm_db, near_field = tg._compute_gated_common_mode_db(
        [-1.5, -1.5, -1.4, -1.6, -1.5],
        [0.5, 0.5, 0.5, 0.5, 0.5],
    )
    assert abs(cm_db - (-1.5)) < 0.05 and near_field is False, (cm_db, near_field)

    # Physical person walking past Workstation (4 chords swinging >= 2.5 dB) -> near_field = True, cm_db = 0.0
    cm_nf, near_field_nf = tg._compute_gated_common_mode_db(
        [-5.0, -4.5, -4.0, -5.0],
        [3.5, 3.0, 4.0, 3.5],
    )
    assert cm_nf == 0.0 and near_field_nf is True, (cm_nf, near_field_nf)


def test_signal_conditioning_hampel_step_and_return_to_baseline() -> None:
    recent_valid = [-65.0, -65.0, -65.0, -65.0, -65.0]

    # 1. Single-sweep 6 dB interference spike -> Hampel clamps, remains quiet
    c1 = tg._condition_chord_signal(
        mean_dbm=-71.0,
        std_db=0.4,
        p2p_swing_db=1.0,
        n_samples=3,
        prev_base=-65.0,
        prev_fast_in=-65.0,
        prev_ewma_std_in=0.4,
        recent_valid_rssi=recent_valid,
        calibrate=False,
    )
    assert c1["filtered_dbm"] > -67.0, c1
    assert c1["motion_state"] == "quiet", c1

    # 2. Second consecutive sweep at -70.0 dB (recent_valid[-1] == -70.5) -> step persistence passes raw step
    c2 = tg._condition_chord_signal(
        mean_dbm=-70.0,
        std_db=0.6,
        p2p_swing_db=1.2,
        n_samples=3,
        prev_base=-65.0,
        prev_fast_in=-68.0,
        prev_ewma_std_in=0.6,
        recent_valid_rssi=[-65.0, -65.0, -65.0, -65.0, -70.5],
        calibrate=False,
    )
    assert c2["filtered_dbm"] == -70.0, c2
    assert c2["motion_state"] in ("presence_shift", "motion_detected"), c2

    # 3. Person leaves room and signal returns to baseline (-65.0 dB) even after 4 disturbed sweeps ->
    #    instant return-to-baseline pass-through prevents the 9-sweep Hampel latch bug!
    c3 = tg._condition_chord_signal(
        mean_dbm=-65.0,
        std_db=0.0,
        p2p_swing_db=0.5,
        n_samples=3,
        prev_base=-65.0,
        prev_fast_in=-65.5,
        prev_ewma_std_in=0.5,
        recent_valid_rssi=[-65.0, -69.5, -69.5, -69.5, -69.5],
        calibrate=False,
    )
    assert c3["filtered_dbm"] == -65.0, c3
    assert c3["motion_state"] == "quiet", c3

    # 4. High QBSS channel utilization (75%) engages interference gating
    c4 = tg._condition_chord_signal(
        mean_dbm=-67.8,
        std_db=0.5,
        p2p_swing_db=1.0,
        n_samples=3,
        prev_base=-65.0,
        prev_fast_in=-65.0,
        prev_ewma_std_in=0.5,
        recent_valid_rssi=recent_valid,
        calibrate=False,
        qbss_chan_util_pct=75.0,
    )
    assert c4["interference_gated"] is True, c4


def test_compass_calibration_and_triangulation() -> None:
    compass_cfg = {
        "north_anchors": [
            {"ssid_pattern": "NorthAnchorAP*", "bssid_prefix": "02:00:5e:aa:01"},
        ],
        "south_wall_anchor": {"bssid": "02:00:5e:00:01:02"},
    }
    assert tg._classify_compass_sector("02:00:5e:aa:01:a5", "NorthAnchorAP", compass_cfg=compass_cfg) == "NORTH"
    assert tg._classify_compass_sector("02:00:5e:aa:01:a6", "NorthAnchorAP-5G", compass_cfg=compass_cfg) == "NORTH"
    assert tg._classify_compass_sector("02:00:5e:00:01:02", "SensorBeacon.b222", compass_cfg=compass_cfg) == "SOUTH_WALL"
    assert tg._classify_compass_sector("02:00:5e:bb:02:c5", "SouthAnchorAP", delta_south_minus_north_db=15, compass_cfg=compass_cfg) == "SOUTH"
    assert tg._classify_compass_sector("02:00:5e:aa:02:17", "NorthFlankAP", delta_south_minus_north_db=-19, compass_cfg=compass_cfg) == "NORTH"
    assert tg._classify_compass_sector("02:00:5e:cc:03:2f", "FlankTestAP", delta_south_minus_north_db=-1, compass_cfg=compass_cfg) == "EAST_WEST_FLANK"


def test_neighbor_single_chord_suppression_vs_corroborated_alert() -> None:
    # Case A: Single neighbor chord (NorthAnchorAP) fluctuates alone -> NEIGHBOR_INTERNAL_SUPPRESSED (0 alerts)
    single_chords = [
        {
            "chord_id": "perim_wifi_aa01",
            "label": "Perimeter NORTH (NorthAnchorAP)",
            "zone": "Perimeter NORTH (NorthAnchorAP)",
            "ring": "exterior_perimeter",
            "compass_sector": "NORTH",
            "motion_state": "motion_detected",
            "p2p_swing_db": 4.0,
            "baseline_drift_db": -3.5,
        },
        {
            "chord_id": "perim_wifi_aa02",
            "label": "Perimeter NORTH (NorthFlankAP)",
            "zone": "Perimeter NORTH (NorthFlankAP)",
            "ring": "exterior_perimeter",
            "compass_sector": "NORTH",
            "motion_state": "quiet",
            "p2p_swing_db": 0.5,
            "baseline_drift_db": 0.0,
        },
        {
            "chord_id": "ws_wifi_b832",
            "label": "Printer / Study Span",
            "zone": "Printer / Study Span",
            "ring": "interior",
            "compass_sector": "NORTH_WEST_STUDY",
            "motion_state": "quiet",
            "p2p_swing_db": 0.0,
            "baseline_drift_db": 0.0,
        },
    ]
    loc_single = tg._localize_rf_disturbances(single_chords, {}, suppress_single_neighbor=True)
    assert loc_single["perimeter_alerts_count"] == 0, loc_single
    assert len(loc_single["suppressed_neighbor_events"]) == 1, loc_single
    assert loc_single["suppressed_neighbor_events"][0]["verdict"] == "NEIGHBOR_INTERNAL_SUPPRESSED"

    # Case B: Two North exterior chords trigger together -> corroborated PERIMETER_SECTOR_MOTION alert
    dual_north = [
        dict(single_chords[0]),
        dict(single_chords[1], motion_state="presence_shift", p2p_swing_db=2.5, baseline_drift_db=-2.8),
        dict(single_chords[2]),
    ]
    loc_dual = tg._localize_rf_disturbances(dual_north, {}, suppress_single_neighbor=True)
    assert loc_dual["perimeter_alerts_count"] >= 1, loc_dual
    assert loc_dual["perimeter_alerts"][0]["sector"] == "NORTH"
    assert loc_dual["perimeter_alerts"][0]["verdict"] == "PERIMETER_SECTOR_MOTION"

    # Case C: Exterior North chord + interior Study chord -> PERIMETER_APPROACH_VECTOR
    approach_chords = [
        dict(single_chords[0]),
        dict(single_chords[1]),
        dict(single_chords[2], motion_state="presence_shift", baseline_drift_db=-3.0),
    ]
    loc_app = tg._localize_rf_disturbances(approach_chords, {}, suppress_single_neighbor=True)
    assert any(a["verdict"] == "PERIMETER_APPROACH_VECTOR" for a in loc_app["perimeter_alerts"]), loc_app


def _hold_airlock_in_child(q: "multiprocessing.Queue[bool]", release_ev: "multiprocessing.Event") -> None:
    with tg._wifi_airlock_radio_lock():
        q.put(True)
        release_ev.wait(timeout=5.0)


def test_airlock_radio_mutex() -> None:
    assert tg._is_wifi_airlock_busy() is False
    ctx = multiprocessing.get_context("fork")
    q: "multiprocessing.Queue[bool]" = ctx.Queue()
    rel = ctx.Event()
    proc = ctx.Process(target=_hold_airlock_in_child, args=(q, rel))
    proc.start()
    try:
        assert q.get(timeout=3.0) is True
        assert tg._is_wifi_airlock_busy() is True
    finally:
        rel.set()
        proc.join(timeout=3.0)
    assert tg._is_wifi_airlock_busy() is False


def test_linux_iw_nmcli_and_wsl_netsh_parsers() -> None:
    src_text = (ROOT_DIR / "lib" / "tools" / "tyler_guardian.py").read_text(encoding="utf-8")
    assert "wlanapi.dll" not in src_text, "tyler_guardian.py must not depend on C# or wlanapi.dll"
    assert "csc.exe" not in src_text, "tyler_guardian.py must not invoke csc.exe"

    sample_iw = """BSS 02:00:5e:10:00:32(on wlan0)
\tTSF: 987654321 usec (0d, 00:16:27)
\tfreq: 2462
\tcapability: ESS Privacy ShortSlotTime (0x0411)
\tsignal: -44.00 dBm
\tlast seen: 120 ms ago
\tSSID: DIRECT-30-LabPrinter
\tDS Parameter set: channel 11
\tTPC report: TX power: 17 dBm
\tBSS Load:
\t\t* station count: 2
\t\t* channel utilisation: 90/255
\t\t* available admission capacity: 0 [*32us]
\tRSN:\t * Version: 1
\t\t * Authentication suites: SAE
\tHE capabilities:
"""
    iw_nets = tg._parse_linux_iw_scan_output(sample_iw)
    assert len(iw_nets) == 1, iw_nets
    n0 = iw_nets[0]
    assert n0["bssid"] == "02:00:5e:10:00:32"
    assert n0["rssi_dbm"] == -44.0
    assert n0["frequency_mhz"] == 2462 and n0["channel"] == 11
    assert n0["beacon_age_ms"] == 120 and n0["tsf_uptime_us"] == 987654321
    assert n0["tx_power_dbm"] == 17
    assert n0["qbss_sta_count"] == 2 and abs(n0["qbss_chan_util_pct"] - 35.3) <= 0.2
    assert n0["auth"] == "WPA3-Personal" and n0["radio_type"] == "802.11ax"
    assert n0["sensor_backend"] == "linux_nl80211_iw"

    sample_nmcli = r"02\:00\:5e\:aa\:01\:29:NorthAnchorAP:Infra:6:2437 MHz:130 Mbit/s:56:WPA2"
    nm_nets = tg._parse_linux_nmcli_wifi_output(sample_nmcli)
    assert len(nm_nets) == 1 and nm_nets[0]["bssid"] == "02:00:5e:aa:01:29"
    assert nm_nets[0]["rssi_dbm"] == -72.0 and nm_nets[0]["sensor_backend"] == "linux_nmcli"

    sample_netsh = """
SSID 1 : SouthAnchorAP
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : 02:00:5e:bb:02:18
         Signal             : 43%
         Radio type         : 802.11ax
         Band               : 2.4 GHz
         Channel            : 6
         Bss Load:
             Connected Stations:         4
             Channel Utilization:        90 (35 %)
"""
    ns_nets = tg._parse_netsh_wlan_bssid_output(sample_netsh)
    assert len(ns_nets) == 1 and ns_nets[0]["bssid"] == "02:00:5e:bb:02:18"
    assert ns_nets[0]["rssi_dbm"] == -78.5 and ns_nets[0]["frequency_mhz"] == 2437
    assert ns_nets[0]["qbss_sta_count"] == 4 and abs(ns_nets[0]["qbss_chan_util_pct"] - 35.3) <= 0.2
    assert ns_nets[0]["sensor_backend"] == "wsl_netsh"


if __name__ == "__main__":
    test_linux_iw_nmcli_and_wsl_netsh_parsers()
    test_bessel_and_quantization_deadband()
    test_colocated_vap_fusion_and_collision_rejection()
    test_gated_common_mode_cancellation()
    test_signal_conditioning_hampel_step_and_return_to_baseline()
    test_compass_calibration_and_triangulation()
    test_neighbor_single_chord_suppression_vs_corroborated_alert()
    test_airlock_radio_mutex()
    print("ALL_TYLER_RF_PERIMETER_CHECKS_OK")
