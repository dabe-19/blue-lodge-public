#!/usr/bin/env python3
"""
social_analytics.py — Zero-X-Budget Social Engagement & Domain/Timing Resonance Engine
======================================================================================
Harvests engagement metrics (likes/favourites, reposts/boosts, replies) across:
  1. Mastodon API (free, using configured instance + token in .george/keys.conf or mastodon_instances.db)
  2. Bluesky Public AppView API (free, unauthenticated getAuthorFeed)
  3. X Free Syndication Endpoint (cdn.syndication.twimg.com/tweet-result, 0 Developer API quota)

Cross-references `.george/social/blog_history.jsonl` with `.george/research/research_index.jsonl`
to compute:
  - Per-domain engagement resonance (Finance, Gaming, Engineering, Sports/Auto, Academic)
  - Time-of-day UTC window resonance (00-06, 06-12, 12-18, 18-24 UTC)
  - Recommended optimal domain & posting window for `auto_optimal` rotation mode

Usage:
  python3 lib/tools/social_analytics.py sync [--lodge-dir PATH]
  python3 lib/tools/social_analytics.py summary [--lodge-dir PATH]
  python3 lib/tools/social_analytics.py recommend-domain [--lodge-dir PATH]
"""

import argparse
import datetime
import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


DOMAIN_LABELS = {
    "finance": "Finance & Macro",
    "gaming": "Gaming & Emulation",
    "engineering": "Systems & Security",
    "general_sports_auto": "Sports & Automotive",
    "academic": "AI / ML & Science",
}

TIME_WINDOWS = [
    ("00:00–06:00 UTC", 0, 6),
    ("06:00–12:00 UTC", 6, 12),
    ("12:00–18:00 UTC", 12, 18),
    ("18:00–24:00 UTC", 18, 24),
]


def parse_multi_json_stream(raw_text: str) -> List[Dict[str, Any]]:
    """Parse a file containing either single-line JSONL or concatenated multi-line JSON objects."""
    decoder = json.JSONDecoder()
    idx = 0
    length = len(raw_text)
    results: List[Dict[str, Any]] = []
    while idx < length:
        while idx < length and raw_text[idx].isspace():
            idx += 1
        if idx >= length:
            break
        try:
            obj, next_idx = decoder.raw_decode(raw_text, idx)
            if isinstance(obj, dict):
                results.append(obj)
            idx = next_idx
        except json.JSONDecodeError:
            next_nl = raw_text.find("\n", idx)
            if next_nl == -1:
                break
            idx = next_nl + 1
    return results


def get_vault_secret(george_dir: Path, name: str) -> str:
    """Decrypt a secret from .george/.vault/<name>.enc using .george/.keyring/signing.key."""
    import subprocess

    enc_file = george_dir / ".vault" / f"{name}.enc"
    key_file = george_dir / ".keyring" / "signing.key"
    if not enc_file.exists() or not key_file.exists():
        return ""
    try:
        key = key_file.read_text(encoding="utf-8", errors="replace").strip()
        if not key:
            return ""
        res = subprocess.run(
            [
                "openssl",
                "enc",
                "-aes-256-cbc",
                "-d",
                "-pbkdf2",
                "-iter",
                "100000",
                "-pass",
                f"pass:{key}",
                "-in",
                str(enc_file),
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if res.returncode == 0 and res.stdout:
            return res.stdout.strip()
    except Exception:
        pass
    return ""


def load_keys_conf(george_dir: Path) -> Dict[str, str]:
    """Load key=value pairs from .george/keys.conf and .george/.vault without shell execution."""
    keys: Dict[str, str] = {}
    conf_path = george_dir / "keys.conf"
    if conf_path.exists():
        try:
            for line in conf_path.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    v = v.strip().strip('"').strip("'")
                    keys[k.strip()] = v
        except Exception:
            pass
    for vault_key in ("MASTODON_INSTANCE", "MASTODON_ACCESS_TOKEN", "BLUESKY_HANDLE"):
        if not keys.get(vault_key):
            val = get_vault_secret(george_dir, vault_key)
            if val:
                keys[vault_key] = val
    return keys


def get_mastodon_credentials(george_dir: Path, keys: Dict[str, str]) -> Optional[Tuple[str, str]]:
    """Resolve primary Mastodon (instance_url, access_token) from SQLite mastodon_instances.db or keys.conf."""
    import sqlite3

    for db_candidate in [george_dir / "mastodon_instances.db", george_dir / "social" / "mastodon_instances.db"]:
        if db_candidate.exists():
            try:
                conn = sqlite3.connect(str(db_candidate))
                row = conn.execute("SELECT instance_url, access_token FROM instances ORDER BY rowid ASC LIMIT 1").fetchone()
                conn.close()
                if row and row[0] and row[1]:
                    inst = str(row[0]).strip().rstrip("/")
                    if not inst.startswith("http"):
                        inst = f"https://{inst}"
                    return inst, str(row[1]).strip()
            except Exception:
                pass
    inst = os.environ.get("MASTODON_INSTANCE") or keys.get("MASTODON_INSTANCE", "") or "https://mastodon.social"
    token = os.environ.get("MASTODON_ACCESS_TOKEN") or keys.get("MASTODON_ACCESS_TOKEN", "")
    if token:
        inst = inst.strip().rstrip("/")
        if not inst.startswith("http"):
            inst = f"https://{inst}"
        return inst, token.strip()
    return None


def http_get_json(url: str, headers: Optional[Dict[str, str]] = None, timeout: float = 8.0) -> Any:
    req_headers = {
        "User-Agent": "George-BlueLodge-Analytics/1.0",
        "Accept": "application/json",
    }
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def strip_html_tags(text: str) -> str:
    cleaned = re.sub(r"<[^>]+>", " ", text or "")
    cleaned = html.unescape(cleaned)
    return re.sub(r"\s+", " ", cleaned).strip()


def fetch_mastodon_statuses(george_dir: Path, keys: Dict[str, str]) -> List[Dict[str, Any]]:
    """Fetch recent statuses from the operator's Mastodon account ($0 API cost)."""
    creds = get_mastodon_credentials(george_dir, keys)
    if not creds:
        return []
    base_url, token = creds
    auth_headers = {"Authorization": f"Bearer {token}"}
    all_statuses: List[Dict[str, Any]] = []
    try:
        acct = http_get_json(f"{base_url}/api/v1/accounts/verify_credentials", headers=auth_headers)
        acct_id = acct.get("id")
        if not acct_id:
            return []
        max_id = ""
        for _ in range(4):
            q = "limit=40&exclude_reblogs=true"
            if max_id:
                q += f"&max_id={max_id}"
            page = http_get_json(
                f"{base_url}/api/v1/accounts/{acct_id}/statuses?{q}",
                headers=auth_headers,
            )
            if not isinstance(page, list) or not page:
                break
            all_statuses.extend(page)
            max_id = str(page[-1].get("id") or "")
            if not max_id or len(page) < 40:
                break
    except Exception:
        pass
    return all_statuses


def fetch_bluesky_feed(keys: Dict[str, str]) -> List[Dict[str, Any]]:
    """Fetch recent posts from Bluesky public AppView API ($0 API cost)."""
    handle = os.environ.get("BLUESKY_HANDLE") or keys.get("BLUESKY_HANDLE", "")
    if not handle:
        return []
    try:
        q = urllib.parse.urlencode({"actor": handle, "limit": 40})
        data = http_get_json(f"https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?{q}")
        feed = data.get("feed", [])
        if isinstance(feed, list):
            return [item.get("post", {}) for item in feed if isinstance(item, dict) and item.get("post")]
    except Exception:
        pass
    return []


def fetch_x_syndication(tweet_id: str) -> Optional[Dict[str, Any]]:
    """Fetch public engagement counts for a single X post via syndication embed endpoint ($0 API cost)."""
    if not tweet_id or not str(tweet_id).isdigit():
        return None
    try:
        url = f"https://cdn.syndication.twimg.com/tweet-result?id={tweet_id}&token=x"
        data = http_get_json(url, timeout=6.0)
        if isinstance(data, dict):
            return {
                "likes": int(data.get("favorite_count", 0) or 0),
                "replies": int(data.get("conversation_count", 0) or 0),
                "reposts": int(data.get("retweet_count", 0) or 0),
            }
    except Exception:
        pass
    return None


def clean_topic_title(topic: str) -> str:
    return re.sub(r"^\[[^\]]+\]\s*", "", (topic or "").strip())


def extract_slug_from_filename(filename: str) -> str:
    m = re.match(r"^[0-9]+_research_(.+)\.txt$", filename or "")
    return m.group(1) if m else ""


def match_mastodon_status(
    slug: str,
    topic: str,
    published_at: str,
    mastodon_root_id: str,
    statuses: List[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    if not statuses:
        return None
    if mastodon_root_id:
        for st in statuses:
            if str(st.get("id", "")) == str(mastodon_root_id):
                return st

    clean_t = clean_topic_title(topic).lower()
    title_words = [w for w in re.findall(r"[a-z0-9]{4,}", clean_t) if len(w) >= 4][:5]

    pub_dt: Optional[datetime.datetime] = None
    if published_at:
        try:
            pub_dt = datetime.datetime.fromisoformat(published_at.replace("Z", "+00:00"))
        except Exception:
            pub_dt = None

    best_match = None
    best_score = 0.0

    for st in statuses:
        # Prefer root statuses (in_reply_to_id is None) when matching thread heads
        is_root = st.get("in_reply_to_id") is None
        text = strip_html_tags(st.get("content", "")).lower()
        score = 0.0
        if clean_t and clean_t[:28] in text:
            score += 5.0
        elif title_words:
            hits = sum(1 for w in title_words if w in text)
            if hits >= 2:
                score += hits * 1.2

        if pub_dt and st.get("created_at"):
            try:
                st_dt = datetime.datetime.fromisoformat(st["created_at"].replace("Z", "+00:00"))
                diff_sec = abs((st_dt - pub_dt).total_seconds())
                if diff_sec <= 600:
                    score += 4.0
                elif diff_sec <= 3600:
                    score += 2.0
            except Exception:
                pass

        if is_root and score > 0:
            score += 1.5

        if score > best_score and score >= 3.5:
            best_score = score
            best_match = st

    return best_match


def aggregate_mastodon_thread_metrics(
    root_st: Dict[str, Any], all_statuses: List[Dict[str, Any]]
) -> Tuple[int, int, int]:
    """Sum favourites & reblogs across all statuses in the thread and count only external replies."""
    by_parent: Dict[str, List[Dict[str, Any]]] = {}
    for st in all_statuses:
        pid = str(st.get("in_reply_to_id") or "")
        if pid:
            by_parent.setdefault(pid, []).append(st)

    total_favs = 0
    total_reblogs = 0
    external_replies = 0

    queue = [root_st]
    visited = set()
    while queue:
        curr = queue.pop(0)
        cid = str(curr.get("id") or "")
        if not cid or cid in visited:
            continue
        visited.add(cid)
        total_favs += int(curr.get("favourites_count", 0) or 0)
        total_reblogs += int(curr.get("reblogs_count", 0) or 0)
        self_children = by_parent.get(cid, [])
        rep_cnt = int(curr.get("replies_count", 0) or 0)
        ext = max(0, rep_cnt - len(self_children))
        external_replies += ext
        queue.extend(self_children)

    return total_favs, total_reblogs, external_replies


def sync_telemetry(lodge_dir: Path, live_network: bool = True) -> Dict[str, Any]:
    env_george = os.environ.get("GEORGE_DIR")
    george_dir = Path(env_george).resolve() if env_george else (lodge_dir / ".george")
    social_dir = george_dir / "social"
    research_dir = george_dir / "research"
    social_dir.mkdir(parents=True, exist_ok=True)

    history_file = social_dir / "blog_history.jsonl"
    index_file = research_dir / "research_index.jsonl"
    telemetry_file = social_dir / "engagement_telemetry.json"

    # Load research_index.jsonl map by slug
    index_by_slug: Dict[str, Dict[str, Any]] = {}
    if index_file.exists():
        for obj in parse_multi_json_stream(index_file.read_text(encoding="utf-8", errors="replace")):
            s = obj.get("slug")
            if s:
                index_by_slug[s] = obj

    # Load existing telemetry cache so previously fetched X/Mastodon metrics persist even if scrolled off 40-post feed
    prev_cache_by_slug: Dict[str, Dict[str, Any]] = {}
    if telemetry_file.exists():
        try:
            prev_data = json.loads(telemetry_file.read_text(encoding="utf-8", errors="replace"))
            for item in prev_data.get("broadcasts", []):
                if item.get("slug"):
                    prev_cache_by_slug[item["slug"]] = item
        except Exception:
            pass

    raw_history: List[Dict[str, Any]] = []
    if history_file.exists():
        raw_history = parse_multi_json_stream(history_file.read_text(encoding="utf-8", errors="replace"))

    # Deduplicate history records by filename (keep latest or most complete entry)
    dedup_history: Dict[str, Dict[str, Any]] = {}
    for entry in raw_history:
        fname = entry.get("filename") or ""
        if not fname:
            continue
        prev = dedup_history.get(fname)
        if not prev or entry.get("status") == "complete":
            dedup_history[fname] = entry

    keys = load_keys_conf(george_dir)
    masto_statuses = fetch_mastodon_statuses(george_dir, keys) if live_network else []
    bsky_posts = fetch_bluesky_feed(keys) if live_network else []

    broadcasts: List[Dict[str, Any]] = []
    for fname, entry in dedup_history.items():
        slug = entry.get("slug") or extract_slug_from_filename(fname)
        idx_meta = index_by_slug.get(slug, {})
        domain = entry.get("domain") or idx_meta.get("domain") or ""
        topic = entry.get("topic") or idx_meta.get("topic") or slug

        # Also check dossier.md if domain is still missing
        if not domain and slug and (research_dir / slug / "dossier.md").exists():
            try:
                d_txt = (research_dir / slug / "dossier.md").read_text(encoding="utf-8", errors="replace")
                m_dom = re.search(r"^\*\*Domain\*\*:\s*(\S+)", d_txt, re.MULTILINE)
                if m_dom:
                    domain = m_dom.group(1).strip()
            except Exception:
                pass
        if not domain:
            domain = "academic"

        published_at = entry.get("published_at") or idx_meta.get("timestamp") or ""
        hour_utc = entry.get("hour_utc")
        day_of_week = entry.get("day_of_week") or ""
        if published_at and (hour_utc is None or not day_of_week):
            try:
                dt = datetime.datetime.fromisoformat(published_at.replace("Z", "+00:00"))
                hour_utc = dt.hour
                day_of_week = dt.strftime("%A")
            except Exception:
                hour_utc = 0
                day_of_week = "Unknown"

        prev_item = prev_cache_by_slug.get(slug, {})

        masto_likes = int(prev_item.get("mastodon_likes", 0) or 0)
        masto_boosts = int(prev_item.get("mastodon_reposts", 0) or 0)
        masto_replies = int(prev_item.get("mastodon_replies", 0) or 0)
        masto_url = entry.get("mastodon_url") or prev_item.get("mastodon_url") or ""
        masto_id = entry.get("mastodon_root_id") or prev_item.get("mastodon_root_id") or ""

        matched_st = match_mastodon_status(slug, topic, published_at, masto_id, masto_statuses)
        if matched_st:
            masto_likes, masto_boosts, masto_replies = aggregate_mastodon_thread_metrics(
                matched_st, masto_statuses
            )
            masto_url = matched_st.get("url") or masto_url
            masto_id = str(matched_st.get("id") or masto_id)

        bsky_likes = int(prev_item.get("bluesky_likes", 0) or 0)
        bsky_reposts = int(prev_item.get("bluesky_reposts", 0) or 0)
        bsky_replies = int(prev_item.get("bluesky_replies", 0) or 0)
        bsky_uri = entry.get("bluesky_uri") or prev_item.get("bluesky_uri") or ""

        if bsky_posts:
            clean_t = clean_topic_title(topic).lower()
            for bp in bsky_posts:
                rec = bp.get("record", {})
                btxt = (rec.get("text") or "").lower()
                if (bsky_uri and bp.get("uri") == bsky_uri) or (clean_t and clean_t[:25] in btxt):
                    bsky_likes = int(bp.get("likeCount", 0) or 0)
                    bsky_reposts = int(bp.get("repostCount", 0) or 0)
                    bsky_replies = int(bp.get("replyCount", 0) or 0)
                    bsky_uri = bp.get("uri") or bsky_uri
                    break

        x_id = entry.get("x_root_id") or prev_item.get("x_root_id") or ""
        x_likes = int(prev_item.get("x_likes", 0) or 0)
        x_reposts = int(prev_item.get("x_reposts", 0) or 0)
        x_replies = int(prev_item.get("x_replies", 0) or 0)
        if live_network and x_id:
            x_metrics = fetch_x_syndication(str(x_id))
            if x_metrics:
                x_likes = x_metrics["likes"]
                x_reposts = x_metrics["reposts"]
                x_replies = x_metrics["replies"]

        total_likes = masto_likes + bsky_likes + x_likes
        total_reposts = masto_boosts + bsky_reposts + x_reposts
        total_replies = masto_replies + bsky_replies + x_replies
        # Weighted resonance score: likes * 1 + reposts * 2 + replies * 1.5
        engagement_score = round(total_likes * 1.0 + total_reposts * 2.0 + total_replies * 1.5, 2)

        broadcasts.append(
            {
                "filename": fname,
                "slug": slug,
                "topic": clean_topic_title(topic),
                "domain": domain,
                "domain_label": DOMAIN_LABELS.get(domain, domain.title()),
                "published_at": published_at,
                "hour_utc": int(hour_utc or 0),
                "day_of_week": day_of_week,
                "succeeded": entry.get("succeeded", ""),
                "status": entry.get("status", "complete"),
                "mastodon_root_id": masto_id,
                "mastodon_url": masto_url,
                "mastodon_likes": masto_likes,
                "mastodon_reposts": masto_boosts,
                "mastodon_replies": masto_replies,
                "bluesky_uri": bsky_uri,
                "bluesky_likes": bsky_likes,
                "bluesky_reposts": bsky_reposts,
                "bluesky_replies": bsky_replies,
                "x_root_id": x_id,
                "x_likes": x_likes,
                "x_reposts": x_reposts,
                "x_replies": x_replies,
                "total_likes": total_likes,
                "total_reposts": total_reposts,
                "total_replies": total_replies,
                "engagement_score": engagement_score,
            }
        )

    broadcasts.sort(key=lambda b: b.get("published_at") or "", reverse=True)

    # Aggregate by domain
    domain_stats: Dict[str, Dict[str, Any]] = {}
    for dom_key, dom_label in DOMAIN_LABELS.items():
        domain_stats[dom_key] = {
            "domain": dom_key,
            "label": dom_label,
            "posts": 0,
            "likes": 0,
            "reposts": 0,
            "replies": 0,
            "total_score": 0.0,
            "avg_score": 0.0,
            "best_window": "—",
        }

    # Track domain x window scores
    domain_window_scores: Dict[str, Dict[str, List[float]]] = {d: {} for d in DOMAIN_LABELS}

    for b in broadcasts:
        dom = b["domain"] if b["domain"] in domain_stats else "academic"
        st = domain_stats[dom]
        st["posts"] += 1
        st["likes"] += b["total_likes"]
        st["reposts"] += b["total_reposts"]
        st["replies"] += b["total_replies"]
        st["total_score"] = round(st["total_score"] + b["engagement_score"], 2)

        hr = b["hour_utc"]
        win_label = "12:00–18:00 UTC"
        for wl, start_h, end_h in TIME_WINDOWS:
            if start_h <= hr < end_h:
                win_label = wl
                break
        domain_window_scores.setdefault(dom, {}).setdefault(win_label, []).append(b["engagement_score"])

    for dom_key, st in domain_stats.items():
        if st["posts"] > 0:
            st["avg_score"] = round(st["total_score"] / st["posts"], 2)
        win_map = domain_window_scores.get(dom_key, {})
        if win_map:
            best_w = max(
                win_map.items(),
                key=lambda kv: (sum(kv[1]) / len(kv[1]), len(kv[1])),
            )[0]
            st["best_window"] = best_w

    # Aggregate by UTC time window
    window_stats: List[Dict[str, Any]] = []
    for wl, start_h, end_h in TIME_WINDOWS:
        in_win = [b for b in broadcasts if start_h <= b["hour_utc"] < end_h]
        posts_cnt = len(in_win)
        likes_cnt = sum(b["total_likes"] for b in in_win)
        reposts_cnt = sum(b["total_reposts"] for b in in_win)
        replies_cnt = sum(b["total_replies"] for b in in_win)
        tot_sc = round(sum(b["engagement_score"] for b in in_win), 2)
        avg_sc = round(tot_sc / posts_cnt, 2) if posts_cnt > 0 else 0.0
        window_stats.append(
            {
                "window": wl,
                "start_hour": start_h,
                "end_hour": end_h,
                "posts": posts_cnt,
                "likes": likes_cnt,
                "reposts": reposts_cnt,
                "replies": replies_cnt,
                "total_score": tot_sc,
                "avg_score": avg_sc,
            }
        )

    # Compute recommended domain (highest avg_score if any engagement > 0, else least recently / under-sampled domain for balanced exploration)
    total_engagement = sum(st["total_score"] for st in domain_stats.values())
    if total_engagement > 0:
        recommended_domain_obj = max(
            domain_stats.values(),
            key=lambda s: (s["avg_score"], s["likes"], -s["posts"]),
        )
        recommendation_basis = "empirical_resonance"
    else:
        # UCB-style exploration: pick domain with fewest published posts
        recommended_domain_obj = min(
            domain_stats.values(),
            key=lambda s: s["posts"],
        )
        recommendation_basis = "exploration_balance"

    best_window_obj = max(
        window_stats,
        key=lambda w: (w["avg_score"], w["posts"]),
    )

    payload = {
        "synced_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "x_api_budget_used": 0,
        "total_broadcasts": len(broadcasts),
        "total_likes": sum(b["total_likes"] for b in broadcasts),
        "total_reposts": sum(b["total_reposts"] for b in broadcasts),
        "total_replies": sum(b["total_replies"] for b in broadcasts),
        "recommended_domain": recommended_domain_obj["domain"],
        "recommended_domain_label": recommended_domain_obj["label"],
        "recommendation_basis": recommendation_basis,
        "recommended_window": best_window_obj["window"],
        "domains": list(domain_stats.values()),
        "time_windows": window_stats,
        "broadcasts": broadcasts[:30],
    }

    telemetry_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Zero-X-Budget Social Engagement & Resonance Engine")
    parser.add_argument("action", choices=["sync", "summary", "recommend-domain"], nargs="?", default="summary")
    parser.add_argument("--lodge-dir", default=os.environ.get("LODGE_DIR", str(Path(__file__).resolve().parents[2])))
    parser.add_argument("--offline", action="store_true", help="Skip live network polling")
    args = parser.parse_args()

    lodge_dir = Path(args.lodge_dir).resolve()
    env_george = os.environ.get("GEORGE_DIR")
    george_dir = Path(env_george).resolve() if env_george else (lodge_dir / ".george")
    telemetry_file = george_dir / "social" / "engagement_telemetry.json"

    if args.action == "sync" or not telemetry_file.exists():
        data = sync_telemetry(lodge_dir, live_network=not args.offline)
    else:
        try:
            data = json.loads(telemetry_file.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            data = sync_telemetry(lodge_dir, live_network=not args.offline)

    if args.action == "recommend-domain":
        print(data.get("recommended_domain", "academic"))
    else:
        print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
