#!/usr/bin/env python3
"""
Sovereign Agentic Deal Verification Graph (2026)
------------------------------------------------
Evaluates secondary marketplace compute deals (GPU & RAM) to determine
whether a candidate deal or steal is AUTHENTIC or FAKE/FRAUDULENT.

Agentic Graph Phases:
  1. INGEST: Normalizes candidate metadata, URL, and target hardware specification.
  2. FETCH: Pulls down webpage content via HTTP client (or fallback proxy).
  3. EXTRACT: Parses title, actual price, condition, seller stats, listing format (BIN vs Auction).
  4. FORENSIC AUDIT: Scans for parts-only/defective units, box/accessory traps, off-platform scams, keyword bait.
  5. AGENT EVALUATION: Invokes local Sovereign LLM (or deterministic fallback) for semantic sanity check.
  6. VERDICT DISPATCH: Persists audit trail in deal_verifications and updates compute_deal_alerts in events.db.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
import urllib.parse
import urllib.request

logger = logging.getLogger("deal_verifier")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_GEORGE_DIR = Path(os.environ.get("GEORGE_DIR") or _REPO_ROOT / ".george")
_DEFAULT_DB_PATH = _GEORGE_DIR / "events.db"

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
)

# ── Red Flag Heuristic Patterns ────────────────────────────────────────

RE_DEFECTIVE_CONDITIONS = re.compile(
    r"(?i)\b("
    r"for\s+parts|parts\s+only|not\s+working|broken|defective|faulty|"
    r"for\s+repair|needs\s+repair|as-is|as\s+is\s+no\s+returns?|"
    r"no\s+display|no\s+video\s+output|doesn'?t\s+turn\s+on|won'?t\s+post|"
    r"code\s*43|artifacting|artifacts|black\s+screen|dead\s+core|"
    r"burnt|fried\s+pcb|missing\s+components?|liquid\s+damage|"
    r"spares\s+or\s+repair|untested\s+sold\s+as\s+is"
    r")\b"
)

RE_ACCESSORY_TRAPS = re.compile(
    r"(?i)\b("
    r"box\s+only|original\s+box\s+only|retail\s+packaging\s+only|empty\s+box|"
    r"shroud\s+only|cooler\s+only|heatsink\s+only|heatsink\s+and\s+fan|"
    r"water\s*block|water\s*cooling\s*block|backplate\s+only|fan\s+replacement|"
    r"bracket\s+only|mounting\s+kit|power\s+cable\s+only|"
    r"poster|picture\s+of|photo\s+postcard|digital\s+drawing|printed\s+picture"
    r")\b"
)

RE_SCAM_SOLICITATIONS = re.compile(
    r"(?i)\b("
    r"whatsapp|telegram\s*:|reach\s+me\s+at\s*\d{3}|text\s+me\s+at|"
    r"zelle\s+only|cash\s*app\s+only|paypal\s+friends|wire\s+transfer\s+only|"
    r"do\s+not\s+pay\s+on\s+ebay|contact\s+me\s+before\s+bidding|"
    r"contact\s+me\s+before\s+buying|message\s+me\s+directly\s+at|"
    r"[\w.-]+@gmail\.com"
    r")\b"
)

RE_AUCTION_INDICATORS = re.compile(
    r"(?i)\b(current\s+bid|starting\s+bid|place\s+bid|time\s+left|\d+\s+bids?|reserve\s+not\s+met)\b"
)

RE_BUY_IT_NOW_INDICATORS = re.compile(
    r"(?i)\b(buy\s+it\s+now|add\s+to\s+cart|fixed\s+price)\b"
)


# ── Data Models ────────────────────────────────────────────────────────

@dataclass
class ListingFeatures:
    url: str
    http_status: int
    raw_html: str
    extracted_text: str
    title: str = ""
    extracted_price: float | None = None
    shipping_price: float | None = None
    condition: str = "UNKNOWN"
    seller_username: str = ""
    seller_feedback_count: int = 0
    seller_positive_pct: float = 0.0
    is_auction: bool = False
    is_buy_it_now: bool = False


@dataclass
class VerificationResult:
    deal_alert_id: int | None
    hardware_id: str
    url: str
    is_authentic: bool
    verdict: str  # AUTHENTIC, PARTS_OR_DEFECTIVE, ACCESSORY_TRAP, SCAM_SUSPECTED, AUCTION_NOT_BIN, MISLEADING_SPEC, UNREACHABLE
    confidence: float  # 0.0 to 1.0
    red_flags: list[str]
    reasoning: str
    evaluator_model: str
    extracted_price: float | None = None
    extracted_condition: str = "UNKNOWN"
    seller_feedback_count: int = 0
    seller_positive_pct: float = 0.0
    is_auction: bool = False
    verified_at: int = 0


# ── HTML Text Parser Helper ────────────────────────────────────────────

class SimpleTextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text_parts: list[str] = []
        self.ignore_tags = {"script", "style", "noscript", "meta", "link"}
        self._current_tag = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]):
        self._current_tag = tag.lower()

    def handle_endtag(self, tag: str):
        if self._current_tag == tag.lower():
            self._current_tag = None

    def handle_data(self, data: str):
        if self._current_tag not in self.ignore_tags:
            cleaned = data.strip()
            if cleaned:
                self.text_parts.append(cleaned)

    def get_text(self) -> str:
        return " ".join(self.text_parts)


# ── Node 1: Web Page Retrieval ─────────────────────────────────────────

def fetch_listing_html(url: str, timeout: int = 10) -> tuple[int, str]:
    """Retrieve raw HTML from a listing URL using realistic browser fingerprinting."""
    if not url or url.startswith("https://example.com") or "fake-test" in url or "ebay.com/itm/12345" in url:
        # Synthetic / mock test handling
        return 200, f"<html><head><title>Mock Listing</title></head><body><h1>Mock Hardware Listing</h1><p>URL: {url}</p></body></html>"

    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Sec-Ch-Ua": '"Not(A:Brand";v="99", "Google Chrome";v="133", "Chromium";v="133"',
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": '"Windows"',
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Sec-Fetch-User": "?1",
        "Upgrade-Insecure-Requests": "1",
    }

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            content_type = resp.headers.get("Content-Type", "")
            encoding = "utf-8"
            if "charset=" in content_type.lower():
                encoding = content_type.lower().split("charset=")[-1].split(";")[0].strip()
            raw_bytes = resp.read()
            html_text = raw_bytes.decode(encoding, errors="replace")
            return status, html_text
    except Exception as e:
        logger.warning(f"urllib fetch error for {url}: {e}")

    # Fallback to curl
    try:
        cmd = [
            "curl", "-sL", "--connect-timeout", str(timeout), "-m", str(timeout + 5),
            "-H", f"User-Agent: {USER_AGENT}",
            "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            url
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 6)
        if res.returncode == 0 and res.stdout:
            return 200, res.stdout
    except Exception as e:
        logger.warning(f"curl fetch error for {url}: {e}")

    return 0, ""


# ── Node 2: Listing Feature Extraction ─────────────────────────────────

def extract_features(url: str, html: str, http_status: int) -> ListingFeatures:
    """Extract semantic and structural e-commerce features from HTML."""
    features = ListingFeatures(
        url=url,
        http_status=http_status,
        raw_html=html,
        extracted_text="",
    )

    if not html:
        return features

    # Extract plain text
    try:
        parser = SimpleTextExtractor()
        parser.feed(html)
        features.extracted_text = parser.get_text()
    except Exception:
        features.extracted_text = re.sub(r"<[^>]+>", " ", html)

    # 1. Page Title
    m_title = re.search(r"<title>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
    if m_title:
        title_str = m_title.group(1).strip()
        title_str = re.sub(r"\s*\|\s*eBay.*$", "", title_str, flags=re.IGNORECASE)
        features.title = title_str

    # 2. Price extraction
    # Look for eBay specific price elements: <span class="x-price-primary">...</span>
    price_patterns = [
        r'class="[^"]*x-price-primary[^"]*">[^<]*\$([0-9,]+\.?[0-9]*)',
        r'itemprop="price"[^>]*content="([0-9.]+)"',
        r'id="prcIsum"[^>]*content="([0-9.]+)"',
        r'class="[^"]*notranslate[^"]*" id="mm-saleDscPrc">[^<]*\$([0-9,]+\.?[0-9]*)',
        r'\$([0-9,]+\.[0-9]{2})',
    ]
    for pat in price_patterns:
        m_pr = re.search(pat, html, re.IGNORECASE)
        if m_pr:
            try:
                features.extracted_price = float(m_pr.group(1).replace(",", ""))
                break
            except Exception:
                pass

    # 3. Item Condition
    # eBay condition element: <div class="x-item-condition-value">...</div>
    m_cond = re.search(r'class="[^"]*x-item-condition-value[^"]*"[^>]*>(.*?)</div>', html, re.IGNORECASE | re.DOTALL)
    if m_cond:
        features.condition = re.sub(r"<[^>]+>", "", m_cond.group(1)).strip()
    elif "for parts or not working" in features.extracted_text.lower():
        features.condition = "For parts or not working"
    elif "open box" in features.extracted_text.lower():
        features.condition = "Open box"
    elif "brand new" in features.extracted_text.lower():
        features.condition = "Brand New"
    elif "used" in features.extracted_text.lower():
        features.condition = "Used"

    # 4. Seller Feedback Stats
    # e.g. (1,234) 99.4% or 1420 feedback, 99.8% positive or score
    m_seller = re.search(r'\(([\d,]+)\)\s*([0-9.]+)%', html)
    if not m_seller:
        m_seller = re.search(r'([\d,]+)\s*(?:feedback|score).*?([0-9.]+)%', html, re.IGNORECASE)
    if m_seller:
        try:
            features.seller_feedback_count = int(m_seller.group(1).replace(",", ""))
            features.seller_positive_pct = float(m_seller.group(2))
        except Exception:
            pass

    # 5. Listing Format: Auction vs Buy It Now
    if RE_AUCTION_INDICATORS.search(html[:15000]) and not RE_BUY_IT_NOW_INDICATORS.search(html[:15000]):
        features.is_auction = True
    if RE_BUY_IT_NOW_INDICATORS.search(html[:15000]):
        features.is_buy_it_now = True

    return features


# ── Node 3: Forensic Red-Flag Audit ────────────────────────────────────

def forensic_audit(features: ListingFeatures, model_name: str, target_fmv: float) -> tuple[bool, str, float, list[str], str]:
    """
    Run comprehensive forensic rule checks against the listing.
    Returns: (is_authentic, verdict, confidence, red_flags, reasoning)
    """
    text_corpus = f"{features.title} {features.condition} {features.extracted_text}"
    red_flags: list[str] = []

    # 0. Check if page retrieval failed or was blocked by anti-bot
    if features.http_status != 200 or not features.raw_html or len(features.raw_html) < 200:
        red_flags.append(f"UNREACHABLE_OR_BLOCKED (HTTP {features.http_status})")
        return (
            False,
            "UNREACHABLE",
            0.85,
            red_flags,
            f"Listing webpage could not be fetched (HTTP status {features.http_status}). Authenticity unverified.",
        )

    m_challenge = re.search(
        r"(?i)(error page \| ebay|security measure|just a moment\.\.\.|attention required! \| cloudflare|"
        r"cloudflare ray id|ddos protection by cloudflare|cf-browser-verification|challenge-platform|"
        r"verify you are human|verifying that you are not a robot|captcha|datadome|perimeterx|vercel security checkpoint|"
        r"vercel-challenge|deployment-protection|checking your browser)",
        f"{features.title} {text_corpus[:4000]}"
    )
    if m_challenge:
        red_flags.append("ANTI_BOT_BLOCKED")
        return (
            False,
            "FETCH_BLOCKED",
            0.85,
            red_flags,
            f"Listing webpage blocked by anti-bot challenge ('{m_challenge.group(0)}'). Authenticity unverified.",
        )

    # 1. Defective / Broken / Parts Trap
    m_defect = RE_DEFECTIVE_CONDITIONS.search(text_corpus)
    if m_defect or "for parts" in features.condition.lower():
        matched_kw = m_defect.group(0) if m_defect else features.condition
        red_flags.append(f"DEFECTIVE_OR_PARTS_ONLY: '{matched_kw}'")
        return (
            False,
            "PARTS_OR_DEFECTIVE",
            0.98,
            red_flags,
            f"Listing is defective/non-functional ('{matched_kw}'). Discarded as scrap/parts trap.",
        )

    # 2. Accessory / Empty Box Trap
    m_acc = RE_ACCESSORY_TRAPS.search(text_corpus)
    if m_acc:
        matched_acc = m_acc.group(0)
        red_flags.append(f"ACCESSORY_OR_BOX_TRAP: '{matched_acc}'")
        return (
            False,
            "ACCESSORY_TRAP",
            0.99,
            red_flags,
            f"Listing is an accessory, cooler, or empty packaging ('{matched_acc}'), not the actual silicon accelerator.",
        )

    # 3. Off-Platform Scam Solicitations
    m_scam = RE_SCAM_SOLICITATIONS.search(text_corpus)
    if m_scam:
        matched_scam = m_scam.group(0)
        red_flags.append(f"OFF_PLATFORM_SCAM_CONTACT: '{matched_scam}'")
        return (
            False,
            "SCAM_SUSPECTED",
            0.99,
            red_flags,
            f"High scam risk detected: seller solicits off-platform contact/payment ('{matched_scam}').",
        )

    # 4. Auction Starting Bid Masquerading as Buy It Now Deal
    if features.is_auction and not features.is_buy_it_now:
        red_flags.append("AUCTION_BID_NOT_BUY_IT_NOW")
        return (
            False,
            "AUCTION_NOT_BIN",
            0.92,
            red_flags,
            "Price represents an early auction opening bid or active bidding price, NOT a guaranteed Buy-It-Now deal.",
        )

    # 5. Untrusted Zero-Feedback Seller with Unrealistic Price
    if features.seller_feedback_count == 0 and features.extracted_price:
        if features.extracted_price < (target_fmv * 0.60):
            red_flags.append("ZERO_FEEDBACK_SELLER_EXTREME_DISCOUNT")
            return (
                False,
                "SCAM_SUSPECTED",
                0.90,
                red_flags,
                f"High fraud probability: 0-feedback seller offering {model_name} at ${features.extracted_price:.0f} (>40% below FMV).",
            )

    # 6. Misleading Keyword Stuffing
    if "not a 3090" in text_corpus.lower() or "not a 4090" in text_corpus.lower():
        red_flags.append("KEYWORD_BAIT_NOT_ACTUAL_MODEL")
        return (
            False,
            "MISLEADING_SPEC",
            0.95,
            red_flags,
            "Listing description clarifies this is NOT the targeted GPU model (search keyword stuffing).",
        )

    # 7. Unconfirmed / Ambiguous Condition Check
    valid_working_conditions = {"used", "open box", "brand new", "new", "refurbished", "seller refurbished", "certified - refurbished"}
    is_known_condition = features.condition.lower() in valid_working_conditions
    has_working_mention = any(w in text_corpus.lower() for w in [
        "tested working", "functional", "fully working", "working pull",
        "passes memtest", "tested and working", "operational", "100% working",
        "good working condition", "perfect working condition"
    ])

    if not is_known_condition and not has_working_mention:
        red_flags.append("UNCONFIRMED_WORKING_CONDITION")
        return (
            False,
            "UNCONFIRMED_CONDITION",
            0.80,
            red_flags,
            f"Listing condition is ambiguous or unverified ('{features.condition}'). Withholding verified deal status until functional state is confirmed.",
        )

    # Passed all forensic tests
    cond_str = features.condition if features.condition != "UNKNOWN" else "Functional/Working"
    return (
        True,
        "AUTHENTIC",
        0.92,
        [],
        f"Verified authentic {model_name} listing. Condition: {cond_str}. No forensic red flags detected.",
    )


# ── Node 4: Agentic / LLM Semantic Verification ────────────────────────

def agentic_llm_eval(
    features: ListingFeatures,
    model_name: str,
    price: float,
    forensic_verdict: str,
    forensic_reasoning: str,
    red_flags: list[str],
) -> tuple[bool, str, float, str]:
    """
    Query Sovereign LLM Inference Fabric (llama.cpp on port 8080) for semantic reasoning.
    Falls back gracefully to forensic rule output if local LLM is offline.
    """
    # If forensic audit already caught an explicit scam, box, or parts trap, trust high confidence
    if forensic_verdict in ("PARTS_OR_DEFECTIVE", "ACCESSORY_TRAP", "SCAM_SUSPECTED"):
        return False, forensic_verdict, 0.99, forensic_reasoning

    prompt = f"""You are the Sovereign Hardware Intelligence Agent for Blue Lodge.
Determine if the following secondary marketplace listing is a REAL, AUTHENTIC deal for an active computing unit, or a FAKE / MISLEADING listing (e.g. broken/for parts, empty box, auction bid, accessory, or scam).

TARGET HARDWARE: {model_name}
LISTED PRICE: ${price:.2f}
PAGE TITLE: {features.title}
CONDITION: {features.condition}
SELLER STATS: {features.seller_feedback_count} feedback, {features.seller_positive_pct}% positive
LISTING TEXT SNIPPET:
{features.extracted_text[:1200]}

Respond ONLY with a JSON object in this exact format:
{{"is_authentic": true_or_false, "verdict": "AUTHENTIC"|"PARTS_OR_DEFECTIVE"|"ACCESSORY_TRAP"|"AUCTION_NOT_BIN"|"SCAM_SUSPECTED"|"MISLEADING_SPEC", "confidence": 0.0_to_1.0, "reasoning": "Brief explanation"}}
"""

    try:
        req_data = json.dumps({"prompt": prompt, "n_predict": 250, "temperature": 0.1}).encode("utf-8")
        req = urllib.request.Request(
            "http://127.0.0.1:8080/completion",
            data=req_data,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = data.get("content", "").strip()
            # Extract JSON block
            m_json = re.search(r"\{.*\}", content, re.DOTALL)
            if m_json:
                res = json.loads(m_json.group(0))
                return (
                    bool(res.get("is_authentic", True)),
                    res.get("verdict", forensic_verdict),
                    float(res.get("confidence", 0.90)),
                    res.get("reasoning", forensic_reasoning),
                )
    except Exception:
        pass

    # Deterministic Fallback to forensic audit
    is_auth = (forensic_verdict == "AUTHENTIC")
    conf = 0.95 if is_auth else 0.92
    return is_auth, forensic_verdict, conf, forensic_reasoning


# ── Node 5: Verification Graph Orchestrator ────────────────────────────

def verify_deal_candidate(
    deal_alert_id: int | None,
    observation_id: int | None,
    hardware_id: str,
    model_name: str,
    price: float,
    url: str,
    target_fmv: float,
    injected_html: str | None = None,
    conn: sqlite3.Connection | None = None,
) -> VerificationResult:
    """
    Run full end-to-end Deal Verification Graph.
    Pulls down listing website, extracts features, audits red flags, invokes agent eval,
    and commits verdict into events.db.
    """
    logger.info(f"Executing Deal Verification Graph for '{model_name}' at ${price:.2f} (URL: {url})...")

    # 1. Fetch
    if injected_html is not None:
        if os.path.exists(injected_html):
            try:
                injected_html = Path(injected_html).read_text(encoding="utf-8")
            except Exception:
                pass
        status, html = 200, injected_html
    else:
        status, html = fetch_listing_html(url)

    # 2. Extract
    features = extract_features(url, html, status)

    # 3. Forensic Rules Audit
    is_auth_rule, verdict_rule, conf_rule, red_flags, reasoning_rule = forensic_audit(
        features, model_name, target_fmv
    )

    # 4. Agentic / LLM Semantic Evaluation
    is_auth, verdict, confidence, reasoning = agentic_llm_eval(
        features, model_name, price, verdict_rule, reasoning_rule, red_flags
    )

    now_ts = int(time.time())
    result = VerificationResult(
        deal_alert_id=deal_alert_id,
        hardware_id=hardware_id,
        url=url,
        is_authentic=is_auth,
        verdict=verdict,
        confidence=confidence,
        red_flags=red_flags,
        reasoning=reasoning,
        evaluator_model="deal_verifier_graph",
        extracted_price=features.extracted_price or price,
        extracted_condition=features.condition,
        seller_feedback_count=features.seller_feedback_count,
        seller_positive_pct=features.seller_positive_pct,
        is_auction=features.is_auction,
        verified_at=now_ts,
    )

    # 5. Persist into SQLite
    try:
        from event_store import record_deal_verification
        record_deal_verification(
            deal_alert_id=deal_alert_id,
            observation_id=observation_id,
            hardware_id=hardware_id,
            url=url,
            is_authentic=is_auth,
            verdict=verdict,
            confidence=confidence,
            reasoning=reasoning,
            http_status=status,
            fetched_title=features.title,
            condition=features.condition,
            seller_feedback_count=features.seller_feedback_count,
            seller_positive_pct=features.seller_positive_pct,
            is_auction=features.is_auction,
            extracted_price_usd=features.extracted_price,
            red_flags=red_flags,
            evaluator_model="deal_verifier_graph",
            conn=conn,
        )
    except Exception as e:
        logger.warning(f"Failed to record deal verification in event store: {e}")

    # 6. Emit verification event into Event Bus
    bus_event = "compute_deal_verified" if is_auth else "compute_deal_rejected"
    try:
        fifo_path = _GEORGE_DIR / "ipc" / "event_bus.fifo"
        if fifo_path.exists():
            payload = {
                "deal_alert_id": deal_alert_id,
                "hardware_id": hardware_id,
                "model": model_name,
                "url": url,
                "is_authentic": is_auth,
                "verdict": verdict,
                "reasoning": reasoning,
                "confidence": confidence,
            }
            envelope = json.dumps({
                "type": bus_event,
                "payload": payload,
                "source": "deal_verifier_graph",
                "timestamp": now_ts,
            })
            # Non-blocking write to fifo
            cmd = f"printf '%s\\n' {json.dumps(envelope)} > {fifo_path} &"
            subprocess.Popen(["bash", "-c", cmd])
    except Exception:
        pass

    return result


def verify_pending_deals(conn: sqlite3.Connection | None = None) -> list[VerificationResult]:
    """Verify all compute deal alerts currently in PENDING verification status."""
    should_close = False
    if conn is None:
        from event_store import init_db
        conn = init_db()
        should_close = True

    try:
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT d.id, d.observation_id, d.hardware_id, d.total_price_usd,
                   h.model, h.target_fmv_usd, o.url, o.raw_title
            FROM compute_deal_alerts d
            JOIN compute_hardware_specs h ON d.hardware_id = h.id
            JOIN compute_market_observations o ON d.observation_id = o.id
            WHERE d.status = 'ACTIVE' AND (d.verification_status IS NULL OR d.verification_status = 'PENDING')
            ORDER BY d.created_at DESC
            """
        )
        rows = cursor.fetchall()
        results = []
        for r in rows:
            res = verify_deal_candidate(
                deal_alert_id=r[0],
                observation_id=r[1],
                hardware_id=r[2],
                model_name=r[4],
                price=r[3],
                url=r[6],
                target_fmv=r[5],
                conn=conn,
            )
            results.append(res)
        return results
    finally:
        if should_close:
            conn.close()


# ── CLI Interface ──────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Agentic Deal Verification Graph")
    parser.add_argument("--url", type=str, help="Listing URL to verify")
    parser.add_argument("--model", type=str, default="GeForce RTX 3090", help="Hardware model name")
    parser.add_argument("--price", type=float, default=499.0, help="Candidate listing price")
    parser.add_argument("--target-fmv", type=float, default=680.0, help="Target FMV benchmark")
    parser.add_argument("--hardware-id", type=str, default="RTX_3090_24GB", help="Hardware ID")
    parser.add_argument("--mock-html", type=str, help="Simulate page content with mock HTML text")
    parser.add_argument("--deal-id", type=int, help="Verify specific deal ID from database")
    parser.add_argument("--verify-pending", action="store_true", help="Verify all pending deals in database")
    parser.add_argument("--db-path", type=Path, help="Custom SQLite database path")
    parser.add_argument("--json", action="store_true", help="Output result as JSON")

    args = parser.parse_args()

    custom_conn = None
    if args.db_path:
        from event_store import init_db
        custom_conn = init_db(args.db_path)

    if args.verify_pending:
        results = verify_pending_deals(conn=custom_conn)
        if args.json:
            print(json.dumps([asdict(r) for r in results], indent=2))
        else:
            print("=" * 76)
            print(f"  VERIFIED {len(results)} PENDING DEALS")
            print("=" * 76)
            for r in results:
                status_str = "[VERIFIED AUTHENTIC]" if r.is_authentic else f"[REJECTED: {r.verdict}]"
                print(f"  {status_str} {r.hardware_id}")
                print(f"      URL:       {r.url}")
                print(f"      Reasoning: {r.reasoning}")
                print()
            print("=" * 76)
        if custom_conn:
            custom_conn.close()
        sys.exit(0)

    if args.deal_id:
        from event_store import init_db
        conn = custom_conn if custom_conn else init_db()
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT d.id, d.observation_id, d.hardware_id, d.total_price_usd,
                   h.model, h.target_fmv_usd, o.url
            FROM compute_deal_alerts d
            JOIN compute_hardware_specs h ON d.hardware_id = h.id
            JOIN compute_market_observations o ON d.observation_id = o.id
            WHERE d.id = ?
            """,
            (args.deal_id,)
        )
        row = cursor.fetchone()
        if not row:
            print(f"[ERROR] Deal ID {args.deal_id} not found.", file=sys.stderr)
            sys.exit(1)
        res = verify_deal_candidate(
            deal_alert_id=row[0],
            observation_id=row[1],
            hardware_id=row[2],
            model_name=row[4],
            price=row[3],
            url=row[6],
            target_fmv=row[5],
            injected_html=args.mock_html,
            conn=conn,
        )
        conn.close()
        if args.json:
            print(json.dumps(asdict(res), indent=2))
        else:
            status_str = "[VERIFIED AUTHENTIC]" if res.is_authentic else f"[REJECTED: {res.verdict}]"
            print(f"{status_str} {res.hardware_id} (Verdict: {res.verdict})")
            print(f"  Reasoning: {res.reasoning}")
        sys.exit(0)

    if args.url:
        res = verify_deal_candidate(
            deal_alert_id=None,
            observation_id=None,
            hardware_id=args.hardware_id,
            model_name=args.model,
            price=args.price,
            url=args.url,
            target_fmv=args.target_fmv,
            injected_html=args.mock_html,
            conn=custom_conn,
        )
        if custom_conn:
            custom_conn.close()
        if args.json:
            print(json.dumps(asdict(res), indent=2))
        else:
            status_str = "[VERIFIED AUTHENTIC]" if res.is_authentic else f"[REJECTED: {res.verdict}]"
            print("=" * 76)
            print(f"  SOVEREIGN DEAL VERIFIER AUDIT REPORT")
            print("=" * 76)
            print(f"  Status:       {status_str}")
            print(f"  Verdict:      {res.verdict} (Confidence: {res.confidence*100:.0f}%)")
            print(f"  Target Model: {args.model}  |  Price: ${args.price:.2f}")
            print(f"  Listing URL:  {args.url}")
            print(f"  Reasoning:    {res.reasoning}")
            if res.red_flags:
                print(f"  Red Flags:    {', '.join(res.red_flags)}")
            print("=" * 76)
        sys.exit(0)

    parser.print_help()


if __name__ == "__main__":
    main()
