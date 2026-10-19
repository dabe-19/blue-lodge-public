"""Sovereign, Fully Local Reverse Image Search & Visual Identification Engine for Blue Lodge.

Combines:
1. Local Vision Feature Extraction (VLM / Heuristics)
2. Two-Stage Visual Reconnaissance via SearXNG Metasearch (Google, Bing, DDG, eBay)
3. Deterministic Sub-Second Visual Feature Embedding & Re-Ranking (MobileCLIP-S0 / DINOv2 / dHash)
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import re
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

_LODGE_ROOT = Path(__file__).resolve().parents[2]


def _call_local_vlm_vision(image_input: Image.Image | str, prompt: str) -> dict[str, Any]:
    """Call local llama-server multimodal vision endpoint if active on port 8080 or port 18080."""
    endpoints = [
        os.getenv("VISION_ENDPOINT_URL", "http://127.0.0.1:8080"),
        "http://127.0.0.1:18080",
    ]

    im = parse_image_input(image_input)
    if not im:
        return {}

    # Downsample image for VLM
    im_rgb = im.convert("RGB")
    im_rgb.thumbnail((768, 768), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    im_rgb.save(buf, format="JPEG", quality=85)
    b64_data = base64.b64encode(buf.getvalue()).decode("utf-8")
    data_uri = f"data:image/jpeg;base64,{b64_data}"

    sys_instruction = (
        "You are an elite visual forensics and product identification expert. "
        "Analyze the image and extract: brand/manufacturer, exact product or entity name, "
        "archetype/category, colorway, visible text or serial numbers, and 3 targeted web search queries "
        "to locate matching product listings.\n"
        "Output strictly valid JSON with keys: brand, entity_name, archetype, colorway, visible_text, search_queries."
    )

    payload = {
        "messages": [
            {"role": "system", "content": sys_instruction},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": data_uri}},
                ],
            },
        ],
        "temperature": 0.7,
        "max_tokens": 400,
        "chat_template_kwargs": {"enable_thinking": False},
        "stream": False,
    }

    for ep in endpoints:
        try:
            req = urllib.request.Request(
                f"{ep}/v1/chat/completions",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=12.0) as resp:
                if resp.status == 200:
                    res_json = json.loads(resp.read().decode("utf-8", errors="ignore"))
                    content = res_json.get("choices", [{}])[0].get("message", {}).get("content", "")
                    content_clean = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
                    m = re.search(r"\{.*\}", content_clean, re.DOTALL)
                    if m:
                        return json.loads(m.group(0))
        except Exception as e:
            logger.debug("VLM probe notice on %s: %s", ep, e)

    return {}


import io


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
) -> dict[str, Any]:
    """Execute cognitive reverse visual identification & synthesis pipeline.

    Args:
        image_input: File path, HTTP URL, or base64 string of the target image.
        query_hint: Optional text hint or search context (filenames are sanitized).
        max_candidates: Maximum search results to inspect.
        min_similarity: Minimum similarity threshold (if ONNX re-ranking is enabled).
        use_onnx: Whether to invoke ONNX MobileCLIP vector re-ranking (default False).

    Returns:
        Structured dictionary containing forensic attributes, synthesized report, and search hits.
    """
    # 1. Parse and encode intake image
    im = parse_image_input(image_input)
    if not im:
        return {"error": "Failed to decode or load intake image", "matches": []}

    ref_dhash = compute_image_dhash(im)
    ref_color = compute_color_profile(im)

    # 2. Sanitize hints - prevent filename pollution
    clean_hint = _sanitize_query_hint(query_hint, image_input)

    # 3. Extract visual forensics
    forensics: dict[str, Any] = {}
    if clean_hint:
        forensics["query_hint"] = clean_hint

    # Attempt VLM forensic extraction from image pixels
    vlm_res = _call_local_vlm_vision(
        im,
        prompt="Identify this object, schematic, component, device, or entity. What is the brand, model, and category?"
    )
    if vlm_res:
        forensics.update(vlm_res)

    # Query formulation: derive from clean user hint or VLM findings ONLY
    queries: list[str] = []
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

    # If VLM and hint are both unavailable, do NOT use filename!
    if not queries:
        queries.append("reverse image lookup technical identification")
    forensics["search_queries"] = queries

    # 4. Sovereign Reconnaissance: Search SearXNG for candidate web sources & images
    candidates: list[dict[str, Any]] = []
    seen_urls: set[str] = set()

    for q in queries:
        if not q:
            continue
        # Search web listings / documentation
        web_hits = search_searxng(q, categories="general", max_results=8)
        for h in web_hits:
            u = h.get("url")
            if u and u not in seen_urls:
                seen_urls.add(u)
                candidates.append(h)

        # Search visual images
        img_hits = search_images(q, max_results=max_candidates)
        for h in img_hits:
            src = h.get("img_src") or h.get("url")
            if src and src not in seen_urls:
                seen_urls.add(src)
                candidates.append(h)

        if len(candidates) >= max_candidates:
            break

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

    # 6. Second-Stage Cognitive Synthesis: Local LLM analyzes evidence
    synthesis = _call_local_llm_synthesis(
        forensic_notes=forensics,
        search_hits=ranked_matches,
        user_hint=clean_hint,
    )

    return {
        "status": "success",
        "intake": {
            "dhash": hex(ref_dhash),
            "chromatic_ratio": round(ref_color.chromatic_ratio, 3) if ref_color else None,
            "engine": "vlm_cognitive_synthesis" + ("_with_onnx" if use_onnx else ""),
        },
        "forensics": forensics,
        "synthesis": synthesis,
        "total_candidates_scanned": len(candidates),
        "total_matches_verified": len(ranked_matches),
        "top_match": ranked_matches[0] if ranked_matches else None,
        "matches": ranked_matches,
    }


def main():
    parser = argparse.ArgumentParser(description="Blue Lodge Sovereign Reverse Image Search & Visual Identification Engine")
    parser.add_argument("image", help="Path to local image file or HTTP image URL")
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
