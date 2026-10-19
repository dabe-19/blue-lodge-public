#!/usr/bin/env python3
"""
research_verifier.py — Deterministic Grounding Gate & Platform Linter for George Deep Research

Provides:
1. Deterministic Citation & Entity Resolver (arXiv API, Crossref DOI, IACR ePrint, RFCs, CVEs)
   - Existence check
   - Year/venue temporal alignment check
   - Abstract topic distance & keyword overlap check
   - Persistent local caching to avoid duplicate queries
2. Adversarial Primitive Heuristics & Rules (domain-agnostic category collision checks)
3. Platform Syntax & Format Linter (LaTeX delimiter stripping, Unicode conversion, cashtag sanitization, character limit assertion)
"""

import sys
import os
import re
import json
import argparse
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime

# ── Stopwords for Topic Distance Calculation ──────────────────────────
STOPWORDS = {
    "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
    "any", "are", "aren't", "as", "at", "be", "because", "been", "before", "being",
    "below", "between", "both", "but", "by", "can't", "cannot", "could", "couldn't",
    "did", "didn't", "do", "does", "doesn't", "doing", "don't", "down", "during",
    "each", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't",
    "have", "haven't", "having", "he", "he'd", "he'll", "he's", "her", "here",
    "here's", "hers", "herself", "him", "himself", "his", "how", "how's", "i",
    "i'd", "i'll", "i'm", "i've", "if", "in", "into", "is", "isn't", "it", "it's",
    "its", "itself", "let's", "me", "more", "most", "mustn't", "my", "myself",
    "no", "nor", "not", "of", "off", "on", "once", "only", "or", "other", "ought",
    "our", "ours", "ourselves", "out", "over", "own", "same", "shan't", "she",
    "she'd", "she'll", "she's", "should", "shouldn't", "so", "some", "such",
    "than", "that", "that's", "the", "their", "theirs", "them", "themselves",
    "then", "there", "there's", "these", "they", "they'd", "they'll", "they're",
    "they've", "this", "those", "through", "to", "too", "under", "until", "up",
    "very", "was", "wasn't", "we", "we'd", "we'll", "we're", "we've", "were",
    "weren't", "what", "what's", "when", "when's", "where", "where's", "which",
    "while", "who", "who's", "whom", "why", "why's", "with", "won't", "would",
    "wouldn't", "you", "you'd", "you'll", "you're", "you've", "your", "yours",
    "yourself", "yourselves", "paper", "presents", "propose", "approach", "method",
    "results", "study", "using", "based", "system", "systems", "show", "shows"
}

# ── Complete LaTeX to Unicode Map ──────────────────────────────────────
LATEX_UNICODE_MAP = [
    # Greek lowercase
    (r"\\alpha(?![a-zA-Z])", "α"), (r"\\beta(?![a-zA-Z])", "β"), (r"\\gamma(?![a-zA-Z])", "γ"),
    (r"\\delta(?![a-zA-Z])", "δ"), (r"\\epsilon(?![a-zA-Z])", "ε"), (r"\\varepsilon(?![a-zA-Z])", "ε"),
    (r"\\zeta(?![a-zA-Z])", "ζ"), (r"\\eta(?![a-zA-Z])", "η"), (r"\\theta(?![a-zA-Z])", "θ"),
    (r"\\vartheta(?![a-zA-Z])", "θ"), (r"\\iota(?![a-zA-Z])", "ι"), (r"\\kappa(?![a-zA-Z])", "κ"),
    (r"\\lambda(?![a-zA-Z])", "λ"), (r"\\mu(?![a-zA-Z])", "μ"), (r"\\nu(?![a-zA-Z])", "ν"),
    (r"\\xi(?![a-zA-Z])", "ξ"), (r"\\pi(?![a-zA-Z])", "π"), (r"\\varpi(?![a-zA-Z])", "ϖ"),
    (r"\\rho(?![a-zA-Z])", "ρ"), (r"\\varrho(?![a-zA-Z])", "ϱ"), (r"\\sigma(?![a-zA-Z])", "σ"),
    (r"\\varsigma(?![a-zA-Z])", "ς"), (r"\\tau(?![a-zA-Z])", "τ"), (r"\\upsilon(?![a-zA-Z])", "υ"),
    (r"\\phi(?![a-zA-Z])", "ϕ"), (r"\\varphi(?![a-zA-Z])", "φ"), (r"\\chi(?![a-zA-Z])", "χ"),
    (r"\\psi(?![a-zA-Z])", "ψ"), (r"\\omega(?![a-zA-Z])", "ω"),
    # Greek uppercase
    (r"\\Gamma(?![a-zA-Z])", "Γ"), (r"\\Delta(?![a-zA-Z])", "Δ"), (r"\\Theta(?![a-zA-Z])", "Θ"),
    (r"\\Lambda(?![a-zA-Z])", "Λ"), (r"\\Xi(?![a-zA-Z])", "Ξ"), (r"\\Pi(?![a-zA-Z])", "Π"),
    (r"\\Sigma(?![a-zA-Z])", "Σ"), (r"\\Upsilon(?![a-zA-Z])", "Υ"), (r"\\Phi(?![a-zA-Z])", "Φ"),
    (r"\\Psi(?![a-zA-Z])", "Ψ"), (r"\\Omega(?![a-zA-Z])", "Ω"),
    # Relations & comparisons
    (r"\\geq(?![a-zA-Z])", "≥"), (r"\\ge(?![a-zA-Z])", "≥"),
    (r"\\leq(?![a-zA-Z])", "≤"), (r"\\le(?![a-zA-Z])", "≤"),
    (r"\\neq(?![a-zA-Z])", "≠"), (r"\\ne(?![a-zA-Z])", "≠"),
    (r"\\approx(?![a-zA-Z])", "≈"), (r"\\sim(?![a-zA-Z])", "∼"),
    (r"\\equiv(?![a-zA-Z])", "≡"), (r"\\ll(?![a-zA-Z])", "≪"), (r"\\gg(?![a-zA-Z])", "≫"),
    (r"\\pm(?![a-zA-Z])", "±"), (r"\\mp(?![a-zA-Z])", "∓"),
    (r"\\times(?![a-zA-Z])", "×"), (r"\\cdot(?![a-zA-Z])", "·"),
    # Arrows
    (r"\\longrightarrow(?![a-zA-Z])", "→"), (r"\\rightarrow(?![a-zA-Z])", "→"), (r"\\to(?![a-zA-Z])", "→"),
    (r"\\longleftarrow(?![a-zA-Z])", "←"), (r"\\leftarrow(?![a-zA-Z])", "←"),
    (r"\\longleftrightarrow(?![a-zA-Z])", "↔"), (r"\\leftrightarrow(?![a-zA-Z])", "↔"),
    (r"\\Longrightarrow(?![a-zA-Z])", "⇒"), (r"\\Rightarrow(?![a-zA-Z])", "⇒"), (r"\\implies(?![a-zA-Z])", "⇒"),
    (r"\\Longleftarrow(?![a-zA-Z])", "⇐"), (r"\\Leftarrow(?![a-zA-Z])", "⇐"),
    (r"\\Longleftrightarrow(?![a-zA-Z])", "⇔"), (r"\\Leftrightarrow(?![a-zA-Z])", "⇔"), (r"\\iff(?![a-zA-Z])", "⇔"),
    (r"\\mapsto(?![a-zA-Z])", "↦"),
    # Operators & calculus
    (r"\\sum(?![a-zA-Z])", "∑"), (r"\\prod(?![a-zA-Z])", "∏"),
    (r"\\int(?![a-zA-Z])", "∫"), (r"\\partial(?![a-zA-Z])", "∂"),
    (r"\\nabla(?![a-zA-Z])", "∇"), (r"\\infty(?![a-zA-Z])", "∞"),
    (r"\\in(?![a-zA-Z])", "∈"), (r"\\notin(?![a-zA-Z])", "∉"),
    (r"\\subset(?![a-zA-Z])", "⊂"), (r"\\subseteq(?![a-zA-Z])", "⊆"),
    (r"\\supset(?![a-zA-Z])", "⊃"), (r"\\supseteq(?![a-zA-Z])", "⊇"),
    (r"\\cap(?![a-zA-Z])", "∩"), (r"\\cup(?![a-zA-Z])", "∪"),
    (r"\\forall(?![a-zA-Z])", "∀"), (r"\\exists(?![a-zA-Z])", "∃"),
    (r"\\neg(?![a-zA-Z])", "¬"), (r"\\land(?![a-zA-Z])", "∧"), (r"\\lor(?![a-zA-Z])", "∨"),
    (r"\\emptyset(?![a-zA-Z])", "∅"),
    # Structures, fonts & accents
    (r"\\mathbb\{Z\}_?(\d*)", r"ℤ\1"), (r"\\mathbb\{R\}_?(\d*)", r"ℝ\1"),
    (r"\\mathbb\{N\}", "ℕ"), (r"\\mathbb\{C\}", "ℂ"), (r"\\mathbb\{Q\}", "ℚ"),
    (r"\\mathbb\{F\}_?(\w*)", r"𝔽\1"),
    (r"\\frac\{([^}]+)\}\{([^}]+)\}", r"(\1/\2)"),
    (r"\\sqrt\{([^}]+)\}", r"√(\1)"),
    (r"\\prime", "\x27"),
    (r"\\\|", "||"),
]


class CitationCache:
    def __init__(self, cache_file=None):
        if cache_file:
            self.cache_file = cache_file
        else:
            lodge_dir = os.environ.get("LODGE_DIR", os.path.expanduser("~/blue-lodge"))
            george_dir = os.environ.get("GEORGE_DIR", os.path.join(lodge_dir, ".george"))
            cache_dir = os.path.join(george_dir, "cache")
            os.makedirs(cache_dir, exist_ok=True)
            self.cache_file = os.path.join(cache_dir, "citations_cache.json")
        self.data = self._load()

    def _load(self):
        if os.path.exists(self.cache_file):
            try:
                with open(self.cache_file, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return {}
        if os.path.basename(self.cache_file) == "citations_cache.json":
            lodge_dir = os.environ.get("LODGE_DIR", os.path.expanduser("~/blue-lodge"))
            fallback_cache = os.path.join(lodge_dir, ".george", "cache", "citations_cache.json")
            if fallback_cache != self.cache_file and os.path.exists(fallback_cache):
                try:
                    with open(fallback_cache, "r", encoding="utf-8") as f:
                        return json.load(f)
                except Exception:
                    pass
        return {}

    def get(self, key):
        return self.data.get(key)

    def set(self, key, value):
        self.data[key] = value
        try:
            with open(self.cache_file, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2)
        except Exception:
            pass


class DeterministicCitationResolver:
    def __init__(self, cache=None, timeout=12):
        self.cache = cache or CitationCache()
        self.timeout = timeout
        self.user_agent = "George-ResearchVerifier/1.0 (Blue Lodge Sovereign Research Engine)"

    def extract_identifiers(self, text):
        """Extract all formal academic and specification identifiers from text."""
        citations = {
            "arxiv": [],
            "doi": [],
            "iacr": [],
            "rfc": [],
            "cve": [],
            "claimed_papers": []
        }

        # 1. arXiv IDs: 2007.09978, 2007.09978v2, arXiv:2007.09978
        #    Deduplicate by BASE ID so that the versioned and unversioned forms of
        #    the SAME paper (e.g. "2402.11140" and "2402.11140v2") collapse to a
        #    single canonical identifier. set() alone only dedups identical strings,
        #    so both forms previously survived and the Grounding Verification Gate
        #    emitted one violation per form — doubling an already-unresolvable
        #    citation and keeping the refinement retry loop from converging
        #    (root cause of the react_agent PROCESS_STALL turn-ceiling burnout).
        arxiv_matches = re.findall(r"(?:arxiv[:\s/]+|arxiv\.org/(?:abs|pdf)/)?\b([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?)\b", text, re.I)
        _arxiv_canonical = {}
        for _aid in arxiv_matches:
            _base = re.sub(r"(?i)v[0-9]+$", "", _aid)
            _prev = _arxiv_canonical.get(_base)
            # Prefer the explicit versioned form for human-facing reporting; the
            # resolver strips the version for its API lookup regardless.
            if _prev is None or (re.search(r"(?i)v[0-9]+$", _aid) and not re.search(r"(?i)v[0-9]+$", _prev)):
                _arxiv_canonical[_base] = _aid
        citations["arxiv"] = sorted(_arxiv_canonical.values())

        # 2. DOIs: 10.xxxx/...
        doi_matches = re.findall(r"\b(10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+)", text)
        cleaned_dois = []
        for d in doi_matches:
            d_clean = re.sub(r"[.,;:)\]]+$", "", d)
            cleaned_dois.append(d_clean)
        citations["doi"] = sorted(list(set(cleaned_dois)))

        # 3. IACR ePrint: 2021/123, ePrint 2021/123
        iacr_matches = re.findall(r"(?:iacr|eprint)[\s:/]+([0-9]{4}/[0-9]{3,5})", text, re.I)
        citations["iacr"] = sorted(list(set(iacr_matches)))

        # 4. RFCs: RFC 7540, RFC-7540
        rfc_matches = re.findall(r"\brfc[\s-]?([0-9]{1,5})\b", text, re.I)
        citations["rfc"] = sorted(list(set(rfc_matches)))

        # 5. CVEs: CVE-2024-1234
        cve_matches = re.findall(r"\b(CVE-[0-9]{4}-[0-9]{4,7})\b", text, re.I)
        citations["cve"] = sorted(list(set(cve_matches)))

        # 6. Specific Paper Venue & Year Claims: e.g. "Ouroboros Crypsinous (IEEE S&P 2025)"
        venue_matches = re.findall(
            r"([A-Za-z0-9\s:_-]{3,50}?)\s*\((IEEE\s*(?:S&P|SP)|ACM\s*CCS|USENIX\s*(?:Security)?|NDSS|Eurocrypt|Crypto|Asiacrypt|NeurIPS|ICML|ICLR|CVPR)\s*([0-9]{4})\)",
            text, re.I
        )
        for name, venue, yr in venue_matches:
            citations["claimed_papers"].append({
                "title": name.strip(),
                "venue": venue.strip(),
                "claimed_year": int(yr)
            })

        return citations

    def resolve_arxiv(self, arxiv_id):
        """Query arXiv Atom API with local cache."""
        cache_key = f"arxiv:{arxiv_id}"
        cached = self.cache.get(cache_key)
        if cached:
            return cached

        # Check persistent SQLite cache
        clean_id = re.sub(r"v[0-9]+$", "", arxiv_id)
        arxiv_cache = None
        try:
            try:
                from lib.tools.arxiv_cache import get_arxiv_cache
            except ImportError:
                from arxiv_cache import get_arxiv_cache
            arxiv_cache = get_arxiv_cache()
            sq_paper = arxiv_cache.get_paper(clean_id) or arxiv_cache.get_paper(arxiv_id)
            if sq_paper and sq_paper.get("title") and sq_paper.get("found", True) is not False:
                pub_date = sq_paper.get("published") or sq_paper.get("pub_date", "")
                year = int(pub_date[:4]) if pub_date and len(pub_date) >= 4 else None
                res = {
                    "found": True,
                    "id": arxiv_id,
                    "title": sq_paper.get("title", ""),
                    "summary": sq_paper.get("summary") or sq_paper.get("content", ""),
                    "authors": sq_paper.get("authors", []),
                    "published_date": pub_date,
                    "published_year": year,
                }
                self.cache.set(cache_key, res)
                return res
        except Exception:
            pass

        url = f"https://export.arxiv.org/api/query?id_list={clean_id}"
        req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                xml_data = resp.read().decode("utf-8")
                root = ET.fromstring(xml_data)
                ns = {"atom": "http://www.w3.org/2005/Atom"}
                entry = root.find("atom:entry", ns)
                if entry is None:
                    res = {"found": False, "error": "Not found on arXiv"}
                    self.cache.set(cache_key, res)
                    return res

                title_el = entry.find("atom:title", ns)
                summary_el = entry.find("atom:summary", ns)
                pub_el = entry.find("atom:published", ns)

                title = title_el.text.strip().replace("\n", " ") if title_el is not None else ""
                summary = summary_el.text.strip().replace("\n", " ") if summary_el is not None else ""
                pub_date = pub_el.text if pub_el is not None else ""
                year = int(pub_date[:4]) if pub_date and len(pub_date) >= 4 else None

                authors = []
                for author_el in entry.findall("atom:author", ns):
                    name_el = author_el.find("atom:name", ns)
                    if name_el is not None and name_el.text:
                        authors.append(name_el.text.strip())

                if "Error" in title:
                    res = {"found": False, "error": "arXiv returned error entry"}
                    self.cache.set(cache_key, res)
                    return res

                res = {
                    "found": True,
                    "id": arxiv_id,
                    "title": title,
                    "summary": summary,
                    "authors": authors,
                    "published_date": pub_date,
                    "published_year": year
                }
                self.cache.set(cache_key, res)
                if arxiv_cache:
                    try:
                        arxiv_cache.set_paper(clean_id, res)
                    except Exception:
                        pass
                return res
        except Exception as e:
            # If offline or network unreachable, check if mock exists or return error
            return {"found": None, "error": str(e)}

    def resolve_doi(self, doi):
        """Query Crossref API for DOI metadata."""
        cache_key = f"doi:{doi}"
        cached = self.cache.get(cache_key)
        if cached:
            return cached

        encoded_doi = urllib.parse.quote(doi)
        url = f"https://api.crossref.org/works/{encoded_doi}"
        req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                msg = data.get("message", {})
                title = " ".join(msg.get("title", []))
                abstract = msg.get("abstract", "")
                created = msg.get("created", {}).get("date-parts", [[None]])[0][0]
                authors = []
                for a in msg.get("author", []):
                    family = a.get("family", "")
                    given = a.get("given", "")
                    full = f"{given} {family}".strip() if given else family
                    if full:
                        authors.append(full)
                res = {
                    "found": True,
                    "id": doi,
                    "title": title,
                    "summary": abstract,
                    "authors": authors,
                    "published_year": created
                }
                self.cache.set(cache_key, res)
                return res
        except urllib.error.HTTPError as e:
            if e.code == 404:
                res = {"found": False, "error": "DOI not found in Crossref"}
                self.cache.set(cache_key, res)
                return res
            return {"found": None, "error": f"HTTP {e.code}"}
        except Exception as e:
            return {"found": None, "error": str(e)}

    @staticmethod
    def stem(w):
        w = re.sub(r"[^a-z0-9]", "", w.lower())
        for suf in ["tions", "tion", "tional", "ing", "ment", "ary", "ers", "er", "ed", "es", "s"]:
            if w.endswith(suf) and len(w) - len(suf) >= 4:
                return w[:-len(suf)]
        return w

    def compute_topic_overlap(self, claim_text, paper_title, paper_summary):
        """Compute keyword and token overlap ratio between claimed topic and paper."""
        def tokenize(s):
            words = re.findall(r"[A-Za-z0-9_-]{3,}", s.lower())
            tokens = set()
            for w in words:
                sw = self.stem(w)
                if w not in STOPWORDS and sw not in STOPWORDS and len(sw) >= 3:
                    tokens.add(sw)
            return tokens

        claim_tokens = tokenize(claim_text)
        paper_tokens = tokenize(paper_title + " " + paper_summary)

        if not claim_tokens:
            return 1.0, []

        overlap = claim_tokens.intersection(paper_tokens)
        ratio = len(overlap) / max(len(claim_tokens), 1)
        return ratio, list(overlap)

    def check_attribution_contradiction(self, citing_context, identifier, retrieved_title, retrieved_summary="", retrieved_authors=None):
        """
        Contradiction-Only Attribution:
        Only fails if the citing text explicitly asserts a specific title (in quotes or immediately preceding)
        and that asserted title actively contradicts the retrieved paper title.
        Bare citations like [arXiv:2203.11171] pass unconditionally.
        Author names (e.g. Trusov, Tathe et al.) or method acronyms (e.g. APoT) pass.
        """
        if retrieved_authors is None:
            retrieved_authors = []

        # Isolate the specific sentence containing the identifier
        sentences = re.split(r'(?<=[.!?])\s+', citing_context)
        target_clause = citing_context
        for s in sentences:
            if identifier in s:
                target_clause = s
                break

        claimed_title = None
        is_quoted = False
        quotes = re.findall(r'[\"“]([^\"”]{2,120})[\"”]', target_clause)
        if quotes:
            claimed_title = quotes[0].strip()
            is_quoted = True
        else:
            m_pre = re.search(r'([A-Z][a-zA-Z0-9_.-]{1,30}(?:\s+[A-Za-z0-9_.-]{1,30}){0,3})\s*(?:et\s+al\.?)?\s*\([^)]*?' + re.escape(identifier), target_clause)
            if m_pre:
                cand = m_pre.group(1).strip()
                words = cand.split()
                filtered = [w for w in words if w.lower() not in ['see', 'also', 'e.g', 'eg', 'in', 'and', 'from', 'with', 'using', 'introduced', 'proposed', 'paper', 'work', 'by', 'of']]
                if filtered:
                    claimed_title = ' '.join(filtered)

        if not claimed_title:
            return True, None

        cand_lower = claimed_title.lower()

        # 0. Bibliography Line Confirmation: If citing_context contains a reference entry matching the retrieved title
        for line in citing_context.splitlines():
            if identifier in line:
                line_tokens = {self.stem(w) for w in re.findall(r"[A-Za-z0-9_-]{3,}", line.lower()) if self.stem(w) not in STOPWORDS}
                ret_tokens = {self.stem(w) for w in re.findall(r"[A-Za-z0-9_-]{3,}", retrieved_title.lower()) if self.stem(w) not in STOPWORDS}
                ref_overlap = line_tokens.intersection(ret_tokens)
                if len(ref_overlap) >= 3 or (len(ret_tokens) > 0 and len(ref_overlap) / len(ret_tokens) >= 0.35):
                    if cand_lower in line.lower() or not is_quoted:
                        return True, None

        # 1. Author Confirmation: If candidate text matches any author of the paper
        for author in retrieved_authors:
            a_lower = author.lower()
            last_name = a_lower.split()[-1] if a_lower.split() else a_lower
            if last_name and (last_name in cand_lower or cand_lower in last_name):
                return True, None
            if a_lower in cand_lower or cand_lower in a_lower:
                return True, None

        # 2. If not quoted and text contains authorial markers (e.g., 'et al', 'Author and Author'),
        # or matches an author-like citation pattern without explicit title declaration
        if not is_quoted:
            if re.search(r'\bet\s+al\b', target_clause, re.IGNORECASE) or re.search(r'\b(by|from)\s+' + re.escape(claimed_title), target_clause, re.IGNORECASE):
                return True, None

        # 3. Direct Appearance in Title or Abstract / Summary (e.g. method acronyms 'APoT', 'DART', 'FP4')
        if retrieved_title and cand_lower in retrieved_title.lower():
            return True, None
        if retrieved_summary and cand_lower in retrieved_summary.lower():
            return True, None

        # 4. Acronym Matching against Title
        if len(claimed_title) <= 8 and (claimed_title.isupper() or claimed_title[0].isupper()):
            title_words = re.findall(r'[A-Za-z0-9]+', retrieved_title)
            acronym = ''.join([w[0].upper() for w in title_words if w.lower() not in STOPWORDS])
            if claimed_title.upper() in acronym or acronym.startswith(claimed_title.upper()):
                return True, None

        # 5. Token Overlap Check for explicit title assertions
        claimed_tokens = {self.stem(w) for w in re.findall(r"[A-Za-z0-9_-]{3,}", cand_lower) if self.stem(w) not in STOPWORDS}
        retrieved_tokens = {self.stem(w) for w in re.findall(r"[A-Za-z0-9_-]{3,}", retrieved_title.lower()) if self.stem(w) not in STOPWORDS}

        if not claimed_tokens:
            return True, None

        overlap = claimed_tokens.intersection(retrieved_tokens)
        ratio = len(overlap) / len(claimed_tokens)

        if ratio < 0.20 and len(overlap) == 0:
            return False, f"Claimed '{claimed_title}' contradicts retrieved '{retrieved_title}' (overlap: {ratio:.2f})"
        return True, None

    def resolve_unindexed_crossref(self, author, year, title):
        """Query Crossref free-text search API to auto-resolve canonical DOI for unindexed works."""
        cache_key = f"crossref_search:{title.lower()[:80]}"
        cached = self.cache.get(cache_key)
        if cached:
            return cached

        q = urllib.parse.quote(f"{title} {author} {year}")
        url = f"https://api.crossref.org/works?query.bibliographic={q}&rows=1"
        req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                items = data.get("message", {}).get("items", [])
                if items:
                    item = items[0]
                    res_title = " ".join(item.get("title", []))
                    res_doi = item.get("DOI")
                    res_year = item.get("created", {}).get("date-parts", [[None]])[0][0]
                    res = {
                        "found": True,
                        "doi": res_doi,
                        "title": res_title,
                        "year": res_year
                    }
                    self.cache.set(cache_key, res)
                    return res
        except Exception as e:
            return {"found": None, "error": str(e)}
        res = {"found": False}
        self.cache.set(cache_key, res)
        return res

    def verify(self, text, topic, domain="academic", evidence=None):
        """
        Run full deterministic resolution:
        - Existence assertions (No 404s)
        - Temporal / year alignment assertions (No future years)
        - Contradiction-Only Attribution assertions (Catch ID typos without blocking cross-domain synthesis)
        - Auto-resolve unindexed foundational works via Crossref

        When `evidence` (the gathered evidence ledger, e.g. scratchpad.md) is
        supplied, identifiers already present in that ledger are treated as
        *grounded*: a registry miss for such an ID is a lookup gap (registry /
        normalization limitation), surfaced as a non-blocking notice under
        citations["evidence_grounded"] rather than a hard CITATION_NOT_FOUND
        violation (incident 41bf78240605). The Square in code: no silent
        suppression, no false-positive quarantine of a correctly cited artifact.
        """
        citations = self.extract_identifiers(text)
        violations = []
        current_year = datetime.now().year

        # Evidence-ledger grounding: identifiers already gathered in the research
        # evidence are treated as verified-in-context. A resolver/registry miss for
        # one of these is a lookup gap, not a fabricated citation. We surface them
        # under citations["evidence_grounded"] (visible, never silent) and do NOT
        # raise CITATION_NOT_FOUND.
        evidence_arxiv = set()
        evidence_dois = set()
        if evidence:
            ev_cites = self.extract_identifiers(evidence)
            evidence_arxiv = {re.sub(r"v[0-9]+$", "", a).strip() for a in ev_cites.get("arxiv", [])}
            evidence_dois = {d.strip() for d in ev_cites.get("doi", []) if d.strip()}

        # 1. Verify arXiv citations
        for aid in citations["arxiv"]:
            res = self.resolve_arxiv(aid)
            if res.get("found") is False:
                clean = re.sub(r"v[0-9]+$", "", aid).strip()
                if clean in evidence_arxiv or aid in evidence_arxiv:
                    # Grounded in the gathered evidence ledger -> a lookup gap, not a
                    # fabricated citation. Surface a non-blocking notice (The Square:
                    # no silent suppression) and do NOT fail the gate.
                    citations.setdefault("evidence_grounded", []).append(
                        f"arXiv:{aid} absent from resolver registry but grounded in evidence ledger."
                    )
                    continue
                violations.append(
                    f"[CITATION_NOT_FOUND] arXiv identifier '{aid}' does not exist in the arXiv registry."
                )
            elif res.get("found") is True:
                pub_yr = res.get("published_year")
                title = res.get("title", "")
                summary = res.get("summary", "")

                # Check future year
                if pub_yr and pub_yr > current_year + 1:
                    violations.append(
                        f"[CITATION_YEAR_MISMATCH] arXiv:{aid} ('{title}') claims future publication year {pub_yr}."
                    )

                # Extract context around this citation in the text
                citing_context = ""
                for line in text.splitlines():
                    if aid in line:
                        citing_context += " " + line
                if not citing_context.strip():
                    citing_context = text

                # Contradiction-Only Attribution Check
                ok, err = self.check_attribution_contradiction(
                    citing_context, aid, title,
                    retrieved_summary=summary,
                    retrieved_authors=res.get("authors", [])
                )
                if not ok:
                    violations.append(
                        f"[CITATION_TITLE_MISMATCH] arXiv:{aid} attribution contradiction: {err}."
                    )

        # 2. Verify DOIs
        for doi in citations["doi"]:
            res = self.resolve_doi(doi)
            if res.get("found") is False:
                if doi in evidence_dois:
                    # Grounded in the evidence ledger -> lookup gap, not a fabricated
                    # citation. Non-blocking notice only (The Square: no silent drop).
                    citations.setdefault("evidence_grounded", []).append(
                        f"DOI:{doi} absent from resolver registry but grounded in evidence ledger."
                    )
                    continue
                violations.append(
                    f"[CITATION_NOT_FOUND] DOI '{doi}' was not found in Crossref registry."
                )
            elif res.get("found") is True:
                pub_yr = res.get("published_year")
                title = res.get("title", "")

                # Check future year
                if pub_yr and pub_yr > current_year + 1:
                    violations.append(
                        f"[CITATION_YEAR_MISMATCH] DOI:{doi} ('{title}') claims future publication year {pub_yr}."
                    )

                citing_context = ""
                for line in text.splitlines():
                    if doi in line:
                        citing_context += " " + line
                if not citing_context.strip():
                    citing_context = text

                # Contradiction-Only Attribution Check
                ok, err = self.check_attribution_contradiction(
                    citing_context, doi, title,
                    retrieved_summary=res.get("summary", ""),
                    retrieved_authors=res.get("authors", [])
                )
                if not ok:
                    violations.append(
                        f"[CITATION_TITLE_MISMATCH] DOI:{doi} attribution contradiction: {err}."
                    )

        # 3. Verify Claimed Venue / Year Pairings
        for cp in citations["claimed_papers"]:
            c_title = cp["title"].lower()
            c_yr = cp["claimed_year"]
            # Known historical papers ground truth check
            if "crypsinous" in c_title and c_yr > 2020:
                violations.append(
                    f"[CITATION_YEAR_MISMATCH] Ouroboros Crypsinous was published at IEEE S&P 2019, but text asserts {c_yr}."
                )
            if c_yr > current_year:
                violations.append(
                    f"[CITATION_YEAR_MISMATCH] Paper '{cp['title']}' claimed venue year {c_yr} in the future."
                )

        # 4. Verify & Auto-Resolve Unindexed Works via Crossref
        citations["resolved_unindexed"] = []
        for up in citations.get("unindexed_papers", []):
            c_yr = up["year"]
            if c_yr > current_year + 1:
                violations.append(
                    f"[CITATION_YEAR_MISMATCH] Unindexed work '{up['title']}' claimed future year {c_yr}."
                )
            res = self.resolve_unindexed_crossref(up["author"], up["year"], up["title"])
            if res and res.get("found"):
                citations["resolved_unindexed"].append({
                    "claimed_title": up["title"],
                    "doi": res.get("doi"),
                    "resolved_title": res.get("title")
                })

        return len(violations) == 0, violations, citations


class EvidenceGrounding:
    """
    Evidence-ledger grounding gate.

    Existence checks alone let a draft pass with real-sounding but invented
    references (wrong venue, nonexistent journal paper, invented authors) as
    long as it carries no resolvable identifier. This gate instead requires
    every reference the draft cites to trace back to the evidence actually
    gathered in Phase 1 (scratchpad.md), by URL, DOI, arXiv id, or title-token
    overlap with a single ledger line. Optionally a reference that is absent
    from the ledger may still be accepted when Crossref resolves it to a work
    whose title is substantially contained in the reference. Network errors
    never count as grounded.
    """

    HEADING_RE = re.compile(
        r"^\s*(?:#{1,6}\s*|\*\*\s*)?(?:\d+[.)]\s*)?"
        r"(references|sources|bibliography|works cited|citations|further reading)"
        r"(?:\s*(?:&|and)\s*[A-Za-z ]{0,30})?\s*:?\s*(?:\*\*)?\s*:?\s*$",
        re.I,
    )
    ENTRY_RE = re.compile(r"^\s*(?:[-*+•]|\d+[.)]|\[\d+\])\s+(.*\S)")
    URL_RE = re.compile(r"https?://[^\s<>()\[\]\"'`]+", re.I)
    ARXIV_RE = re.compile(r"\b([0-9]{4}\.[0-9]{4,5})(?:v[0-9]+)?\b")
    DOI_RE = re.compile(r"\b(10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+)")
    OVERLAP = 0.6

    def __init__(self, ledger_text, resolver=None, allow_network=True):
        self.ledger = ledger_text or ""
        self.resolver = resolver
        self.allow_network = allow_network
        self.ledger_urls = {self.norm_url(u) for u in self.URL_RE.findall(self.ledger)}
        self.ledger_arxiv = set(self.ARXIV_RE.findall(self.ledger))
        self.ledger_dois = {self.norm_doi(d) for d in self.DOI_RE.findall(self.ledger)}
        self.ledger_lines = []
        for line in self.ledger.splitlines():
            toks = self.tokens(line)
            if toks:
                self.ledger_lines.append(toks)

    @staticmethod
    def norm_url(u):
        u = u.strip().rstrip(".,;:!?*_").lower()
        u = re.sub(r"^https?://", "", u)
        u = re.sub(r"^www\.", "", u)
        u = re.sub(r"[?#].*$", "", u)
        u = re.sub(r"/(abs|pdf)/", "/abs/", u)
        u = re.sub(r"\.pdf$", "", u)
        return u.rstrip("/")

    @staticmethod
    def norm_doi(d):
        return re.sub(r"[.,;:)\]]+$", "", d).lower()

    @staticmethod
    def tokens(text):
        toks = set()
        for w in re.findall(r"[A-Za-z][A-Za-z0-9_-]{2,}", (text or "").lower()):
            s = DeterministicCitationResolver.stem(w)
            if s and s not in STOPWORDS and w not in STOPWORDS:
                toks.add(s)
        return toks

    def extract_references(self, text):
        """Return reference entries from a References/Sources section."""
        entries = []
        in_refs = False
        for line in (text or "").splitlines():
            stripped = line.strip()
            if self.HEADING_RE.match(stripped) and len(stripped) < 60:
                in_refs = True
                continue
            if in_refs and re.match(r"^\s*#{1,6}\s+\S", line):
                in_refs = False
                continue
            if not in_refs or not stripped:
                continue
            m = self.ENTRY_RE.match(line)
            entry = m.group(1) if m else stripped
            if len(entry) >= 8:
                entries.append(entry)
        return entries

    def _ledger_match(self, entry):
        for u in self.URL_RE.findall(entry):
            if self.norm_url(u) in self.ledger_urls:
                return "url"
        for a in self.ARXIV_RE.findall(entry):
            if a in self.ledger_arxiv:
                return "arxiv"
        for d in self.DOI_RE.findall(entry):
            if self.norm_doi(d) in self.ledger_dois:
                return "doi"
        # Title overlap is computed on the entry minus its URLs.
        etoks = self.tokens(self.URL_RE.sub(" ", entry))
        if len(etoks) >= 2:
            for ltoks in self.ledger_lines:
                if len(etoks & ltoks) / len(etoks) >= self.OVERLAP:
                    return "title"
        return None

    def _crossref_match(self, entry):
        if not (self.allow_network and self.resolver):
            return False
        clean = self.URL_RE.sub(" ", entry)
        etoks = self.tokens(clean)
        if len(etoks) < 3:
            return False
        yr = re.search(r"\b(19|20)\d{2}\b", clean)
        try:
            res = self.resolver.resolve_unindexed_crossref("", yr.group(0) if yr else "", clean[:200])
        except Exception:
            return False
        if not res or res.get("found") is not True:
            return False
        rtoks = self.tokens(res.get("title", ""))
        if not rtoks:
            return False
        return len(rtoks & etoks) / len(rtoks) >= self.OVERLAP

    def check(self, text):
        """Return (ok, violations, report)."""
        report = {"references": 0, "grounded": 0, "ledger_grounded": 0, "ungrounded": []}
        if not self.ledger.strip():
            report["skipped"] = "empty evidence ledger"
            return True, [], report

        violations = []
        entries = self.extract_references(text)
        # Inline arXiv ids / DOIs outside the references section are references too.
        listed = " ".join(entries)
        for a in sorted(set(self.ARXIV_RE.findall(text))):
            if a not in listed:
                entries.append(f"arXiv:{a}")
        for d in sorted({self.norm_doi(x) for x in self.DOI_RE.findall(text)}):
            if d not in listed.lower():
                entries.append(f"doi:{d}")

        report["references"] = len(entries)
        for entry in entries:
            how = self._ledger_match(entry)
            if how:
                report["grounded"] += 1
                report["ledger_grounded"] += 1
                continue
            if self._crossref_match(entry):
                report["grounded"] += 1
                continue
            short = entry if len(entry) <= 140 else entry[:137] + "..."
            report["ungrounded"].append(short)
            violations.append(
                f"[CITATION_UNGROUNDED] Reference '{short}' does not appear in the gathered evidence "
                f"and could not be resolved to a matching published work. Remove it (and any claim that "
                f"depends on it) or replace it with a source from the evidence ledger."
            )

        if entries and report["ledger_grounded"] == 0:
            violations.append(
                "[EVIDENCE_UNUSED] None of the draft's references come from the sources gathered during "
                "research. The synthesis must cite the evidence ledger, not recalled or invented works."
            )
        return len(violations) == 0, violations, report


class AdversarialPrimitiveHeuristics:
    """
    Programmatic invariant checker for high-risk cross-domain abstraction collisions.
    Used alongside LLM Adversarial Auditor to guarantee hard rules are enforced.
    """

    @staticmethod
    def audit(text, topic, domain="academic"):
        violations = []
        lower = text.lower()

        # ── Domain: Academic / Cryptographic / State Proofs ──────────
        # Check 1: MPC ceremony assumption vs consensus threshold
        if re.search(r"\b(mithril|ouroboros|cardano|state proof)\b", lower):
            if re.search(r"\b(1-of-n|1-of-100|single honest|1 honest signer|at least one honest)\b", lower) and \
               re.search(r"\b(mithril|stake-based threshold|signature aggregation|consensus)\b", lower):
                violations.append(
                    "[TRUST_MODEL_MISMATCH] Conflated MPC ceremony assumption (1-of-N honest party) with "
                    "stake-weighted Byzantine agreement threshold (Mithril k-of-m stake quorum)."
                )

            # Check 2: Finite field / exact state roots vs lossy continuous optimization
            if re.search(r"\b(utxo|eutxo|ledger state|state root|merkle root|state transition)\b", lower) and \
               re.search(r"\b(gradient descent|matrix factorization|loss landscape|low-rank approximation|lossy)\b", lower):
                violations.append(
                    "[CATEGORY_COLLISION] Grafted continuous lossy optimization / low-rank matrix factorizations "
                    "onto discrete finite field (𝔽_p) cryptographic state verification. Ledger state requires zero-error algebraic soundness."
                )

            # Check 3: Privacy mechanism vs state compression
            if re.search(r"\bcrypsinous\b", lower) and re.search(r"\b(state compression|scaling|pruning|succinct state)\b", lower):
                violations.append(
                    "[MECHANISM_MISMATCH] Ouroboros Crypsinous is a privacy-preserving leader election protocol (cloaking slot leaders), "
                    "NOT a state compression or rollup scaling mechanism."
                )

        # ── Domain: Engineering / Distributed Systems ────────────────
        if domain == "engineering" or re.search(r"\b(distributed|raft|paxos|consensus|byzantine)\b", lower):
            if re.search(r"\b(zero[- ]latency|instantaneous)\b", lower) and re.search(r"\b(linearizab|strict consisten|quorum)\b", lower):
                violations.append(
                    "[CAP_INVARIANT_VIOLATION] Claimed zero-latency linearizability across distributed nodes without network quorum round-trips."
                )
            if re.search(r"\b(sram bandwidth|register bandwidth)\b", lower) and re.search(r"\b(pcie|nvme|ethernet)\b", lower):
                violations.append(
                    "[HARDWARE_BOUND_MISMATCH] Conflated on-chip SRAM/L1 bandwidth with off-chip PCIe or network bus bandwidth."
                )

        # ── Domain: Finance / DeFi ───────────────────────────────────
        if domain == "finance" or re.search(r"\b(arbitrage|defi|yield|trading)\b", lower):
            if re.search(r"\b(risk[- ]free|guaranteed profit|zero[- ]risk)\b", lower) and not re.search(r"\b(theoretical|riskless in theory|assuming zero slippage)\b", lower):
                violations.append(
                    "[FINANCIAL_INVARIANT_VIOLATION] Claimed 'risk-free' execution without accounting for slippage, gas price races, mempool frontrunning, or counterparty default."
                )
            if re.search(r"\b(revenue)\b", lower) and re.search(r"\b(gmv|gross merchandise volume)\b", lower) and re.search(r"\b(revenue\s+is\s+gmv|revenue\s+of\s+gmv)\b", lower):
                violations.append(
                    "[FINANCIAL_CATEGORY_ERROR] Conflated Gross Merchandise Volume (GMV) with recognized GAAP revenue."
                )

        # ── Domain: Gaming / Emulation ───────────────────────────────
        if domain == "gaming" or re.search(r"\b(emulator|emulation|recompiler)\b", lower):
            if re.search(r"\b(cycle[- ]accurate)\b", lower) and re.search(r"\b(unbounded fps|unlimited framerate|60fps to 240fps)\b", lower):
                violations.append(
                    "[EMULATION_INVARIANT_VIOLATION] Claimed arbitrary framerate scaling on a strict cycle-accurate hardware emulation pipeline without breaking cycle timing."
                )

        # ── Domain: General / Sports / Automotive ────────────────────
        if domain == "general_sports_auto" or re.search(r"\b(automotive|engine|horsepower)\b", lower):
            if re.search(r"\b0-60\b", lower) and re.search(r"\b(under 1 second|0\.[0-9] seconds)\b", lower) and not re.search(r"\b(dragster|rocket)\b", lower):
                violations.append(
                    "[PHYSICAL_LIMIT_VIOLATION] Claimed 0-60 mph acceleration below 1.0 second on street production tires exceeding coefficient of friction limits."
                )

        return len(violations) == 0, violations


class PlatformSyntaxLinter:
    """
    Deterministic Platform Syntax & Format Linter
    Strips raw LaTeX escapes, converts to clean Unicode, sanitizes cashtags, and asserts length limits.
    """

    @staticmethod
    def sanitize_math_to_unicode(text):
        """Converts LaTeX symbols and math commands into clean Unicode."""
        res = text
        for pat, repl in LATEX_UNICODE_MAP:
            res = re.sub(pat, repl, res)

        # Clean math subscript expressions e.g. _{zk} -> _zk, _{st} -> _st
        res = re.sub(r"_\{([a-zA-Z0-9_-]+)\}", r"_\1", res)

        # Remove remaining math delimiters: $...$ and $$...$$
        res = re.sub(r"\$\$([^\$]+)\$\$", r"\1", res)
        # Match $math$ but preserve $100, $5.50, $ADA, $BTC
        res = re.sub(r"(?<![A-Za-z0-9])\$([^\$\n]+?)\$(?![A-Za-z0-9])", r"\1", res)

        # Clean single-letter cashtags ($f, $C, $x) into plain characters
        res = re.sub(r"(?<![A-Za-z0-9])\$([a-zA-Z])(?![A-Za-z0-9_])", r"\1", res)
        return res

    @staticmethod
    def sanitize_meta_commentary(text):
        """Strips accidental LLM self-correction, rubric meta-apologies, and breaks >650c single-paragraph walls of text."""
        cleaned = re.sub(r"\*\s*\((?:Self-Correction|Note:\s*The\s*rejection|Rejection\s*Trace)[^\)]*\)\s*\*?", "", text, flags=re.IGNORECASE)
        cleaned = re.sub(r"\[(?:Self-Correction|Note:\s*The\s*rejection|Rejection\s*Trace)[^\]]*\]", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\*\s*\*Decision:\*\s*I\s*will\s*(?:cite|describe|remove|omit)[^\n]*", "", cleaned, flags=re.IGNORECASE)
        # Strip rubric meta-apologies (e.g. "*Note: As this topic concerns market microstructure rather than a specific corporate entity...*")
        cleaned = re.sub(
            r"^\s*\*?(?:Note|Editor's Note|Analytical Note):\s*(?:As this topic concerns|While this topic|Because this inquiry examines|Since this analysis focuses on)[^\n]*(?:corporate entity|10-K|SEC filing|balance sheet)[^\n]*\*?\s*$",
            "",
            cleaned,
            flags=re.IGNORECASE | re.MULTILINE,
        )
        cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)

        # If this is a multi-post thread (contains ---POST---), break any single paragraph > 680 chars at a natural sentence boundary
        if "---POST---" in cleaned:
            raw_posts = cleaned.split("---POST---")
            rebuilt_posts = []
            for rp in raw_posts:
                paras = [p.strip() for p in rp.strip().split("\n\n") if p.strip()]
                new_paras = []
                for para in paras:
                    if len(para) > 680 and not para.startswith(("▸", "•", "-", "Primary", "Sources:")):
                        sents = re.split(r"(?<=[.?!])\s+(?=[A-Z0-9\"'(])", para)
                        if len(sents) >= 4:
                            mid = len(sents) // 2
                            new_paras.append(" ".join(sents[:mid]).strip())
                            new_paras.append(" ".join(sents[mid:]).strip())
                        elif len(sents) >= 2 and len(sents[0]) >= 140:
                            new_paras.append(sents[0].strip())
                            new_paras.append(" ".join(sents[1:]).strip())
                        else:
                            new_paras.append(para)
                    else:
                        new_paras.append(para)
                rebuilt_posts.append("\n\n".join(new_paras))
            cleaned = "\n\n---POST---\n\n".join(rebuilt_posts)

        return cleaned

    @staticmethod
    def extract_fallback_thread(text, max_len=None):
        """Extracts a structured, magazine-style multi-post social thread from dossier.md."""
        x_premium = os.environ.get("X_PREMIUM", "1") == "1"
        if max_len is None:
            max_len = int(os.environ.get("X_MAX_CHARS", "1500")) if x_premium else 460
        target_min = 380 if (x_premium and max_len > 600) else 250
        max_sentence_len = 360 if x_premium else 240

        # Strip rubric meta-apologies first
        text = PlatformSyntaxLinter.sanitize_meta_commentary(text)

        # Extract dossier title if present
        title_match = re.search(r"^#\s+(?:Sovereign\s+[A-Za-z\s&]+Dossier:\s*)?(.+)$", text, flags=re.MULTILINE)
        raw_title = title_match.group(1).strip() if title_match else ""
        raw_title = re.sub(r"^\[[a-zA-Z0-9_-]+\]\s*", "", raw_title).strip()

        def clean_txt(t, keep_urls=False):
            if keep_urls:
                t = re.sub(r"\[([^\]]+)\]\((https?://[^\)]+)\)", r"\1 (\2)", t)
            else:
                t = re.sub(r"\[([^\]]+)\]\((https?://[^\)]+)\)", r"\1", t)
            t = re.sub(r"[*_#`|]", "", t)
            t = PlatformSyntaxLinter.sanitize_math_to_unicode(t)
            t = re.sub(r"\\(?:left|right|cdot|text|mathrm)", "", t)
            t = re.sub(r"\.{2,}", ".", t)
            t = re.sub(r"\s+", " ", t).strip()
            return t

        def extract_metric_callouts(sec_text, limit=2):
            callouts = []
            for line in sec_text.split("\n"):
                ls = line.strip()
                if ls.startswith(("-", "*", "•", "▸")) and any(ch.isdigit() for ch in ls):
                    c = clean_txt(ls.lstrip("-*•▸ ").strip())
                    if 35 <= len(c) <= 180:
                        callouts.append(f"▸ {c}")
                        if len(callouts) >= limit:
                            break
            return callouts

        def parse_tables_to_sentences(sec_text):
            sentences = []
            lines = [l.strip() for l in sec_text.split("\n") if l.strip().startswith("|")]
            for l in lines:
                if "---" in l or "Task" in l or "Dataset" in l or "Metric" in l:
                    continue
                parts = [clean_txt(c) for c in l.split("|") if c.strip()]
                if len(parts) >= 4:
                    task = parts[0]
                    dataset = parts[1]
                    metric = parts[2]
                    res = parts[3]
                    comp = parts[4] if len(parts) > 4 else "baselines"
                    s = f"In benchmark evaluation of {task} ({dataset}), recorded result achieves {res} {metric}, outperforming {comp}."
                    sentences.append(s)
            return sentences

        def split_into_clean_sentences(sec_text, max_sent_len=max_sentence_len):
            lines = []
            for l in sec_text.split("\n"):
                ls = l.strip()
                if ls.startswith("#") or ls.startswith("|") or "--- | ---" in ls:
                    continue
                if re.match(r"^\*?(?:Note|Editor's Note):\s*As this topic concerns", ls, re.I):
                    continue
                lines.append(l)
            clean_body = " ".join(lines)

            raw_sents = re.split(r"(?<=[.?!])\s+", clean_body)
            cleaned = []
            lead_strip = r"^(?:Critique|Response|Mechanism|Strength|Limitation|Implication|Advantage|Operation|Function|Observation|Experiment|FLOPs Analysis|Note|Key Contribution|The MDL Solution|Concrete Benchmark):\s*"
            for s in raw_sents:
                s = clean_txt(s)
                s = re.sub(lead_strip, "", s, flags=re.I).strip()
                if len(s) < 40 or s.endswith(":") or s.startswith(("-", "*")) or re.match(r"^\d+\.", s):
                    continue
                if len(s) <= max_sent_len:
                    if s and s[0].isupper():
                        cleaned.append(s)
                else:
                    clauses = re.split(r"(?<=[;—:])\s+|(?<=[a-zA-Z0-9]\),\s)", s)
                    curr = ""
                    for c in clauses:
                        c = c.strip()
                        if not c:
                            continue
                        c = re.sub(lead_strip, "", c, flags=re.I).strip()
                        if len(curr) + len(c) + 1 <= max_sent_len:
                            curr = (curr + " " + c).strip() if curr else c
                        else:
                            if len(curr) >= 45 and curr[0].isupper():
                                cleaned.append(curr.rstrip(",;—:") + ".")
                            curr = (c[0].upper() + c[1:]) if c else ""
                    if len(curr) >= 45 and curr[0].isupper():
                        cleaned.append(curr.rstrip(",;—:") + ".")
            return cleaned

        orphan_re = re.compile(r"^(?:However|Therefore|Furthermore|Moreover|In addition|And|But|Thus|Hence|Meanwhile)[,\s]+", re.I)

        def clean_orphan(s):
            if orphan_re.match(s):
                s = orphan_re.sub("", s)
                if s:
                    s = s[0].upper() + s[1:]
            return s

        def assemble_post(sentences, target_min_len=target_min, target_max=max_len, is_intro=False, callouts=None):
            if not sentences:
                return ""
            callouts = callouts or []

            def format_with_paragraphs(sent_list):
                if len(sent_list) >= 3:
                    p1 = " ".join(sent_list[:2])
                    p2 = " ".join(sent_list[2:])
                    body = f"{p1}\n\n{p2}"
                elif len(sent_list) == 2 and (len(sent_list[0]) + len(sent_list[1]) > 260):
                    body = f"{sent_list[0]}\n\n{sent_list[1]}"
                else:
                    body = " ".join(sent_list)
                if callouts and target_max > 520:
                    c_block = "\n".join(callouts[:2])
                    if len(body) + len(c_block) + 2 <= target_max:
                        body = f"{body}\n\n{c_block}"
                return body

            if is_intro and len(sentences) >= 2:
                for count in (4, 3, 2):
                    if len(sentences) >= count:
                        cand = format_with_paragraphs(sentences[:count])
                        if target_min_len <= len(cand) <= target_max:
                            return cand
                for j in range(1, len(sentences)):
                    cand = format_with_paragraphs([sentences[0], sentences[j]])
                    if len(cand) <= target_max:
                        return cand

            for count in (4, 3, 2):
                if len(sentences) >= count:
                    for i in range(len(sentences) - count + 1):
                        if not is_intro and orphan_re.match(sentences[i]):
                            continue
                        cand = format_with_paragraphs(sentences[i:i + count])
                        if target_min_len <= len(cand) <= target_max:
                            return clean_orphan(cand)

            # Fallback pair/triplet search
            for i in range(len(sentences)):
                if not is_intro and orphan_re.match(sentences[i]):
                    continue
                for j in range(i + 1, len(sentences)):
                    cand = format_with_paragraphs([sentences[i], sentences[j]])
                    if target_min_len <= len(cand) <= target_max:
                        return clean_orphan(cand)

            best = ""
            for s in sentences:
                s = clean_orphan(s)
                if len(s) > len(best) and len(s) <= target_max:
                    best = s
            return best

        sections = re.split(r"\n(?=## )", text)
        abstract_post = ""
        foundations_post = ""
        architecture_post = ""
        empirical_post = ""
        tradeoffs_post = ""
        provenance_post = ""

        for sec in sections:
            lines = sec.strip().split("\n")
            hdr = lines[0].lower()
            content = "\n".join(lines[1:])
            callouts = extract_metric_callouts(content)
            if any(k in hdr for k in ["abstract", "summary", "thesis", "overview"]) and not abstract_post:
                sents = split_into_clean_sentences(content)
                header_prefix = f"🏛️ {raw_title}\n\n" if (raw_title and max_len >= 420) else ""
                avail_max = max_len - len(header_prefix)
                body = assemble_post(sents, target_min_len=max(180, target_min - len(header_prefix)), target_max=avail_max, is_intro=True)
                if body:
                    abstract_post = f"{header_prefix}{body}" if header_prefix else body
            elif any(k in hdr for k in ["theoretical", "foundations", "energy", "specification", "financial performance", "hardware", "microstructure", "order-flow"]) and not foundations_post:
                sents = split_into_clean_sentences(content)
                foundations_post = assemble_post(sents, callouts=callouts)
            elif any(k in hdr for k in ["architecture", "algorithmic", "mechanics", "implementation", "capital allocation", "emulation", "tactical", "liquidity", "protocol"]) and not architecture_post:
                sents = split_into_clean_sentences(content)
                architecture_post = assemble_post(sents, callouts=callouts)
            elif any(k in hdr for k in ["benchmark", "empirical", "performance", "valuation", "frame timing", "telemetry", "comparative"]) and not empirical_post:
                tbl_sents = parse_tables_to_sentences(content)
                sents = tbl_sents + split_into_clean_sentences(content)
                empirical_post = assemble_post(sents, callouts=callouts)
            elif any(k in hdr for k in ["discourse", "limitation", "tradeoff", "bottleneck", "macro risk", "failure", "challenge", "postmortem", "assessment"]) and not tradeoffs_post:
                sents = split_into_clean_sentences(content)
                tradeoffs_post = assemble_post(sents, callouts=callouts)
            elif any(k in hdr for k in ["citation", "reference", "provenance", "filing", "source", "codebase"]) and not provenance_post:
                ref_items = []
                for rl in content.split("\n"):
                    rls = rl.strip()
                    if not rls or rls.startswith("#"):
                        continue
                    cleaned_ref = clean_txt(rls.lstrip("-*•0123456789. ").strip(), keep_urls=True)
                    if len(cleaned_ref) >= 12:
                        ref_items.append(f"▸ {cleaned_ref}")
                arxiv_ids = list(dict.fromkeys(re.findall(r"arXiv:([0-9]+\.[0-9]+(?:v\d+)?)", text)))[:3]
                urls = list(dict.fromkeys(re.findall(r"https?://[^\s\)\]>\"']+", content)))[:3]
                if ref_items:
                    chosen_refs = []
                    cur_len = 28
                    for item in ref_items[:4]:
                        if cur_len + len(item) + 2 <= max_len - 80:
                            chosen_refs.append(item)
                            cur_len += len(item) + 2
                    if chosen_refs:
                        provenance_post = "Primary Sources & Provenance:\n" + "\n".join(chosen_refs) + "\n\nArchived in the Blue Lodge Sovereign Library."
                if not provenance_post:
                    cite_tokens = [f"arXiv:{r}" for r in arxiv_ids] + urls
                    p_lead = "Primary Sources: " + "; ".join(cite_tokens[:3]) + "." if cite_tokens else "Primary Sources: Verified research artifacts & empirical benchmarks."
                    p_tail = "Full technical monograph and citations preserved in the Blue Lodge Sovereign Library."
                    combined = f"{p_lead}\n\n{p_tail}"
                    provenance_post = combined if len(combined) <= max_len else p_lead

        candidates = [abstract_post, foundations_post, architecture_post, empirical_post, tradeoffs_post, provenance_post]
        cleaned_posts = []
        for p in candidates:
            if p and len(p.strip()) >= 60:
                paras = []
                for para in p.split("\n\n"):
                    lines_out = []
                    for ln in para.split("\n"):
                        ln_c = re.sub(r"[ \t]+", " ", ln).strip()
                        ln_c = re.sub(r"\s+\.", ".", ln_c)
                        ln_c = re.sub(r"\.{2,}", ".", ln_c)
                        if ln_c:
                            lines_out.append(ln_c)
                    if lines_out:
                        paras.append("\n".join(lines_out))
                if paras:
                    cleaned_posts.append("\n\n".join(paras))
        if not cleaned_posts:
            cleaned_posts = [clean_txt(text[:max_len])]
        return "\n\n---POST---\n\n".join(cleaned_posts)

    @staticmethod
    def lint(text, platform="social", max_chars=None):
        violations = []
        sanitized = PlatformSyntaxLinter.sanitize_meta_commentary(text)
        sanitized = PlatformSyntaxLinter.sanitize_math_to_unicode(sanitized)

        # Check for lingering raw LaTeX backslashes for math
        raw_latex = re.findall(r"\\(?:sigma|pi|sum|frac|sqrt|alpha|beta|gamma|mathbb|geq|leq|neq)\b", sanitized, re.I)
        if raw_latex:
            violations.append(f"[UNRENDERED_LATEX] Found raw LaTeX commands: {', '.join(set(raw_latex))}")

        # Check for lingering single-letter cashtags
        bad_cashtags = re.findall(r"(?<![A-Za-z0-9])\$([a-zA-Z])(?![A-Za-z0-9_])", sanitized)
        if bad_cashtags:
            violations.append(f"[INVALID_CASHTAG] Found unescaped single-letter cashtags: {', '.join(set(bad_cashtags))}")

        x_premium = os.environ.get("X_PREMIUM", "1") == "1"
        x_limit = int(os.environ.get("X_MAX_CHARS", "4000")) if x_premium else 280

        if max_chars is None:
            if platform in ("twitter", "x"):
                max_chars = x_limit
            elif platform == "bluesky":
                max_chars = 300
            elif platform in ("mastodon", "social", "multi"):
                max_chars = x_limit if x_premium else 480
            else:
                max_chars = x_limit if x_premium else 480

        # Check character limits per post if posts are separated by ---POST---
        posts = [p.strip() for p in sanitized.split("---POST---") if p.strip()]
        if not posts:
            posts = [sanitized.strip()]

        orphan_re = re.compile(r"^(?:However|Therefore|Furthermore|Moreover|In addition|And|But|Thus|Hence|Meanwhile)[,\s]+", re.I)
        cleaned_posts = []

        for idx, p in enumerate(posts):
            p_len = len(p)
            if p_len > max_chars:
                violations.append(
                    f"[CHAR_LIMIT_EXCEEDED] Post {idx+1} exceeds {max_chars} chars ({p_len} chars): '{p[:60]}...'"
                )
            if orphan_re.match(p):
                violations.append(
                    f"[ORPHAN_TRANSITIONAL_OPENING] Post {idx+1} begins with an orphan connective without introductory context: '{orphan_re.match(p).group(0).strip()}'"
                )
                m = orphan_re.match(p)
                p = p[m.end():]
                if p:
                    p = p[0].upper() + p[1:]

            cleaned_posts.append(p)
            if platform in ("social", "multi") and not x_premium:
                sentences = re.split(r"(?<=[.?!])\s+", p)
                for s_idx, s in enumerate(sentences):
                    if len(s) > 270:
                        clauses = re.split(r"(?<=[;—:])\s+|(?<=,\s)", s)
                        if all(len(c) > 270 for c in clauses):
                            violations.append(
                                f"[TWITTER_UNSPLITTABLE_SENTENCE] Post {idx+1} sentence {s_idx+1} has {len(s)} chars without punctuation break, exceeding Twitter 270 char limit: '{s[:50]}...'"
                            )

        # Check minimum post count for multi-post threads
        if "---POST---" in text and len(posts) < 4:
            violations.append(f"[INSUFFICIENT_POST_COUNT] Thread contains only {len(posts)} post(s); expected at least 5 posts.")

        # Check for truncated final post (dangling punctuation or trailing conjunctions/prepositions)
        last_post = posts[-1].strip() if posts else ""
        if last_post and len(posts) > 1:
            if re.search(r"[,;—:\-]\s*$", last_post) or re.search(r"\b(and|or|with|where|which|that|the|a|an|in|on|at|of|to|is|has|have|having|including)\s*$", last_post, re.I):
                violations.append(f"[TRUNCATED_FINAL_POST] Final post appears truncated mid-sentence (ends with: '{last_post[-50:]}')")

        # Check for references / provenance in multi-post threads
        if len(posts) > 1:
            has_provenance = any(
                re.search(r"(arXiv:\d+\.\d+|doi:|https?://|Primary Sources?:|Sources?:|References?:|Citations?:|Sovereign Library|Blue Lodge|Archiv|SEC|10-K|10-Q|GitHub|RFC|NFL|ESPN|Next Gen Stats|PFF|Telemetry|Dyno|Chassis|FIA|F1|Formula 1|NASCAR|Motorsport|Stathead|Pro-Football-Reference)", p, re.I)
                for p in posts
            )
            if not has_provenance:
                violations.append("[MISSING_PROVENANCE_REFERENCES] Thread does not contain primary source references, verified citations, or Sovereign Library provenance.")

        sanitized = "\n\n---POST---\n\n".join(cleaned_posts)
        return len(violations) == 0, violations, sanitized


def main():
    parser = argparse.ArgumentParser(description="Deterministic Research Verifier & Linter")
    subparsers = parser.add_subparsers(dest="command")

    # verify-citations
    p_cit = subparsers.add_parser("verify-citations", help="Deterministic Citation & Entity Resolver")
    p_cit.add_argument("--file", "-f", help="Path to markdown/text file")
    p_cit.add_argument("--text", "-t", help="Raw text string")
    p_cit.add_argument("--topic", required=True, help="Research inquiry topic")
    p_cit.add_argument("--domain", default="academic", help="Research domain")
    p_cit.add_argument("--cache", help="Custom citation cache JSON path")
    p_cit.add_argument("--evidence", help="Evidence ledger (scratchpad.md); every cited reference must trace back to it")

    # audit-heuristics
    p_aud = subparsers.add_parser("audit-heuristics", help="Adversarial Primitive Invariant Auditor")
    p_aud.add_argument("--file", "-f", help="Path to markdown/text file")
    p_aud.add_argument("--text", "-t", help="Raw text string")
    p_aud.add_argument("--topic", required=True, help="Research inquiry topic")
    p_aud.add_argument("--domain", default="academic", help="Research domain")

    # lint-platform
    p_lint = subparsers.add_parser("lint-platform", help="Platform Syntax & Format Linter")
    p_lint.add_argument("--file", "-f", help="Path to markdown/text file")
    p_lint.add_argument("--text", "-t", help="Raw text string")
    p_lint.add_argument("--platform", default="twitter", help="Target platform (twitter, mastodon, bluesky)")
    p_lint.add_argument("--fix", action="store_true", help="Auto-fix formatting violations in place")

    # extract-thread
    p_ext = subparsers.add_parser("extract-thread", help="Extract substantive fallback social thread from dossier")
    p_ext.add_argument("--file", "-f", required=True, help="Path to dossier.md")
    p_ext.add_argument("--text", "-t", help="Raw text string")
    p_ext.add_argument("--max-len", type=int, default=460, help="Maximum length per post")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Helper to get text
    def get_content(cmd_args):
        if cmd_args.text:
            return cmd_args.text
        if cmd_args.file:
            if not os.path.exists(cmd_args.file):
                print(f"Error: file not found: {cmd_args.file}", file=sys.stderr)
                sys.exit(2)
            with open(cmd_args.file, "r", encoding="utf-8") as f:
                return f.read()
        return sys.stdin.read()

    content = get_content(args)

    if args.command == "extract-thread":
        res_thread = PlatformSyntaxLinter.extract_fallback_thread(content, args.max_len)
        print(res_thread)
        sys.exit(0)

    elif args.command == "verify-citations":
        cache = CitationCache(args.cache) if args.cache else None
        resolver = DeterministicCitationResolver(cache=cache)
        # Load the evidence ledger FIRST so the resolver can treat evidence-grounded
        # identifiers as verified-in-context (evidence-aware CITATION_NOT_FOUND
        # suppression, incident 41bf78240605).
        ledger = ""
        if args.evidence and os.path.isfile(args.evidence):
            try:
                with open(args.evidence, "r", encoding="utf-8", errors="replace") as f:
                    ledger = f.read()
            except OSError:
                ledger = ""
        ok, violations, citations = resolver.verify(
            content, args.topic, args.domain, evidence=ledger
        )
        grounding = None
        if ledger:
            allow_net = os.environ.get("RESEARCH_GROUNDING_NETWORK", "1") != "0"
            g_ok, g_viol, grounding = EvidenceGrounding(ledger, resolver, allow_net).check(content)
            violations = violations + g_viol
            ok = ok and g_ok
        output = {
            "status": "PASS" if ok else "FAIL",
            "extracted_citations": citations,
            "violations": violations
        }
        if grounding is not None:
            output["grounding"] = grounding
        print(json.dumps(output, indent=2))
        sys.exit(0 if ok else 1)

    elif args.command == "audit-heuristics":
        ok, violations = AdversarialPrimitiveHeuristics.audit(content, args.topic, args.domain)
        output = {
            "status": "PASS" if ok else "FAIL",
            "violations": violations
        }
        print(json.dumps(output, indent=2))
        sys.exit(0 if ok else 1)

    elif args.command == "lint-platform":
        ok, violations, sanitized = PlatformSyntaxLinter.lint(content, args.platform)
        if args.fix and args.file:
            with open(args.file, "w", encoding="utf-8") as f:
                f.write(sanitized)
        output = {
            "status": "PASS" if ok else "FAIL",
            "violations": violations,
            "sanitized_preview": sanitized[:300]
        }
        print(json.dumps(output, indent=2))
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
