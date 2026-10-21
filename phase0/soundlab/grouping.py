"""Similarity groups (UMAP + HDBSCAN), 2-D sound maps, neighbours and group names."""

from __future__ import annotations

import re
import warnings
from collections import Counter

import numpy as np

# Words the AI model scores each group against when naming it.
DESCRIPTORS = [
    "airy", "breathy", "windy", "swishy", "whooshing", "swooshing", "fluttering", "whipping",
    "fast", "slow", "short", "long", "sustained", "rising", "falling", "pass-by", "doppler",
    "deep", "low rumble", "sub bass", "high-pitched", "bright", "dark", "muffled", "thin", "full",
    "metallic", "ringing", "resonant", "glassy", "wooden", "cloth", "fabric", "paper", "plastic", "rubber",
    "watery", "splashy", "liquid", "fiery", "crackling", "electric", "buzzing", "humming", "static",
    "digital", "glitchy", "synthetic", "sci-fi", "futuristic", "laser", "magical", "sparkly", "shimmering",
    "ethereal", "eerie", "dark ambient", "cinematic", "trailer", "aggressive", "heavy", "light", "soft",
    "harsh", "gritty", "distorted", "noisy", "tonal", "musical", "reversed", "granular", "organic",
    "mechanical", "motor", "engine", "wind gust", "animal", "creature", "vocal", "human", "impact",
    "hit", "boom", "thud", "punchy", "click", "snap", "crunchy", "squeaky", "creaky", "explosive",
    "distant", "close-up", "roomy", "reverberant", "dry", "beep", "alarm", "tick",
]
STOPWORDS = set("""a an and the of in on at to for with by from as or is are be into over under up down out off
this that these those it its very more most some any each all no not one two three sfx fx sound sounds effect
effects designed version var variation take wav mono stereo audio file pack library vol volume""".split())


def reduce_for_clustering(X: np.ndarray, seed: int = 42) -> np.ndarray:
    n = len(X)
    if n < 30:
        from sklearn.decomposition import PCA

        k = max(2, min(10, n - 1))
        return PCA(n_components=k, random_state=seed).fit_transform(X)
    import umap

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return umap.UMAP(n_components=min(10, n - 2), n_neighbors=min(15, n - 1), min_dist=0.0,
                         metric="cosine", random_state=seed).fit_transform(X)


def cluster(X: np.ndarray, min_group_size: int = 5, fine: bool = False, seed: int = 42) -> np.ndarray:
    """Labels per row; -1 = didn't fit any group."""
    from sklearn.cluster import HDBSCAN

    n = len(X)
    if n < 2 * min_group_size:
        return np.zeros(n, dtype=int)
    Z = reduce_for_clustering(X, seed)
    hd = HDBSCAN(min_cluster_size=min_group_size, min_samples=max(2, min_group_size // 2),
                 cluster_selection_method="leaf" if fine else "eom", copy=True)
    labels = hd.fit_predict(Z)
    if labels.max() < 0:  # everything was noise: keep one group
        return np.zeros(n, dtype=int)
    return labels


def attach_leftovers(X: np.ndarray, labels: np.ndarray, min_similarity: float) -> np.ndarray:
    """Give ungrouped sounds to the nearest group centre if they are close enough."""
    labels = labels.copy()
    groups = [g for g in np.unique(labels) if g >= 0]
    if not groups:
        return labels
    centres = np.stack([X[labels == g].mean(axis=0) for g in groups])
    centres /= np.linalg.norm(centres, axis=1, keepdims=True) + 1e-12
    Xn = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-12)
    for i in np.nonzero(labels < 0)[0]:
        sims = centres @ Xn[i]
        j = int(np.argmax(sims))
        if sims[j] >= min_similarity:
            labels[i] = groups[j]
    return labels


def layout_2d(X: np.ndarray, seed: int = 42) -> np.ndarray:
    n = len(X)
    if n == 1:
        return np.zeros((1, 2))
    if n < 20:
        from sklearn.decomposition import PCA

        Y = PCA(n_components=2, random_state=seed).fit_transform(X) if n > 2 else np.c_[np.arange(n), np.zeros(n)]
    else:
        import umap

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            Y = umap.UMAP(n_components=2, n_neighbors=min(15, n - 1), min_dist=0.15, metric="cosine",
                          random_state=seed).fit_transform(X)
    Y = Y - Y.min(axis=0)
    span = Y.max(axis=0)
    span[span == 0] = 1
    return Y / span


def nearest_neighbours(X: np.ndarray, k: int = 8, block: int = 2048) -> tuple[np.ndarray, np.ndarray]:
    Xn = (X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-12)).astype(np.float32)
    k = min(k, len(X) - 1)
    if k <= 0:
        return np.zeros((len(X), 0), int), np.zeros((len(X), 0))
    idx = np.zeros((len(X), k), dtype=int)
    sim = np.zeros((len(X), k), dtype=np.float32)
    for s in range(0, len(X), block):
        S = Xn[s:s + block] @ Xn.T
        for r in range(S.shape[0]):
            S[r, s + r] = -np.inf
        part = np.argpartition(-S, k, axis=1)[:, :k]
        ps = np.take_along_axis(S, part, axis=1)
        order = np.argsort(-ps, axis=1)
        idx[s:s + block] = np.take_along_axis(part, order, axis=1)
        sim[s:s + block] = np.take_along_axis(ps, order, axis=1)
    return idx, sim


def tokens(text: str) -> list[str]:
    return [t for t in re.findall(r"[a-z][a-z\-]{2,}", (text or "").lower()) if t not in STOPWORDS]


def keyword_names(texts_per_group: dict[int, list[str]], top: int = 3,
                  exclude: set[str] = frozenset()) -> dict[int, list[str]]:
    """Distinctive words from vendor metadata per group (TF-IDF style).
    exclude: words to ignore, e.g. UCS CatIDs that appear in filenames."""
    df = Counter()
    tf = {}
    for g, texts in texts_per_group.items():
        c = Counter(t for txt in texts for t in set(tokens(txt)) if t not in exclude)
        tf[g] = c
        df.update(set(c))
    n_groups = max(1, len(texts_per_group))
    out = {}
    for g, c in tf.items():
        size = max(1, len(texts_per_group[g]))
        scored = [(cnt / size * np.log(1 + n_groups / df[w]), w) for w, cnt in c.items() if cnt / size >= 0.3]
        out[g] = [w for _, w in sorted(scored, reverse=True)[:top]]
    return out


def descriptor_names(centres: dict[int, np.ndarray], descriptor_vecs: np.ndarray, library_scores: np.ndarray,
                     top: int = 3) -> dict[int, list[str]]:
    """Words whose text embedding is closest to each group's centre, measured
    against the other groups in the same category and the whole library, so
    groups get words that set them apart rather than the same generic word.

    library_scores: mean word scores over every analysed sound."""
    groups = list(centres)
    if not groups:
        return {}
    C = np.stack([centres[g] / (np.linalg.norm(centres[g]) + 1e-12) for g in groups])
    S = C @ descriptor_vecs.T
    bucket_mean = S.mean(axis=0, keepdims=True)
    S = S - 0.6 * bucket_mean - 0.3 * library_scores[None, :]
    out = {}
    for i, g in enumerate(groups):
        order = np.argsort(-S[i])[:top]
        out[g] = [DESCRIPTORS[j] for j in order]
    return out
