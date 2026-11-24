"""Deterministic Sub-Second Visual Feature Extraction & Similarity Re-Ranking for Blue Lodge.

Provides a two-tier visual similarity engine:
1. Tier 1 (Instant Exact Match): 64-bit perceptual difference hash (dHash) for <1ms stock/duplicate identification.
2. Tier 2 (Semantic Visual Cosine Similarity): MobileCLIP ONNX encoder converting 224x224 RGB image arrays
   into 512-dimensional unit vectors on CPU (~25-35ms) for photo-to-photo matching across angles and lighting.
3. Color & Silhouette Profiling: Multi-channel HSV colorway and greyscale luminance silhouette analysis.
4. Resilient Fallback: Automatically falls back to normalized dHash and color comparison if ONNX is unprovisioned.
"""

from __future__ import annotations

import base64
import io
import logging
import os
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

try:
    import onnxruntime as ort  # type: ignore
except ImportError:
    ort = None

logger = logging.getLogger("vision_embedder")

# Normalization constants
DINO_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
DINO_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

_LODGE_ROOT = Path(__file__).resolve().parents[2]

CANDIDATE_MODEL_PATHS = [
    _LODGE_ROOT / "models" / "vision" / "mobileclip_s0.onnx",
    _LODGE_ROOT / "models" / "vision" / "dinov2_vits14.onnx",
    _LODGE_ROOT / "models" / "vision" / "mobileclip_b.onnx",
    (Path.home() / "models/vision/mobileclip_s0.onnx"),
    (Path.home() / "models/vision/dinov2_vits14.onnx"),
]


def _resolve_model_path(preferred_path: Path | str | None = None) -> Path:
    """Find the first existing, non-stub Vision ONNX model path."""
    if preferred_path:
        p = Path(preferred_path)
        if p.exists() and p.stat().st_size > 100_000:
            return p

    for p in CANDIDATE_MODEL_PATHS:
        if p.exists() and p.stat().st_size > 100_000:
            return p

    return preferred_path if preferred_path else CANDIDATE_MODEL_PATHS[0]


def compute_image_dhash(image: Image.Image, hash_size: int = 8) -> int:
    """Compute 64-bit perceptual difference hash (dHash) for an image."""
    try:
        # Resize to (hash_size + 1, hash_size) in greyscale
        resized = image.convert("L").resize((hash_size + 1, hash_size), Image.Resampling.BILINEAR)
        pixels = np.asarray(resized, dtype=np.int16)
        # Compute horizontal gradient: compare adjacent pixels
        diff = pixels[:, 1:] > pixels[:, :-1]
        # Pack boolean array into an integer
        decimal_val = 0
        for val in diff.flatten():
            decimal_val = (decimal_val << 1) | int(val)
        return decimal_val
    except Exception as e:
        logger.debug("Failed computing dHash: %s", e)
        return 0


def hamming_distance(h1: int, h2: int) -> int:
    """Compute bitwise Hamming distance between two 64-bit integers."""
    return bin(h1 ^ h2).count("1")


def preprocess_pil_image(
    im: Image.Image,
    target_size: tuple[int, int] = (224, 224),
    is_dinov2: bool = False,
) -> np.ndarray:
    """Preprocess a PIL Image into a normalized float32 NCHW tensor for MobileCLIP or DINOv2 ONNX."""
    im_rgb = im.convert("RGB")
    im_resized = im_rgb.resize(target_size, Image.Resampling.BICUBIC)
    arr = np.asarray(im_resized, dtype=np.float32) / 255.0

    mean = DINO_MEAN if is_dinov2 else CLIP_MEAN
    std = DINO_STD if is_dinov2 else CLIP_STD
    arr = (arr - mean) / std

    tensor = np.transpose(arr, (2, 0, 1))
    tensor = np.expand_dims(tensor, axis=0)
    return tensor.astype(np.float32)


def parse_image_input(image_input: Image.Image | str | bytes) -> Image.Image | None:
    """Safely parse a PIL Image, base64 data URL, HTTP image URL, raw base64 string, or byte payload."""
    if isinstance(image_input, Image.Image):
        return image_input
    if not image_input:
        return None

    raw_bytes: bytes | None = None
    if isinstance(image_input, bytes):
        raw_bytes = image_input
    elif isinstance(image_input, str):
        cleaned = image_input.strip()
        if cleaned.startswith(("http://", "https://")):
            # Remote image URL: download safely with timeout
            try:
                req = urllib.request.Request(
                    cleaned,
                    headers={"User-Agent": "BlueLodge-VisionEmbedder/1.0", "Accept": "image/*"},
                )
                with urllib.request.urlopen(req, timeout=6.0) as resp:
                    if resp.status == 200:
                        raw_bytes = resp.read()
            except Exception as exc:
                logger.debug("Failed downloading intake image from %s: %s", cleaned, exc)
                raw_bytes = None
        elif cleaned.startswith("data:"):
            # Any data URI (data:image/jpeg;base64,..., data:application/octet-stream;base64,...)
            parts = cleaned.split(",", 1)
            if len(parts) == 2:
                try:
                    raw_bytes = base64.b64decode(parts[1])
                except Exception:
                    raw_bytes = None
        elif len(cleaned) < 1024:
            # Check local filesystem path
            try:
                p = Path(cleaned).expanduser().resolve()
                if p.is_file():
                    im = Image.open(p)
                    im.load()
                    return im
            except Exception:
                pass
            try:
                raw_bytes = base64.b64decode(cleaned)
            except Exception:
                raw_bytes = None
        else:
            try:
                raw_bytes = base64.b64decode(cleaned)
            except Exception:
                raw_bytes = None

    if raw_bytes:
        try:
            im = Image.open(io.BytesIO(raw_bytes))
            im.load()
            return im
        except Exception:
            return None
    return None


@dataclass
class ColorProfile:
    """Multi-channel visual color and silhouette profile supporting tuple backward-compatibility."""
    chromatic_ratio: float
    hue_hist: np.ndarray        # 12-bin L1-normalized 1D Hue histogram (0..255)
    val_hist: np.ndarray        # 4-bin L1-normalized 1D Value histogram
    hue_sat_2d: np.ndarray      # 16x4 (64-bin) L1-normalized 2D Joint Hue-Saturation histogram
    luma_profile: np.ndarray    # 8-bin L1-normalized Greyscale luminance histogram

    def __getitem__(self, idx: int) -> Any:
        return (self.chromatic_ratio, self.hue_hist, self.val_hist)[idx]

    def __iter__(self):
        return iter((self.chromatic_ratio, self.hue_hist, self.val_hist))

    def __len__(self) -> int:
        return 3


def compute_color_profile(im: Image.Image) -> ColorProfile:
    """Extract a fast, robust multi-channel HSV and greyscale distribution profile from a PIL Image."""
    im_small = im.convert("RGB").resize((128, 128), Image.Resampling.BILINEAR)
    hsv = np.array(im_small.convert("HSV"), dtype=np.float32)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]

    # Filter out pure white studio backgrounds (v > 245 and s < 30) and deep pitch-black borders (v < 20)
    valid_mask = ~((v > 245) & (s < 30)) & (v > 20)
    if np.sum(valid_mask) < 100:
        valid_mask = np.ones((128, 128), dtype=bool)

    s_valid = s[valid_mask]
    v_valid = v[valid_mask]
    h_valid = h[valid_mask]

    chrom_mask = (s_valid > 35) & (v_valid > 30)
    chrom_count = int(np.sum(chrom_mask))
    total_valid = max(1, len(s_valid))
    chrom_ratio = float(chrom_count / total_valid)

    # 1. 12-bin 1D Hue histogram (0..256 in PIL HSV mapping)
    hue_hist = np.zeros(12, dtype=np.float32)
    if chrom_count >= 20:
        counts, _ = np.histogram(h_valid[chrom_mask], bins=12, range=(0, 256))
        hue_hist = counts.astype(np.float32) / float(chrom_count)

    # 2. 4-bin 1D Value histogram
    neutral_mask = ~chrom_mask
    val_hist = np.zeros(4, dtype=np.float32)
    neut_count = int(np.sum(neutral_mask))
    if neut_count >= 20:
        counts, _ = np.histogram(v_valid[neutral_mask], bins=4, range=(0, 256))
        val_hist = counts.astype(np.float32) / float(neut_count)
    else:
        counts, _ = np.histogram(v_valid, bins=4, range=(0, 256))
        val_hist = counts.astype(np.float32) / float(max(1, len(v_valid)))

    # 3. 16x4 (64-bin) 2D Joint Hue-Saturation distribution
    hue_sat_2d = np.zeros((16, 4), dtype=np.float32)
    if chrom_count >= 20:
        counts_2d, _, _ = np.histogram2d(
            h_valid[chrom_mask], s_valid[chrom_mask], bins=[16, 4], range=[[0, 256], [35, 256]]
        )
        hue_sat_2d = counts_2d.astype(np.float32) / float(chrom_count)

    # 4. 8-bin Greyscale / Luminance silhouette distribution
    gray = np.array(im_small.convert("L"), dtype=np.float32)
    gray_valid = gray[valid_mask]
    luma_profile = np.zeros(8, dtype=np.float32)
    if len(gray_valid) >= 20:
        counts_luma, _ = np.histogram(gray_valid, bins=8, range=(0, 256))
        luma_profile = counts_luma.astype(np.float32) / float(len(gray_valid))

    return ColorProfile(
        chromatic_ratio=chrom_ratio,
        hue_hist=hue_hist,
        val_hist=val_hist,
        hue_sat_2d=hue_sat_2d,
        luma_profile=luma_profile,
    )


def compare_color_profiles(
    p1: tuple[float, np.ndarray, np.ndarray] | ColorProfile | None,
    p2: tuple[float, np.ndarray, np.ndarray] | ColorProfile | None,
) -> float:
    """Compute histogram intersection similarity [0.0..1.0] between two color profiles."""
    if p1 is None or p2 is None:
        return 0.50

    cr1, h1, v1 = p1[0], p1[1], p1[2]
    cr2, h2, v2 = p2[0], p2[1], p2[2]

    both_chrom = (cr1 >= 0.08) and (cr2 >= 0.08)
    both_neut = (cr1 < 0.08) and (cr2 < 0.08)

    if both_chrom:
        hs2d_1 = getattr(p1, "hue_sat_2d", None)
        hs2d_2 = getattr(p2, "hue_sat_2d", None)
        if hs2d_1 is not None and hs2d_2 is not None:
            hs_sim = float(np.sum(np.minimum(hs2d_1, hs2d_2)))
            val_sim = float(np.sum(np.minimum(v1, v2)))
            return round(0.90 * hs_sim + 0.10 * val_sim, 4)

        hue_sim = float(np.sum(np.minimum(h1, h2)))
        val_sim = float(np.sum(np.minimum(v1, v2)))
        return round(0.90 * hue_sim + 0.10 * val_sim, 4)
    elif both_neut:
        val_sim = float(np.sum(np.minimum(v1, v2)))
        return round(val_sim, 4)
    else:
        hue_sim = float(np.sum(np.minimum(h1, h2)))
        val_sim = float(np.sum(np.minimum(v1, v2)))
        penalty = max(0.0, 1.0 - abs(cr1 - cr2))
        return round(max(0.0, min(1.0, 0.5 * hue_sim + 0.5 * val_sim * penalty * 0.5)), 4)


class VisionEmbedder:
    """Singleton engine managing MobileCLIP/DINOv2 ONNX CPU inference, perceptual dHash, and HSV color verification."""

    def __init__(self, model_path: Path | str | None = None) -> None:
        self.model_path = _resolve_model_path(model_path)
        self.is_dinov2: bool = "dinov2" in str(self.model_path).lower()
        self.session: Any = None
        self.input_name: str | None = None
        self.target_size: tuple[int, int] = (224, 224)
        self.is_onnx_ready: bool = False

        self._init_session()

    def _init_session(self) -> None:
        if ort is None:
            logger.info("onnxruntime not installed; operating in perceptual dHash mode.")
            return

        if not self.model_path.exists():
            logger.info("Vision ONNX model not found at %s; operating in perceptual dHash mode.", self.model_path)
            return

        if self.model_path.stat().st_size < 100_000:
            logger.info("Vision ONNX model at %s is stub/mock; operating in perceptual dHash mode.", self.model_path)
            return

        try:
            opts = ort.SessionOptions()
            opts.intra_op_num_threads = 1
            opts.inter_op_num_threads = 1
            opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

            self.session = ort.InferenceSession(
                str(self.model_path),
                sess_options=opts,
                providers=["CPUExecutionProvider"],
            )
            inputs = self.session.get_inputs()
            if inputs:
                self.input_name = inputs[0].name
                in_shape = inputs[0].shape
                if len(in_shape) == 4 and isinstance(in_shape[2], int) and isinstance(in_shape[3], int):
                    self.target_size = (in_shape[3], in_shape[2])
                else:
                    self.target_size = (224, 224)
                self.is_onnx_ready = True
                engine_name = "Meta DINOv2 Vision Transformer" if self.is_dinov2 else "MobileCLIP ONNX"
                logger.info("%s engine successfully initialized from %s.", engine_name, self.model_path)
        except Exception as ex:
            logger.warning("Failed initializing Vision ONNX session (%s); falling back to dHash.", ex)
            self.session = None
            self.is_onnx_ready = False

    def encode_image(
        self, image_input: Image.Image | str | bytes
    ) -> tuple[np.ndarray | None, int, ColorProfile | None]:
        """Encode an image into an L2-normalized embedding vector, 64-bit dHash, and ColorProfile."""
        batch_res = self.encode_images_batch([image_input])
        return batch_res[0] if batch_res else (None, 0, None)

    def encode_images_batch(
        self, image_inputs: list[Image.Image | str | bytes]
    ) -> list[tuple[np.ndarray | None, int, ColorProfile | None]]:
        """Encode a batch of images using vectorized SIMD inference in ONNXRuntime."""
        if not image_inputs:
            return []

        parsed_images: list[Image.Image | None] = []
        valid_indices: list[int] = []
        valid_tensors: list[np.ndarray] = []
        dhashes: list[int] = []
        color_profiles: list[ColorProfile | None] = []

        target_sz = getattr(self, "target_size", (224, 224))

        for idx, item in enumerate(image_inputs):
            im = parse_image_input(item)
            parsed_images.append(im)
            if im is not None:
                dh = compute_image_dhash(im)
                cp = compute_color_profile(im)
                dhashes.append(dh)
                color_profiles.append(cp)
                if self.is_onnx_ready and self.session is not None and self.input_name:
                    try:
                        tensor = preprocess_pil_image(im, target_size=target_sz, is_dinov2=self.is_dinov2)
                        valid_tensors.append(tensor)
                        valid_indices.append(idx)
                    except Exception as e:
                        logger.debug("Preprocessing failed for image %d: %s", idx, e)
            else:
                dhashes.append(0)
                color_profiles.append(None)

        batch_vectors: dict[int, np.ndarray] = {}
        if valid_tensors and self.is_onnx_ready and self.session is not None and self.input_name:
            try:
                stacked_tensor = np.concatenate(valid_tensors, axis=0)
                outputs = self.session.run(None, {self.input_name: stacked_tensor})
                raw_matrix = outputs[0]
                if self.is_dinov2 and len(raw_matrix.shape) == 3:
                    raw_matrix = raw_matrix[:, 0, :]
                norms = np.linalg.norm(raw_matrix, axis=1, keepdims=True)
                normalized_matrix = np.where(norms > 1e-6, raw_matrix / norms, raw_matrix)
                for i, orig_idx in enumerate(valid_indices):
                    batch_vectors[orig_idx] = normalized_matrix[i]
            except Exception as batch_err:
                logger.warning("Batch ONNX inference notice (%s); attempting serial fallbacks.", batch_err)
                for i, orig_idx in enumerate(valid_indices):
                    try:
                        out = self.session.run(None, {self.input_name: valid_tensors[i]})[0]
                        if self.is_dinov2 and len(out.shape) == 3:
                            out = out[0, 0, :]
                        elif len(out.shape) == 2:
                            out = out[0]
                        n = np.linalg.norm(out)
                        batch_vectors[orig_idx] = out / n if n > 1e-6 else out
                    except Exception:
                        pass

        results: list[tuple[np.ndarray | None, int, ColorProfile | None]] = []
        for idx in range(len(image_inputs)):
            vec = batch_vectors.get(idx)
            results.append((vec, dhashes[idx], color_profiles[idx]))

        return results

    def compute_similarity(
        self,
        vec_a: np.ndarray | None,
        dhash_a: int,
        vec_b: np.ndarray | None,
        dhash_b: int,
        color_a: ColorProfile | None = None,
        color_b: ColorProfile | None = None,
    ) -> float:
        """Compute hybrid similarity score blending ONNX semantic features, perceptual dHash, and HSV color."""
        # Tier 1: Perceptual exact stock duplicate (<1ms)
        if dhash_a and dhash_b:
            if hamming_distance(dhash_a, dhash_b) <= 2:
                return 1.0

        color_sim: float | None = None
        if color_a is not None and color_b is not None:
            color_sim = compare_color_profiles(color_a, color_b)

        # Tier 2: Semantic vector cosine similarity
        if vec_a is not None and vec_b is not None:
            dot = float(np.dot(vec_a, vec_b))
            sem_score = max(0.0, min(1.0, dot))
            if color_sim is not None:
                # Blend 80% semantic + 20% colorway
                return round(0.80 * sem_score + 0.20 * color_sim, 4)
            return round(sem_score, 4)

        # Fallback to normalized dHash + color similarity if ONNX not available
        if dhash_a and dhash_b:
            dist = hamming_distance(dhash_a, dhash_b)
            dhash_sim = max(0.0, 1.0 - (dist / 32.0))
            if color_sim is not None:
                return round(0.60 * dhash_sim + 0.40 * color_sim, 4)
            return round(dhash_sim, 4)

        return color_sim if color_sim is not None else 0.50

    def rerank_candidates(
        self,
        intake_image: Image.Image | str | bytes,
        candidates: list[dict[str, Any]],
        image_key: str = "img_src",
        min_similarity: float = 0.25,
    ) -> list[dict[str, Any]]:
        """Rerank a list of candidate items against the intake image."""
        ref_vec, ref_dhash, ref_color = self.encode_image(intake_image)
        if ref_dhash == 0 and ref_vec is None:
            logger.warning("Intake image could not be encoded.")
            return candidates

        cand_inputs = [c.get(image_key) or c.get("thumbnail") or "" for c in candidates]
        cand_encoded = self.encode_images_batch(cand_inputs)

        ranked: list[dict[str, Any]] = []
        for idx, c in enumerate(candidates):
            c_vec, c_dhash, c_color = cand_encoded[idx]
            if c_dhash == 0 and c_vec is None:
                continue

            sim = self.compute_similarity(ref_vec, ref_dhash, c_vec, c_dhash, ref_color, c_color)
            if sim >= min_similarity:
                item = dict(c)
                item["similarity"] = sim
                item["match_percentage"] = int(round(sim * 100))
                ranked.append(item)

        ranked.sort(key=lambda x: x.get("similarity", 0.0), reverse=True)
        return ranked


_DEFAULT_EMBEDDER: VisionEmbedder | None = None


def get_vision_embedder() -> VisionEmbedder:
    """Retrieve or lazily initialize the singleton VisionEmbedder engine."""
    global _DEFAULT_EMBEDDER
    if _DEFAULT_EMBEDDER is None:
        _DEFAULT_EMBEDDER = VisionEmbedder()
    return _DEFAULT_EMBEDDER
