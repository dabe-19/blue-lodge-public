"""Sovereign, Fully Local Reverse Image Search & Visual Identification Engine for Blue Lodge.

Combines:
1. Local Vision Feature Extraction (VLM / Heuristics)
2. Two-Stage Visual Reconnaissance via SearXNG Metasearch (Google, Bing, DDG, eBay)
3. Deterministic Sub-Second Visual Feature Embedding & Re-Ranking (MobileCLIP-S0 / DINOv2 / dHash)
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import logging
import os
import re
import statistics
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

_LODGE_ROOT = Path(__file__).resolve().parents[2]
if str(_LODGE_ROOT) not in sys.path:
    sys.path.insert(0, str(_LODGE_ROOT))

from PIL import Image

from lib.tools.searxng_backend import search_images
from lib.tools.search_router import search_searxng_compat as search_searxng  # P4 unified router
from lib.tools.vision_embedder import (
    compute_color_profile,
    compute_image_dhash,
    get_vision_embedder,
    parse_image_input,
)

logger = logging.getLogger("reverse_image_search")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_MODEL_ID_CACHE: dict[str, str] = {}
_PRICE_RE = re.compile(r"\$\s*([0-9]{1,4}(?:\.[0-9]{2})?)")


def _resolve_active_model_id(ep: str) -> str | None:
    """Query GET {ep}/v1/models to discover the currently loaded PRISM/llama-server model ID."""
    if ep in _MODEL_ID_CACHE:
        return _MODEL_ID_CACHE[ep] or None
    try:
        req = urllib.request.Request(f"{ep}/v1/models", headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=4.0) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                models = data.get("data") or []
                if models and isinstance(models[0], dict) and models[0].get("id"):
                    mid = str(models[0]["id"])
                    _MODEL_ID_CACHE[ep] = mid
                    return mid
    except Exception:
        pass
    _MODEL_ID_CACHE[ep] = ""
    return None


def _encode_image_data_uri(image_input: Image.Image | str, max_dim: int = 768) -> str | None:
    """Downsample any image input to <= max_dim JPEG q=85 for fast local 27B multimodal prefill."""
    im = parse_image_input(image_input)
    if not im:
        return None
    im_rgb = im.convert("RGB")
    im_rgb.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    im_rgb.save(buf, format="JPEG", quality=85)
    b64_data = base64.b64encode(buf.getvalue()).decode("utf-8")
    return f"data:image/jpeg;base64,{b64_data}"


def _load_configured_vision_endpoints() -> list[str]:
    """Resolve candidate vision endpoints from environment and .george/endpoints.conf."""
    conf_vals: dict[str, str] = {}
    conf_path = _LODGE_ROOT / ".george" / "endpoints.conf"
    if conf_path.is_file():
        try:
            for raw in conf_path.read_text(encoding="utf-8", errors="replace").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf_vals[k.strip()] = v.strip().strip('"').strip("'")
        except Exception:
            pass

    candidates = [
        os.getenv("VISION_ENDPOINT_URL", ""),
        os.getenv("ACTIVE_ENDPOINT_URL", ""),
        os.getenv("TIER1_URL", "") or conf_vals.get("TIER1_URL", "http://127.0.0.1:8080"),
        os.getenv("TIER2_URL", "") or conf_vals.get("TIER2_URL", "http://127.0.0.1:18080"),
    ]
    seen: list[str] = []
    for c in candidates:
        c_clean = c.strip().rstrip("/")
        if c_clean and c_clean not in seen:
            seen.append(c_clean)
    return seen or ["http://127.0.0.1:8080"]


def _call_local_vlm_vision(
    image_inputs: Image.Image | str | list[Image.Image | str],
    prompt: str,
    domain: str = "general",
) -> dict[str, Any]:
    """Call configured llama-server multimodal vision endpoint(s) from endpoints.conf.

    Supports single or multi-image inputs (e.g. hero garment + brand tag + care/RN tag)
    and uses the active PRISM model resolved dynamically from /v1/models with a 75s timeout.
    """
    endpoints = _load_configured_vision_endpoints()
    items = image_inputs if isinstance(image_inputs, list) else [image_inputs]

    content_parts: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
    encoded_count = 0
    for item in items[:4]:
        uri = _encode_image_data_uri(item, max_dim=768)
        if uri:
            content_parts.append({"type": "image_url", "image_url": {"url": uri}})
            encoded_count += 1
    if encoded_count == 0:
        return {}

    if domain == "reseller":
        sys_instruction = (
            "You are an elite fashion reseller, thrift authentication expert, and visual forensics analyst. "
            "Inspect ALL provided photos together (garment front/back, brand label, size tag, style code, RN/CA number, fabric/care tag). "
            "Extract strictly valid JSON (no markdown fences) with keys:\n"
            "  brand (string), style_name (string), style_code (string), rn_number (string), "
            "  department (Women|Men|Kids|Home|Unisex), category (string), subcategory (string), "
            "  size (string), condition_guess (NWT|NWOT|EUC|GUC|Fair), color (string), material (string), "
            "  visible_text (string of exact tag/label text), entity_name (short listing title), "
            "  search_queries (array of 3-4 concise Poshmark/eBay comp search queries WITHOUT site: operators)."
        )
    else:
        sys_instruction = (
            "You are an elite visual forensics and product identification expert. "
            "Analyze the image(s) and extract: brand/manufacturer, exact product or entity name, "
            "archetype/category, colorway, visible text or serial numbers, and 3 targeted web search queries "
            "to locate matching product listings.\n"
            "Output strictly valid JSON with keys: brand, entity_name, archetype, colorway, visible_text, search_queries."
        )

    for ep in endpoints:
        try:
            model_id = _resolve_active_model_id(ep)
            payload: dict[str, Any] = {
                "messages": [
                    {"role": "system", "content": sys_instruction},
                    {"role": "user", "content": content_parts},
                ],
                "temperature": 0.2 if domain == "reseller" else 0.5,
                "max_tokens": 600,
                "chat_template_kwargs": {"enable_thinking": False},
                "stream": False,
            }
            if model_id:
                payload["model"] = model_id

            req = urllib.request.Request(
                f"{ep}/v1/chat/completions",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=75.0) as resp:
                if resp.status == 200:
                    res_json = json.loads(resp.read().decode("utf-8", errors="ignore"))
                    msg = res_json.get("choices", [{}])[0].get("message", {})
                    content = msg.get("content", "") or ""
                    content_clean = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
                    m = re.search(r"\{.*\}", content_clean, re.DOTALL)
                    if m:
                        parsed = json.loads(m.group(0))
                        if isinstance(parsed, dict):
                            parsed["_vision_endpoint"] = ep
                            if model_id:
                                parsed["_vision_model"] = model_id
                            return parsed
        except Exception as e:
            logger.warning("VLM probe notice on %s: %s", ep, e)

    return {}


def _detect_marketplace(url: str) -> str:
    u = (url or "").lower()
    if "poshmark.com" in u:
        return "poshmark"
    if "ebay.com" in u:
        return "ebay"
    if "mercari.com" in u:
        return "mercari"
    if "depop.com" in u:
        return "depop"
    if "grailed.com" in u:
        return "grailed"
    if "therealreal.com" in u:
        return "therealreal"
    return "web"


def _extract_price(text: str) -> float | None:
    if not text:
        return None
    for m in _PRICE_RE.finditer(text):
        try:
            val = float(m.group(1))
            if 3.0 <= val <= 5000.0:
                return val
        except ValueError:
            continue
    return None


def _sanitize_query_hint(hint: str | None, image_path_or_url: str) -> str | None:
    """Ensure filenames and file extensions do not pollute search queries."""
    if not hint:
        return None
    h = hint.strip()
    if not h:
        return None
    # Strip extensions if someone passed a filename as a hint
    base = Path(image_path_or_url).stem.lower()
    name = Path(image_path_or_url).name.lower()
    h_lower = h.lower()
    if h_lower == base or h_lower == name:
        logger.info("Discarded filename '%s' to prevent search index pollution.", hint)
        return None
    for ext in [".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tiff"]:
        if h_lower.endswith(ext):
            logger.info("Discarded file-like hint '%s' to prevent search index pollution.", hint)
            return None
    return h


def _call_local_llm_synthesis(
    forensic_notes: dict[str, Any],
    search_hits: list[dict[str, Any]],
    user_hint: str | None = None,
) -> str:
    """Execute second-stage cognitive synthesis using local LLM on port 8080."""
    endpoint = os.getenv("LLM_ENDPOINT_URL", "http://127.0.0.1:8080")
    
    # Format candidates for LLM review
    candidates_text = []
    for i, h in enumerate(search_hits[:6], 1):
        candidates_text.append(
            f"Candidate {i}:\n"
            f"  Title: {h.get('title', 'Unknown')}\n"
            f"  URL: {h.get('url', '')}\n"
            f"  Snippet: {h.get('content', '') or h.get('description', '')}\n"
        )
    candidates_block = "\n".join(candidates_text) if candidates_text else "No web candidates retrieved."

    system_prompt = (
        "You are George, senior technical craftsman and sovereign systems auditor for Blue Lodge.\n"
        "You perform second-stage cognitive synthesis over reverse visual search candidates.\n"
        "Analyze the provided visual features, user context, and search candidate snippets.\n"
        "Filter out false positives, hallucinations, and keyword-polluted noise.\n"
        "Synthesize an authoritative, grounded technical summary of what this entity is, "
        "including manufacturer/origin, architectural role, and verified reference links.\n"
        "Be concise, technical, and strictly grounded in evidence. No emojis."
    )

    user_prompt = (
        f"Context / User Hint: {user_hint or 'None provided'}\n\n"
        f"Observed Visual Forensics:\n{json.dumps(forensic_notes, indent=2)}\n\n"
        f"Search Reconnaissance Candidates:\n{candidates_block}\n\n"
        "Deliver your forensic synthesis:"
    )

    payload = {
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.7,
        "max_tokens": 450,
        "chat_template_kwargs": {"enable_thinking": False},
        "stream": False,
    }

    try:
        req = urllib.request.Request(
            f"{endpoint}/v1/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60.0) as resp:
            if resp.status == 200:
                res_json = json.loads(resp.read().decode("utf-8", errors="ignore"))
                msg = res_json.get("choices", [{}])[0].get("message", {})
                content = msg.get("content", "").strip()
                # Remove think tags if any
                clean = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
                if clean:
                    return clean
                # If content was empty due to reasoning tokens
                reasoning = msg.get("reasoning_content", "").strip()
                if reasoning:
                    return reasoning
    except Exception as e:
        logger.debug("LLM synthesis notice on %s: %s", endpoint, e)

    return ""


def reverse_image_search(
    image_input: str,
    query_hint: str | None = None,
    max_candidates: int = 15,
    min_similarity: float = 0.25,
    use_onnx: bool = False,
    extra_images: list[str] | None = None,
    domain: str = "general",
) -> dict[str, Any]:
    """Execute cognitive reverse visual identification & synthesis pipeline.

    Args:
        image_input: File path, HTTP URL, or base64 string of the primary target image.
        query_hint: Optional text hint or search context (filenames are sanitized).
        max_candidates: Maximum search results to inspect.
        min_similarity: Minimum similarity threshold (if ONNX re-ranking is enabled).
        use_onnx: Whether to invoke ONNX MobileCLIP vector re-ranking (default False).
        extra_images: Optional additional images (e.g. brand label, RN/care tag) analyzed in one call.
        domain: 'general' (default) or 'reseller' (Poshmark/eBay garment forensics + comp pricing).

    Returns:
        Structured dictionary containing forensic attributes, synthesized report, and search hits.
    """
    # 1. Parse and encode intake image(s)
    im = parse_image_input(image_input)
    if not im:
        return {"error": "Failed to decode or load intake image", "matches": []}

    all_images: list[Image.Image | str] = [im]
    for ex in (extra_images or [])[:3]:
        if ex and ex != image_input:
            ex_im = parse_image_input(ex)
            if ex_im:
                all_images.append(ex_im)

    ref_dhash = compute_image_dhash(im)
    ref_color = compute_color_profile(im)

    # 2. Sanitize hints - prevent filename pollution
    clean_hint = _sanitize_query_hint(query_hint, image_input)

    # 3. Extract visual forensics using Blue Lodge's active local multimodal VLM
    forensics: dict[str, Any] = {}
    if clean_hint:
        forensics["query_hint"] = clean_hint

    vlm_prompt = (
        f"Analyze these {len(all_images)} garment/item photo(s) for Poshmark/eBay resale valuation. "
        f"User hint: {clean_hint or 'none'}. Read every visible brand label, size tag, style code, and fabric detail carefully."
        if domain == "reseller"
        else f"Identify this object, schematic, component, device, or entity. User hint: {clean_hint or 'none'}. What is the brand, model, and category?"
    )
    vlm_res = _call_local_vlm_vision(all_images, prompt=vlm_prompt, domain=domain)
    if vlm_res:
        forensics.update(vlm_res)

    # Query formulation: derive from clean user hint or VLM findings ONLY
    queries: list[str] = []
    if domain == "reseller":
        brand = str(forensics.get("brand") or "").strip()
        style = str(forensics.get("style_name") or forensics.get("entity_name") or "").strip()
        style_code = str(forensics.get("style_code") or "").strip()
        cat = str(forensics.get("category") or forensics.get("subcategory") or "").strip()
        color = str(forensics.get("color") or "").strip()

        if brand and style_code:
            queries.append(f'"{brand}" "{style_code}" poshmark OR ebay')
        if brand and style:
            queries.append(f'site:poshmark.com "{brand}" {style}')
            queries.append(f'"{brand}" {style} sold ebay OR poshmark')
        elif brand and cat:
            queries.append(f'site:poshmark.com "{brand}" {cat} {color}'.strip())
            queries.append(f'"{brand}" {cat} {color} sold poshmark ebay'.strip())
        if clean_hint:
            queries.append(f"{clean_hint} poshmark sold")
        for q in (forensics.get("search_queries") or []):
            if q and q not in queries:
                queries.append(f"{q} poshmark")
    else:
        if clean_hint:
            queries.append(clean_hint)
        if forensics.get("search_queries"):
            for q in forensics["search_queries"]:
                if q and q not in queries:
                    queries.append(q)
        if forensics.get("entity_name"):
            brand_entity = f"{forensics.get('brand', '')} {forensics['entity_name']}".strip()
            if brand_entity and brand_entity not in queries:
                queries.append(brand_entity)

    # Deduplicate queries preserving order
    seen_q: set[str] = set()
    queries = [q.strip() for q in queries if q and q.strip() and not (q.strip().lower() in seen_q or seen_q.add(q.strip().lower()))]

    # If VLM and hint are both unavailable, do NOT use filename!
    if not queries:
        queries.append("poshmark fashion resale listing" if domain == "reseller" else "reverse image lookup technical identification")
    forensics["search_queries"] = queries

    # 4. Sovereign Reconnaissance: Search SearXNG for candidate web sources & images
    candidates: list[dict[str, Any]] = []
    seen_urls: set[str] = set()

    for q in queries[:4]:
        if not q:
            continue
        # Search web listings / documentation
        web_hits = search_searxng(q, categories="general", max_results=8)
        for h in web_hits:
            u = h.get("url")
            if u and u not in seen_urls:
                seen_urls.add(u)
                if domain == "reseller":
                    h["marketplace"] = _detect_marketplace(u)
                    h["extracted_price"] = _extract_price(f"{h.get('title', '')} {h.get('content', '') or h.get('description', '')}")
                    h["is_sold_hint"] = bool(re.search(r"\b(sold|ended)\b", f"{h.get('title', '')} {h.get('content', '')}", re.I))
                candidates.append(h)

        # Search visual images (strip site: operators for image engines)
        img_q = re.sub(r"\bsite:\S+\s*", "", q).strip()
        if img_q:
            img_hits = search_images(img_q, max_results=max(6, max_candidates // 2))
            for h in img_hits:
                src = h.get("img_src") or h.get("url")
                if src and src not in seen_urls:
                    seen_urls.add(src)
                    if domain == "reseller":
                        h["marketplace"] = _detect_marketplace(h.get("url") or src)
                        h["extracted_price"] = _extract_price(f"{h.get('title', '')} {h.get('content', '')}")
                    candidates.append(h)

        if len(candidates) >= max_candidates * 2:
            break

    # Prioritize marketplace hits in reseller mode
    if domain == "reseller":
        def _reseller_rank(c: dict[str, Any]) -> tuple[int, int, int]:
            mp = c.get("marketplace", "web")
            mp_score = 3 if mp == "poshmark" else (2 if mp in ("ebay", "mercari", "depop") else 1)
            has_price = 1 if c.get("extracted_price") else 0
            sold_bonus = 1 if c.get("is_sold_hint") else 0
            return (mp_score, has_price, sold_bonus)
        candidates.sort(key=_reseller_rank, reverse=True)
        candidates = candidates[:max_candidates]

    # 5. Optional ONNX vector re-ranking (strictly opt-in)
    ranked_matches = candidates
    if use_onnx:
        embedder = get_vision_embedder()
        if embedder.is_onnx_ready:
            ranked_matches = embedder.rerank_candidates(
                intake_image=im,
                candidates=candidates,
                image_key="img_src",
                min_similarity=min_similarity,
            )

    # 6. Second-Stage Cognitive Synthesis (skipped in reseller mode when caller is George's own ReAct loop, or run if general)
    synthesis = ""
    if domain != "reseller":
        synthesis = _call_local_llm_synthesis(
            forensic_notes=forensics,
            search_hits=ranked_matches,
            user_hint=clean_hint,
        )

    out: dict[str, Any] = {
        "status": "success",
        "domain": domain,
        "intake": {
            "dhash": hex(ref_dhash),
            "images_analyzed": len(all_images),
            "chromatic_ratio": round(ref_color.chromatic_ratio, 3) if ref_color else None,
            "engine": f"prism_vlm_{domain}" + ("_with_onnx" if use_onnx else ""),
        },
        "forensics": forensics,
        "synthesis": synthesis,
        "total_candidates_scanned": len(candidates),
        "total_matches_verified": len(ranked_matches),
        "top_match": ranked_matches[0] if ranked_matches else None,
        "matches": ranked_matches,
    }

    if domain == "reseller":
        prices = [float(c["extracted_price"]) for c in ranked_matches if c.get("extracted_price")]
        out["price_summary"] = {
            "priced_comp_count": len(prices),
            "min": round(min(prices), 2) if prices else None,
            "median": round(statistics.median(prices), 2) if prices else None,
            "max": round(max(prices), 2) if prices else None,
        }

    return out


def main():
    parser = argparse.ArgumentParser(description="Blue Lodge Sovereign Reverse Image Search & Visual Identification Engine")
    parser.add_argument("image", help="Path to primary local image file or HTTP image URL")
    parser.add_argument("--images", nargs="*", default=[], help="Optional extra image paths (e.g. brand tag, care/RN label)")
    parser.add_argument("--domain", "-d", default="general", choices=["general", "reseller"], help="Forensic extraction domain")
    parser.add_argument("--hint", "-H", default=None, help="Optional text hint or brand/product guidance")
    parser.add_argument("--max-candidates", "-m", type=int, default=15, help="Maximum candidate images to scan")
    parser.add_argument("--min-sim", "-s", type=float, default=0.25, help="Minimum visual similarity threshold (0.0 - 1.0)")
    parser.add_argument("--with-onnx", action="store_true", help="Enable optional MobileCLIP ONNX vector re-ranking")
    parser.add_argument("--format", "-f", default="markdown", choices=["text", "json", "markdown"])

    args = parser.parse_args()

    res = reverse_image_search(
        image_input=args.image,
        query_hint=args.hint,
        max_candidates=args.max_candidates,
        min_similarity=args.min_sim,
        use_onnx=args.with_onnx,
        extra_images=args.images,
        domain=args.domain,
    )

    if args.format == "json":
        print(json.dumps(res, indent=2))
        return

    forensics = res.get("forensics", {})
    synthesis = res.get("synthesis", "")
    matches = res.get("matches", [])

    if args.format == "markdown":
        print("# Sovereign Visual Identification Report\n")
        print(f"**Target Image**: `{args.image}`")
        print(f"**Pipeline**: {res.get('intake', {}).get('engine')} (dHash: `{res.get('intake', {}).get('dhash')}`)\n")

        if synthesis:
            print("## Cognitive Forensic Synthesis")
            print(synthesis)
            print()

        if forensics:
            print("## Observed Attributes")
            if forensics.get("brand"):
                print(f"- **Brand/Maker**: {forensics.get('brand')}")
            if forensics.get("entity_name"):
                print(f"- **Entity Name**: {forensics.get('entity_name')}")
            if forensics.get("archetype"):
                print(f"- **Category/Archetype**: {forensics.get('archetype')}")
            if forensics.get("colorway"):
                print(f"- **Colorway**: {forensics.get('colorway')}")
            if forensics.get("search_queries"):
                print(f"- **Grounded Queries**: `{', '.join(forensics.get('search_queries'))}`")
            print()

        if matches:
            print(f"## Reconnaissance Citations ({len(matches)} inspected from {res.get('total_candidates_scanned')} candidates)\n")
            for i, m in enumerate(matches[:6], 1):
                sim_str = ""
                if "similarity" in m:
                    sim_pct = m.get("match_percentage", int(round(m.get("similarity", 0.0) * 100)))
                    sim_str = f"[{sim_pct}% Match] "
                print(f"### {i}. {sim_str}{m.get('title', 'Candidate Source')}")
                print(f"- **Source URL**: [{m.get('url')}]({m.get('url')})")
                if m.get("img_src"):
                    print(f"- **Visual Asset**: [Image Link]({m.get('img_src')})")
                if m.get("content"):
                    print(f"- **Snippet**: {m.get('content')}")
                print()
    else:
        # Clean text
        print("=== Sovereign Visual Identification ===")
        print(f"Target: {args.image}")
        print(f"Engine: {res.get('intake', {}).get('engine')}")
        if synthesis:
            print(f"\nSynthesis:\n{synthesis}\n")
        print(f"Candidates Retrieved: {len(matches)}")
        for i, m in enumerate(matches[:5], 1):
            print(f"[{i}] {m.get('title')}")
            print(f"    Source: {m.get('url')}")
            print()


if __name__ == "__main__":
    main()
