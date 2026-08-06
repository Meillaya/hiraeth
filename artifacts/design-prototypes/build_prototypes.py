#!/usr/bin/env python3
"""Build three self-contained full-site design prototypes from the real catalog corpus.

Directions: gallery (museum-wall calm), ledger (archive-index density),
night-reading (dark-first warm reading room). Python stdlib only, deterministic:
no timestamps, no unseeded randomness, stable file ordering. Idempotent: files
whose content is already current are left untouched.

Inputs (read-only):
  priv/catalog_sources/real_publishers/*.json  - real publisher datasets
  priv/static/covers/cache/                    - local cover cache (<sha256>.<ext> + <sha256>-thumb.jpg)
  priv/static/fonts/                           - self-hosted OFL woff2 fonts

Outputs (all under artifacts/design-prototypes/):
  {gallery,ledger,night-reading}/{index,browse,book,publishers}.html + styles.css + fonts/ + covers/
  manifest.json
"""

from __future__ import annotations

import hashlib
import html
import json
import posixpath
import re
import shutil
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
DATASET_DIR = ROOT / "priv" / "catalog_sources" / "real_publishers"
COVER_CACHE = ROOT / "priv" / "static" / "covers" / "cache"
FONT_DIR = ROOT / "priv" / "static" / "fonts"
OUT_DIR = Path(__file__).resolve().parent

NON_DATASET_FILES = {
    "schema.json",
    "source_artifacts_manifest.json",
    "source_authority_manifest.json",
    "source_coverage_report.json",
}
KNOWN_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp", ".gif")
SAMPLE_SIZE = 21          # covered volumes, round-robin across providers
FALLBACK_SAMPLE_SIZE = 3  # volumes without a cached cover (typographic fallback)
DESCRIPTION_EXCERPT = 480
DESCRIPTION_DETAIL = 980

FONTS = {
    "newsreader-variable-normal.woff2": ("Newsreader", "normal", "200 800"),
    "newsreader-variable-italic.woff2": ("Newsreader", "italic", "200 800"),
    "space-mono-400-normal.woff2": ("Space Mono", "normal", "400"),
    "space-mono-400-italic.woff2": ("Space Mono", "italic", "400"),
    "space-mono-700-normal.woff2": ("Space Mono", "normal", "700"),
}

NAV = (
    ("Browse", "browse.html"),
    ("Search", "browse.html#catalog-search"),
    ("Publishers", "publishers.html"),
    ("Series", "browse.html#filters"),
    ("Contributors", "browse.html#filters"),
)


# ---------------------------------------------------------------------------
# Data loading and deterministic sampling
# ---------------------------------------------------------------------------

def cover_cache_names(source_url: str) -> tuple[str, str]:
    """Mirror Hiraeth.Ingestion.CoverPipeline: sha256(source_url) + URL-path extension."""
    digest = hashlib.sha256(source_url.encode("utf-8")).hexdigest()
    ext = posixpath.splitext(urlparse(source_url).path)[1].lower()
    if ext not in KNOWN_EXTENSIONS:
        ext = ".jpg"
    return f"{digest}{ext}", f"{digest}-thumb.jpg"


def resolve_cover_file(full_name: str) -> str | None:
    """Return the cache filename that actually exists for a hash, if any."""
    stem = full_name.rsplit(".", 1)[0]
    if (COVER_CACHE / full_name).is_file():
        return full_name
    for ext in KNOWN_EXTENSIONS:
        candidate = f"{stem}{ext}"
        if (COVER_CACHE / candidate).is_file():
            return candidate
    return None


BLOCK_TAGS = r"</?(?:p|div|br|li|ul|ol|h[1-6]|blockquote|section|article|tr|td|th|table|hr|figure|figcaption|dd|dt|dl|pre)\b[^>]*>"


def plain_text(value: str) -> str:
    text = re.sub(BLOCK_TAGS, " ", value, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\s+([,.;:!?])", r"\1", text)


def excerpt(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text.rfind(" ", 0, limit)
    if cut < limit // 2:
        cut = limit
    return text[:cut].rstrip(" ,;:") + " …"


def load_datasets() -> tuple[list[dict], dict[str, int]]:
    """Load all datasets; corpus counts are keyed by display publisher name."""
    datasets: list[dict] = []
    corpus_counts: dict[str, int] = {}
    for path in sorted(DATASET_DIR.glob("*.json")):
        if path.name in NON_DATASET_FILES:
            continue
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
        records = payload.get("records", [])
        for record in records:
            publisher = record.get("publisher") or "Publisher unknown"
            corpus_counts[publisher] = corpus_counts.get(publisher, 0) + 1
        datasets.append({"file": path.name, "provider": payload.get("provider", path.stem), "records": records})
    return datasets, corpus_counts


def normalize_record(record: dict, dataset_file: str, provider: str) -> dict:
    work = record.get("work") or {}
    edition = record.get("edition") or {}
    contributors = record.get("contributors") or []
    authors = [c["name"] for c in contributors if c.get("role") == "author"]
    translators = [c["name"] for c in contributors if c.get("role") == "translator"]
    editors = [c["name"] for c in contributors if c.get("role") == "editor"]
    published_on = edition.get("published_on")
    year = published_on[:4] if published_on else None
    description = record.get("description") or record.get("synopsis") or ""
    cover = record.get("cover") or {}
    source_url = cover.get("source_url")
    cover_full = cover_thumb = None
    if source_url:
        full_name, thumb_name = cover_cache_names(source_url)
        found = resolve_cover_file(full_name)
        if found:
            cover_full = found
            if (COVER_CACHE / thumb_name).is_file():
                cover_thumb = thumb_name
    praise = [
        {"quote": plain_text(item.get("quote", "")), "source": item.get("source", "")}
        for item in record.get("editorial_praise") or []
        if item.get("quote")
    ]
    series = [item.get("title") for item in record.get("series") or [] if item.get("title")]
    return {
        "title": work.get("title") or edition.get("title") or "Untitled",
        "subtitle": work.get("subtitle"),
        "authors": authors,
        "translators": translators,
        "editors": editors,
        "contributor_roles": sorted({c.get("role", "contributor") for c in contributors}),
        "publisher": record.get("publisher") or "Publisher unknown",
        "imprint": record.get("imprint"),
        "year": year,
        "published_on": published_on,
        "format": edition.get("format") or "paperback",
        "isbn": edition.get("isbn_13"),
        "page_count": edition.get("page_count"),
        "language_code": edition.get("language_code"),
        "original_language_code": work.get("original_language_code"),
        "subjects": work.get("subjects") or [],
        "description": plain_text(description),
        "cover_full": cover_full,
        "cover_thumb": cover_thumb,
        "praise": praise,
        "series": series,
        "dataset": dataset_file,
        "provider": provider,
    }


def sample_books(datasets: list[dict]) -> list[dict]:
    """Round-robin across providers for diversity; deterministic file/index order."""
    covered_by_provider: dict[str, list[dict]] = {}
    fallback_pool: list[dict] = []
    for dataset in datasets:
        bucket = covered_by_provider.setdefault(dataset["provider"], [])
        for record in dataset["records"]:
            book = normalize_record(record, dataset["file"], dataset["provider"])
            if not book["description"]:
                continue
            if book["cover_full"]:
                bucket.append(book)
            elif "cover" not in record:
                fallback_pool.append(book)
    selection: list[dict] = []
    providers = sorted(covered_by_provider)
    cursors = {provider: 0 for provider in providers}
    while len(selection) < SAMPLE_SIZE:
        progressed = False
        for provider in providers:
            if len(selection) >= SAMPLE_SIZE:
                break
            bucket = covered_by_provider[provider]
            cursor = cursors[provider]
            if cursor < len(bucket):
                selection.append(bucket[cursor])
                cursors[provider] = cursor + 1
                progressed = True
        if not progressed:
            break
    selection.extend(fallback_pool[:FALLBACK_SAMPLE_SIZE])
    return selection


# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------

def esc(value: object) -> str:
    return html.escape(str(value if value is not None else ""), quote=True)


def byline(book: dict) -> str:
    return ", ".join(book["authors"]) if book["authors"] else "Contributors uncredited"


def contributor_line(book: dict) -> str:
    parts = []
    if book["authors"]:
        parts.append("by " + ", ".join(book["authors"]))
    if book["translators"]:
        parts.append("translated by " + ", ".join(book["translators"]))
    if book["editors"]:
        parts.append("edited by " + ", ".join(book["editors"]))
    return " ".join(parts)


def year_label(book: dict) -> str:
    return book["year"] or "n.d."


def nav_links(active: str) -> str:
    items = []
    for label, href in NAV:
        cls = "nav-link is-active" if label == active else "nav-link"
        aria = ' aria-current="page"' if label == active else ""
        items.append(f'<a class="{cls}" href="{href}"{aria}>{label}</a>')
    return "\n".join(items)


def fallback_cover(book: dict, size: str = "card") -> str:
    """Typographic fallback cover: grain texture, mono publisher line, serif title, italic byline."""
    series_slot = (book["series"][:1] or ["Edition"])[0]
    return f"""<div class="fallback-cover fb-{size}" role="img" aria-label="Typographic cover placeholder for {esc(book['title'])}">
  <span class="fb-grain" aria-hidden="true"></span>
  <p class="fb-publisher">{esc(book['publisher'])}</p>
  <div class="fb-body">
    <span class="fb-rule" aria-hidden="true"></span>
    <p class="fb-title">{esc(book['title'])}</p>
    <p class="fb-byline">{esc(byline(book))}</p>
  </div>
  <div class="fb-foot">
    <span class="fb-series">{esc(series_slot)}</span>
    <span class="fb-year">{esc(year_label(book))}</span>
  </div>
</div>"""


def cover_figure(book: dict, variant: str, eager: bool = False) -> str:
    """Render a real cached cover image, or the typographic fallback when absent."""
    if variant == "hero":
        src_name = book["cover_full"]
    else:
        src_name = book["cover_thumb"] or book["cover_full"]
    if not src_name:
        return fallback_cover(book, "hero" if variant == "hero" else "card")
    loading = "eager" if eager else "lazy"
    return f"""<img class="cover-img cover-{variant}" src="covers/{src_name}" alt="Cover of {esc(book['title'])}" width="400" height="600" loading="{loading}" decoding="async">"""


def format_counts(books: list[dict]) -> list[tuple[str, int]]:
    counts: dict[str, int] = {}
    for book in books:
        counts[book["format"]] = counts.get(book["format"], 0) + 1
    return sorted(counts.items())


def publisher_counts(books: list[dict]) -> list[tuple[str, int]]:
    counts: dict[str, int] = {}
    for book in books:
        counts[book["publisher"]] = counts.get(book["publisher"], 0) + 1
    return sorted(counts.items())


def role_counts(books: list[dict]) -> list[tuple[str, int]]:
    counts: dict[str, int] = {}
    for book in books:
        for role in book["contributor_roles"]:
            counts[role] = counts.get(role, 0) + 1
    return sorted(counts.items())


def chip_row(books: list[dict]) -> str:
    chips = []
    for fmt, count in format_counts(books):
        chips.append(f'<span class="chip"><span class="chip-name">{esc(fmt)}</span><span class="chip-count">{count}</span></span>')
    translated = sum(1 for book in books if book["translators"])
    if translated:
        chips.append(f'<span class="chip"><span class="chip-name">in translation</span><span class="chip-count">{translated}</span></span>')
    for publisher, count in publisher_counts(books)[:8]:
        chips.append(f'<span class="chip"><span class="chip-name">{esc(publisher)}</span><span class="chip-count">{count}</span></span>')
    series_titles = []
    for book in books:
        for title in book["series"]:
            if title not in series_titles:
                series_titles.append(title)
    for title in series_titles[:4]:
        chips.append(f'<span class="chip chip-series"><span class="chip-name">{esc(title)}</span></span>')
    for role, count in role_counts(books):
        chips.append(f'<span class="chip chip-role"><span class="chip-name">{esc(role)}</span><span class="chip-count">{count}</span></span>')
    return "\n".join(chips)


def footer(direction_name: str) -> str:
    nav_cols = "\n".join(
        f'<a class="footer-link" href="{href}">{label}</a>' for label, href in NAV
    )
    return f"""<footer class="site-footer">
  <div class="container footer-grid">
    <div class="footer-brand">
      <p class="footer-wordmark">Hiraeth</p>
      <p class="footer-tagline">A quiet editorial archive of independent publishers.</p>
    </div>
    <nav class="footer-nav" aria-label="Footer navigation">
      <p class="footer-heading">Catalog</p>
      {nav_cols}
    </nav>
    <div class="footer-colophon">
      <p class="footer-heading">Colophon</p>
      <p class="footer-note">Set in Newsreader and Space Mono. Covers render from the local cache; volumes without a cached cover keep a typographic stand-in.</p>
      <p class="footer-note">Design prototype — {esc(direction_name)} direction. Real catalog data; navigation is illustrative.</p>
    </div>
  </div>
  <div class="container footer-legal">
    <p>© Hiraeth Project. All rights reserved.</p>
  </div>
</footer>"""


def page_shell(
    direction: str,
    direction_name: str,
    page: str,
    title_suffix: str,
    body: str,
    masthead_extra: str = "",
) -> str:
    active = {"index": "", "browse": "Browse", "book": "Browse", "publishers": "Publishers"}[page]
    mobile_links = "\n".join(
        f'<a class="nav-link" href="{href}">{label}</a>' for label, href in NAV
    )
    return f"""<!doctype html>
<html lang="en" data-direction="{direction}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title_suffix)} · Hiraeth — {esc(direction_name)} prototype</title>
<link rel="stylesheet" href="styles.css">
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>
<p class="proto-strip"><span class="container proto-strip-inner">Design prototype · {esc(direction_name)} direction · real catalog data</span></p>
<header class="masthead">
  <div class="container masthead-inner">
    <a class="wordmark" href="index.html">Hiraeth</a>
    <nav class="site-nav" aria-label="Primary navigation">
{nav_links(active)}
    </nav>
    {masthead_extra}
    <details class="mobile-menu">
      <summary aria-label="Open menu">Menu</summary>
      <div class="mobile-menu-panel">
        <a class="nav-link" href="index.html">Home</a>
        {mobile_links}
      </div>
    </details>
  </div>
</header>
<main id="main">
{body}
</main>
{footer(direction_name)}
</body>
</html>
"""


# ---------------------------------------------------------------------------
# GALLERY — museum-wall calm
# ---------------------------------------------------------------------------

GALLERY_CSS = """/* GALLERY — museum-wall calm. Paper, ink, hairline rules, oversized Newsreader. */

@font-face {
  font-family: "Newsreader";
  font-style: normal;
  font-weight: 200 800;
  font-display: swap;
  src: url("fonts/newsreader-variable-normal.woff2") format("woff2");
}
@font-face {
  font-family: "Newsreader";
  font-style: italic;
  font-weight: 200 800;
  font-display: swap;
  src: url("fonts/newsreader-variable-italic.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url("fonts/space-mono-400-normal.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url("fonts/space-mono-700-normal.woff2") format("woff2");
}

:root {
  --paper: #FBFAF7;
  --paper-raise: #FFFFFF;
  --ink: #1B1714;
  --ink-2: rgba(27, 23, 20, 0.64);
  --ink-3: rgba(27, 23, 20, 0.42);
  --line: rgba(27, 23, 20, 0.14);
  --line-strong: rgba(27, 23, 20, 0.3);
  --thread: #A33417;
  --radius: 2px;
  --shadow-card: 0 1px 2px rgba(27, 23, 20, 0.06), 0 10px 24px -18px rgba(27, 23, 20, 0.28);
  --shadow-lift: 0 2px 4px rgba(27, 23, 20, 0.08), 0 24px 44px -20px rgba(27, 23, 20, 0.38);
  --shadow-hero: 0 40px 80px -36px rgba(27, 23, 20, 0.45);
  --serif: "Newsreader", "Iowan Old Style", Georgia, serif;
  --mono: "Space Mono", "SFMono-Regular", Menlo, monospace;
  --measure: 1180px;
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background: var(--paper);
  color: var(--ink);
  font-family: var(--serif);
  font-size: 17px;
  line-height: 1.65;
  -webkit-font-smoothing: antialiased;
}
img { display: block; max-width: 100%; }
a { color: inherit; }

.container { max-width: var(--measure); margin-inline: auto; padding-inline: clamp(20px, 4vw, 48px); }

.skip-link {
  position: absolute; left: -9999px; top: 0;
  background: var(--ink); color: var(--paper);
  font-family: var(--mono); font-size: 12px; letter-spacing: 0.18em; text-transform: uppercase;
  padding: 10px 18px; text-decoration: none; z-index: 60;
}
.skip-link:focus { left: 12px; top: 12px; }

:focus-visible { outline: 2px solid var(--thread); outline-offset: 3px; border-radius: var(--radius); }

.proto-strip { margin: 0; background: var(--ink); color: rgba(251, 250, 247, 0.72); }
.proto-strip-inner {
  display: block; padding: 6px clamp(20px, 4vw, 48px);
  font-family: var(--mono); font-size: 10px; letter-spacing: 0.18em; text-transform: uppercase;
}

/* Masthead */
.masthead {
  position: sticky; top: 0; z-index: 50;
  background: color-mix(in srgb, var(--paper) 92%, transparent);
  backdrop-filter: blur(8px);
  border-bottom: 1px solid var(--line);
}
.masthead-inner { display: flex; align-items: center; gap: 36px; min-height: 64px; }
.wordmark {
  font-family: var(--serif); font-size: 24px; font-weight: 480; letter-spacing: 0.01em;
  text-decoration: none; color: var(--ink);
}
.site-nav { display: flex; gap: 28px; margin-left: auto; }
.nav-link {
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase;
  color: var(--ink-2); text-decoration: none; padding: 6px 0;
  border-bottom: 1px solid transparent;
  transition: color 180ms ease, border-color 180ms ease;
}
.nav-link:hover { color: var(--ink); border-bottom-color: var(--line-strong); }
.nav-link.is-active { color: var(--thread); border-bottom-color: var(--thread); }
.mobile-menu { display: none; margin-left: auto; position: relative; }
.mobile-menu summary {
  list-style: none; cursor: pointer;
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase;
  color: var(--ink); padding: 8px 0;
}
.mobile-menu summary::-webkit-details-marker { display: none; }
.mobile-menu-panel {
  position: absolute; right: 0; top: calc(100% + 14px);
  display: flex; flex-direction: column; gap: 4px;
  background: var(--paper-raise); border: 1px solid var(--line);
  box-shadow: var(--shadow-lift); padding: 14px 18px; min-width: 200px; border-radius: var(--radius);
}
.mobile-menu-panel .nav-link { padding: 8px 0; }

/* Typography */
.kicker {
  font-family: var(--mono); font-size: 11px; font-weight: 400;
  letter-spacing: 0.18em; text-transform: uppercase; color: var(--ink-2);
  margin: 0 0 18px;
}
.kicker-thread { color: var(--thread); }
.display {
  font-family: var(--serif);
  font-size: clamp(3rem, 2.1rem + 3.4vw, 6rem);
  font-weight: 300; line-height: 1.04; letter-spacing: -0.015em;
  margin: 0 0 28px; max-width: 16ch;
}
.display em { font-style: italic; font-weight: 340; color: var(--thread); }
.section-head { display: flex; align-items: baseline; justify-content: space-between; gap: 24px; margin-bottom: 34px; }
.section-title { font-size: 1.9rem; font-weight: 420; letter-spacing: -0.01em; margin: 0; }
.section-note { font-family: var(--mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-3); }
.rule { border: 0; border-top: 1px solid var(--line); margin: 0; }

/* Home hero */
.hero { padding: clamp(56px, 9vw, 120px) 0 clamp(48px, 7vw, 88px); border-bottom: 1px solid var(--line); }
.hero-lede { font-size: 1.2rem; font-style: italic; color: var(--ink-2); max-width: 52ch; margin: 0; }

/* Spotlight */
.spotlight { display: grid; grid-template-columns: minmax(260px, 420px) 1fr; gap: clamp(36px, 6vw, 84px); padding: clamp(48px, 7vw, 88px) 0; border-bottom: 1px solid var(--line); align-items: start; }
.spotlight-cover { position: relative; }
.spotlight-cover .cover-img, .spotlight-cover .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover;
  border-radius: var(--radius); box-shadow: var(--shadow-hero);
}
.spotlight-title { font-size: clamp(1.9rem, 1.4rem + 1.8vw, 3rem); font-weight: 400; line-height: 1.12; letter-spacing: -0.01em; margin: 0 0 14px; }
.spotlight-byline { font-size: 1.1rem; font-style: italic; color: var(--ink-2); margin: 0 0 26px; }
.spotlight-excerpt { max-width: 58ch; color: var(--ink-2); margin: 0 0 30px; }
.spotlight-meta { font-family: var(--mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-3); margin: 0 0 34px; }

.text-link {
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase;
  color: var(--thread); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--thread) 40%, transparent);
  padding-bottom: 4px; transition: border-color 180ms ease;
}
.text-link:hover { border-bottom-color: var(--thread); }

/* Cover grid */
.grid-section { padding: clamp(48px, 7vw, 88px) 0; }
.cover-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(196px, 1fr)); gap: 44px 28px; }
.book-card { margin: 0; }
.book-card a { text-decoration: none; display: block; }
.book-card .cover-img, .book-card .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover;
  border-radius: var(--radius); box-shadow: var(--shadow-card);
  transition: transform 300ms ease, box-shadow 300ms ease;
}
.book-card a:hover .cover-img, .book-card a:hover .fallback-cover,
.book-card a:focus-visible .cover-img, .book-card a:focus-visible .fallback-cover {
  transform: translateY(-6px); box-shadow: var(--shadow-lift);
}
.card-caption { padding-top: 16px; }
.card-title { font-size: 1.04rem; font-weight: 500; line-height: 1.3; margin: 0 0 6px; color: var(--ink); }
.card-meta { font-family: var(--mono); font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-3); margin: 0; }

/* Typographic fallback cover */
.fallback-cover {
  position: relative; display: flex; flex-direction: column; justify-content: space-between;
  padding: 18px; overflow: hidden; user-select: none;
  background: var(--paper-raise); color: var(--ink);
  border: 1px solid var(--line);
}
.fb-grain {
  position: absolute; inset: 0; pointer-events: none; opacity: 0.5;
  background-image: radial-gradient(rgba(27, 23, 20, 0.05) 1px, transparent 1px);
  background-size: 3px 3px;
}
.fb-grain::after {
  content: ""; position: absolute; inset: 0;
  background: radial-gradient(120% 60% at 50% 0%, rgba(224, 164, 88, 0.1), transparent 60%);
}
.fb-publisher { position: relative; margin: 0; text-align: center; font-family: var(--mono); font-size: 9px; letter-spacing: 0.22em; text-transform: uppercase; opacity: 0.8; }
.fb-body { position: relative; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 10px; padding: 12px 6px; }
.fb-rule { width: 42px; height: 1px; background: color-mix(in srgb, currentColor 24%, transparent); }
.fb-title { margin: 0; font-family: var(--serif); font-size: 1.24rem; font-weight: 500; line-height: 1.25; letter-spacing: -0.01em; }
.fb-byline { margin: 0; font-family: var(--serif); font-style: italic; font-size: 0.82rem; opacity: 0.85; }
.fb-foot { position: relative; display: flex; justify-content: space-between; gap: 8px; border-top: 1px solid color-mix(in srgb, currentColor 25%, transparent); padding-top: 10px; font-family: var(--mono); font-size: 8px; letter-spacing: 0.16em; text-transform: uppercase; opacity: 0.72; }
.fb-series { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Browse */
.browse-masthead { padding: clamp(44px, 6vw, 72px) 0 34px; border-bottom: 1px solid var(--line); }
.browse-title { font-size: clamp(2.2rem, 1.6rem + 2vw, 3.6rem); font-weight: 320; letter-spacing: -0.012em; margin: 0 0 12px; }
.browse-sub { color: var(--ink-2); font-style: italic; margin: 0; }
.search-block { padding: 34px 0 8px; }
.search-label { font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--ink-2); display: block; margin-bottom: 10px; }
.search-input {
  width: 100%; max-width: 640px; background: transparent; border: 0;
  border-bottom: 1px solid var(--line-strong); border-radius: 0;
  font-family: var(--serif); font-size: 1.4rem; color: var(--ink);
  padding: 10px 2px 14px; transition: border-color 200ms ease;
}
.search-input::placeholder { color: var(--ink-3); font-style: italic; }
.search-input:focus { outline: none; border-bottom-color: var(--thread); }
.filter-block { padding: 26px 0 8px; }
.chips { display: flex; flex-wrap: wrap; gap: 10px; }
.chip {
  display: inline-flex; align-items: baseline; gap: 8px;
  border: 1px solid var(--line); border-radius: var(--radius);
  padding: 7px 12px; background: transparent;
  font-family: var(--mono); font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-2);
  transition: border-color 180ms ease, color 180ms ease;
}
.chip:hover { border-color: var(--line-strong); color: var(--ink); }
.chip-count { color: var(--ink-3); }
.chip-series { border-color: color-mix(in srgb, var(--thread) 35%, transparent); color: var(--thread); }
.browse-grid-wrap { padding: 40px 0 clamp(56px, 7vw, 96px); }

/* Book detail */
.book-detail { display: grid; grid-template-columns: minmax(260px, 430px) 1fr; gap: clamp(36px, 6vw, 84px); padding: clamp(48px, 7vw, 88px) 0; align-items: start; }
.book-cover-aside { position: sticky; top: 96px; }
.book-cover-aside .cover-img, .book-cover-aside .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover; border-radius: var(--radius); box-shadow: var(--shadow-hero);
}
.book-title { font-size: clamp(2.1rem, 1.6rem + 2vw, 3.4rem); font-weight: 400; line-height: 1.1; letter-spacing: -0.012em; margin: 0 0 14px; }
.book-byline { font-size: 1.15rem; font-style: italic; color: var(--ink-2); margin: 0 0 30px; }
.book-description { max-width: 62ch; font-size: 1.06rem; color: var(--ink); margin: 0 0 40px; }
.praise { border-left: 1px solid var(--thread); padding-left: 26px; margin: 0 0 44px; max-width: 56ch; }
.praise-quote { font-size: 1.3rem; font-style: italic; line-height: 1.5; margin: 0 0 10px; }
.praise-source { font-family: var(--mono); font-size: 10px; letter-spacing: 0.16em; text-transform: uppercase; color: var(--ink-3); margin: 0; }
.biblio { border-top: 1px solid var(--line); margin: 0 0 44px; max-width: 640px; }
.biblio-row { display: grid; grid-template-columns: 160px 1fr; gap: 20px; padding: 13px 0; border-bottom: 1px solid var(--line); }
.biblio dt { font-family: var(--mono); font-size: 10px; letter-spacing: 0.16em; text-transform: uppercase; color: var(--ink-3); margin: 0; padding-top: 3px; }
.biblio dd { margin: 0; font-size: 1rem; }
.subject-list { display: flex; flex-wrap: wrap; gap: 8px; list-style: none; margin: 0; padding: 0; }
.subject-list li { font-family: var(--mono); font-size: 10px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--ink-2); border: 1px solid var(--line); border-radius: var(--radius); padding: 4px 9px; }
.button {
  display: inline-block; background: var(--ink); color: var(--paper);
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase;
  text-decoration: none; padding: 14px 24px; border-radius: var(--radius);
  transition: background 200ms ease, transform 200ms ease;
}
.button:hover { background: var(--thread); transform: translateY(-1px); }
.button-ghost { background: transparent; color: var(--ink); border: 1px solid var(--line-strong); }
.button-ghost:hover { background: transparent; color: var(--thread); border-color: var(--thread); }

/* Publishers */
.publisher-list { padding: clamp(40px, 6vw, 72px) 0; }
.publisher-row {
  display: grid; grid-template-columns: 1fr auto; gap: 12px 32px; align-items: baseline;
  padding: 26px 8px; border-top: 1px solid var(--line); text-decoration: none; color: inherit;
  transition: background 200ms ease, padding-left 200ms ease;
}
.publisher-row:last-child { border-bottom: 1px solid var(--line); }
.publisher-row:hover { background: color-mix(in srgb, var(--paper-raise) 70%, transparent); padding-left: 16px; }
.publisher-name { font-size: 1.5rem; font-weight: 440; letter-spacing: -0.01em; margin: 0; }
.publisher-sample { grid-column: 1; font-style: italic; color: var(--ink-2); margin: 0; font-size: 0.98rem; }
.publisher-count { font-family: var(--mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-3); grid-row: 1; }
.publisher-count strong { color: var(--thread); font-weight: 700; }

/* Footer */
.site-footer { border-top: 1px solid var(--line); margin-top: clamp(48px, 6vw, 80px); padding-top: clamp(40px, 5vw, 64px); }
.footer-grid { display: grid; grid-template-columns: 1.4fr 0.8fr 1.4fr; gap: 40px; padding-bottom: 44px; }
.footer-wordmark { font-size: 1.5rem; font-weight: 480; margin: 0 0 10px; }
.footer-tagline { font-style: italic; color: var(--ink-2); margin: 0; max-width: 30ch; }
.footer-heading { font-family: var(--mono); font-size: 10px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--ink-3); margin: 0 0 14px; }
.footer-nav { display: flex; flex-direction: column; gap: 8px; }
.footer-link { font-family: var(--mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-2); text-decoration: none; width: fit-content; }
.footer-link:hover { color: var(--thread); }
.footer-note { color: var(--ink-2); font-size: 0.92rem; margin: 0 0 10px; max-width: 46ch; }
.footer-legal { border-top: 1px solid var(--line); padding-block: 20px; font-family: var(--mono); font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-3); }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition-duration: 0.01ms !important; }
  html { scroll-behavior: auto; }
}

@media (max-width: 900px) {
  .spotlight, .book-detail { grid-template-columns: 1fr; }
  .book-cover-aside { position: static; max-width: 340px; }
  .spotlight-cover { max-width: 340px; }
  .footer-grid { grid-template-columns: 1fr; gap: 32px; }
}
@media (max-width: 720px) {
  .site-nav { display: none; }
  .mobile-menu { display: block; }
}
@media (max-width: 390px) {
  body { font-size: 16px; }
  .cover-grid { grid-template-columns: repeat(2, 1fr); gap: 28px 16px; }
  .display { font-size: 2.6rem; }
  .masthead-inner { gap: 16px; }
  .publisher-row { grid-template-columns: 1fr; }
  .publisher-count { grid-row: auto; }
  .biblio-row { grid-template-columns: 1fr; gap: 4px; }
}
"""


def gallery_card(book: dict) -> str:
    return f"""<figure class="book-card">
  <a href="book.html">
    {cover_figure(book, "card")}
    <figcaption class="card-caption">
      <p class="card-title">{esc(book['title'])}</p>
      <p class="card-meta">{esc(book['publisher'])} · {esc(year_label(book))}</p>
    </figcaption>
  </a>
</figure>"""


def gallery_pages(ctx: dict) -> dict[str, str]:
    spotlight = ctx["spotlight"]
    books = ctx["books"]
    fallback_books = [book for book in books if not book["cover_full"]]
    recent = books[: 12 - len(fallback_books)] + fallback_books

    index_body = f"""<section class="hero">
  <div class="container">
    <p class="kicker kicker-thread">Independent publishing, catalogued</p>
    <h1 class="display">A quiet editorial archive of <em>independent publishers</em>.</h1>
    <p class="hero-lede">{ctx['corpus_total']:,} source records from {len(ctx['corpus_counts'])} approved presses — every volume traceable to its publisher, every cover shown from the local cache.</p>
  </div>
</section>
<section class="spotlight container">
  <div class="spotlight-cover">{cover_figure(spotlight, "hero", eager=True)}</div>
  <div class="spotlight-body">
    <p class="kicker kicker-thread">Spotlight volume — {esc(spotlight['publisher'])}</p>
    <h2 class="spotlight-title">{esc(spotlight['title'])}</h2>
    <p class="spotlight-byline">{esc(contributor_line(spotlight))}</p>
    <p class="spotlight-excerpt">{esc(excerpt(spotlight['description'], DESCRIPTION_EXCERPT))}</p>
    <p class="spotlight-meta">{esc(spotlight['format'])} · {esc(year_label(spotlight))}</p>
    <a class="text-link" href="book.html">Open the volume</a>
  </div>
</section>
<section class="grid-section">
  <div class="container">
    <div class="section-head">
      <h2 class="section-title">Recently imported</h2>
      <p class="section-note">{len(recent)} of {len(books)} sampled volumes</p>
    </div>
    <div class="cover-grid">
{chr(10).join(gallery_card(book) for book in recent)}
    </div>
  </div>
</section>"""

    browse_body = f"""<section class="browse-masthead container">
  <p class="kicker">Catalog index</p>
  <h1 class="browse-title">Browse the collection</h1>
  <p class="browse-sub">{len(books)} volumes sampled from {ctx['corpus_total']:,} records across {len(ctx['corpus_counts'])} independent presses.</p>
</section>
<div class="container">
  <div class="search-block" id="catalog-search">
    <label class="search-label" for="q">Search the catalog</label>
    <input class="search-input" id="q" type="search" placeholder="Titles, authors, translators, publishers" autocomplete="off">
  </div>
  <div class="filter-block" id="filters">
    <div class="chips">
{chip_row(books)}
    </div>
  </div>
</div>
<section class="browse-grid-wrap">
  <div class="container">
    <div class="cover-grid">
{chr(10).join(gallery_card(book) for book in books)}
    </div>
  </div>
</section>"""

    book_body = gallery_book_body(spotlight)
    publishers_body = gallery_publishers_body(ctx)

    return {
        "index.html": page_shell("gallery", "Gallery", "index", "Home", index_body),
        "browse.html": page_shell("gallery", "Gallery", "browse", "Browse", browse_body),
        "book.html": page_shell("gallery", "Gallery", "book", spotlight["title"], book_body),
        "publishers.html": page_shell("gallery", "Gallery", "publishers", "Publishers", publishers_body),
    }


def gallery_book_body(book: dict) -> str:
    praise_html = ""
    if book["praise"]:
        first = book["praise"][0]
        praise_html = f"""<blockquote class="praise">
  <p class="praise-quote">“{esc(first['quote'])}”</p>
  <p class="praise-source">— {esc(first['source'])}</p>
</blockquote>"""
    subjects_html = ""
    if book["subjects"]:
        items = "".join(f"<li>{esc(subject)}</li>" for subject in book["subjects"][:8])
        subjects_html = f'<ul class="subject-list">{items}</ul>'
    series_value = ", ".join(book["series"]) if book["series"] else "—"
    return f"""<article class="book-detail container">
  <aside class="book-cover-aside">{cover_figure(book, "hero", eager=True)}</aside>
  <div class="book-body">
    <p class="kicker kicker-thread">Spotlight volume — {esc(book['publisher'])}</p>
    <h1 class="book-title">{esc(book['title'])}</h1>
    <p class="book-byline">{esc(contributor_line(book))}</p>
    <p class="book-description">{esc(excerpt(book['description'], DESCRIPTION_DETAIL))}</p>
    {praise_html}
    <dl class="biblio">
      <div class="biblio-row"><dt>Publisher</dt><dd>{esc(book['publisher'])}</dd></div>
      <div class="biblio-row"><dt>Format</dt><dd>{esc(book['format'])}</dd></div>
      <div class="biblio-row"><dt>Published</dt><dd>{esc(book['published_on'] or 'n.d.')}</dd></div>
      <div class="biblio-row"><dt>ISBN-13</dt><dd>{esc(book['isbn'] or 'not recorded')}</dd></div>
      <div class="biblio-row"><dt>Series</dt><dd>{esc(series_value)}</dd></div>
      <div class="biblio-row"><dt>Subjects</dt><dd>{subjects_html or '—'}</dd></div>
    </dl>
    <p style="display:flex; gap:14px; flex-wrap:wrap;">
      <a class="button" href="publishers.html">Browse {esc(book['publisher'])}</a>
      <a class="button button-ghost" href="browse.html">Back to browse</a>
    </p>
  </div>
</article>"""


def gallery_publishers_body(ctx: dict) -> str:
    rows = []
    sampled_by_publisher: dict[str, list[dict]] = {}
    for book in ctx["books"]:
        sampled_by_publisher.setdefault(book["publisher"], []).append(book)
    for publisher in sorted(ctx["corpus_counts"]):
        count = ctx["corpus_counts"][publisher]
        sampled = sampled_by_publisher.get(publisher, [])
        sample_line = ""
        if sampled:
            sample_line = f'<p class="publisher-sample">In this sample: {esc(sampled[0]["title"])}{esc(" · " + sampled[0]["year"]) if sampled[0]["year"] else ""}</p>'
            count_html = f'<p class="publisher-count"><strong>{len(sampled)} sampled</strong> · {count:,} records</p>'
        else:
            count_html = f'<p class="publisher-count">{count:,} records</p>'
        rows.append(f"""<a class="publisher-row" href="browse.html">
  <h2 class="publisher-name">{esc(publisher)}</h2>
  {count_html}
  {sample_line}
</a>""")
    return f"""<section class="browse-masthead container">
  <p class="kicker">Source registry</p>
  <h1 class="browse-title">Publishers</h1>
  <p class="browse-sub">{len(ctx['corpus_counts'])} approved independent presses; {ctx['corpus_total']:,} source records under provenance.</p>
</section>
<section class="publisher-list container">
{chr(10).join(rows)}
</section>"""


# ---------------------------------------------------------------------------
# LEDGER — archive-index density
# ---------------------------------------------------------------------------

LEDGER_CSS = """/* LEDGER — archive-index density. Strong rules, Space Mono labels, tabular rows. */

@font-face {
  font-family: "Newsreader";
  font-style: normal;
  font-weight: 200 800;
  font-display: swap;
  src: url("fonts/newsreader-variable-normal.woff2") format("woff2");
}
@font-face {
  font-family: "Newsreader";
  font-style: italic;
  font-weight: 200 800;
  font-display: swap;
  src: url("fonts/newsreader-variable-italic.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url("fonts/space-mono-400-normal.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: italic;
  font-weight: 400;
  font-display: swap;
  src: url("fonts/space-mono-400-italic.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url("fonts/space-mono-700-normal.woff2") format("woff2");
}

:root {
  --paper: #F6F3EA;
  --wash: rgba(21, 18, 11, 0.045);
  --ink: #15120B;
  --ink-2: rgba(21, 18, 11, 0.66);
  --ink-3: rgba(21, 18, 11, 0.44);
  --rule: #15120B;
  --rule-soft: rgba(21, 18, 11, 0.35);
  --accent: #A33417;
  --serif: "Newsreader", "Iowan Old Style", Georgia, serif;
  --mono: "Space Mono", "SFMono-Regular", Menlo, monospace;
  --rail: 232px;
  --measure: 1240px;
}

* { box-sizing: border-box; }
body {
  margin: 0; background: var(--paper); color: var(--ink);
  font-family: var(--mono); font-size: 13px; line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}
img { display: block; max-width: 100%; }
a { color: inherit; }

.container { max-width: var(--measure); margin-inline: auto; padding-inline: clamp(18px, 3.4vw, 40px); }

.skip-link {
  position: absolute; left: -9999px; top: 0; z-index: 60;
  background: var(--ink); color: var(--paper); text-decoration: none;
  font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; padding: 10px 16px;
}
.skip-link:focus { left: 0; top: 0; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

.proto-strip { margin: 0; background: var(--ink); color: rgba(246, 243, 234, 0.75); }
.proto-strip-inner { display: block; padding: 5px clamp(18px, 3.4vw, 40px); font-size: 9px; letter-spacing: 0.2em; text-transform: uppercase; }

/* Masthead */
.masthead { border-bottom: 1px solid var(--rule); background: var(--paper); position: sticky; top: 0; z-index: 50; }
.masthead-inner { display: flex; align-items: stretch; gap: 0; min-height: 56px; }
.wordmark {
  display: flex; align-items: center; padding-right: 28px;
  font-weight: 700; font-size: 14px; letter-spacing: 0.22em; text-transform: uppercase; text-decoration: none;
}
.site-nav { display: flex; align-items: stretch; margin-left: auto; border-left: 1px solid var(--rule); }
.nav-link {
  display: flex; align-items: center; padding: 0 18px;
  font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; text-decoration: none;
  color: var(--ink-2); border-left: 1px solid var(--rule-soft);
  transition: background 140ms ease, color 140ms ease;
}
.nav-link:hover { background: var(--wash); color: var(--ink); }
.nav-link.is-active { color: var(--accent); box-shadow: inset 0 -3px 0 var(--accent); }
.mobile-menu { display: none; margin-left: auto; position: relative; align-self: center; }
.mobile-menu summary { list-style: none; cursor: pointer; font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; padding: 8px 0; }
.mobile-menu summary::-webkit-details-marker { display: none; }
.mobile-menu-panel {
  position: absolute; right: 0; top: calc(100% + 10px); z-index: 55;
  display: flex; flex-direction: column;
  background: var(--paper); border: 1px solid var(--rule); min-width: 210px;
}
.mobile-menu-panel .nav-link { border-left: 0; border-top: 1px solid var(--rule-soft); padding: 12px 16px; }

/* Type helpers */
.label { font-size: 10px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--ink-2); }
.label-accent { color: var(--accent); }
h1, h2, h3 { font-family: var(--mono); }

/* Ledger shell: left rail + body */
.ledger-shell { display: grid; grid-template-columns: var(--rail) 1fr; border-bottom: 1px solid var(--rule); }
.rail { border-right: 1px solid var(--rule); padding: 28px 22px 40px; position: sticky; top: 57px; align-self: start; max-height: calc(100vh - 57px); overflow-y: auto; }
.rail-heading { margin: 0 0 14px; font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--ink-3); }
.rail-list { list-style: none; margin: 0 0 26px; padding: 0; }
.rail-list li { margin: 0; }
.rail-link {
  display: flex; justify-content: space-between; gap: 10px; padding: 6px 4px;
  font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; text-decoration: none; color: var(--ink-2);
  border-bottom: 1px solid var(--rule-soft);
  transition: color 140ms ease, background 140ms ease;
}
.rail-link:hover { color: var(--ink); background: var(--wash); }
.rail-link.is-active { color: var(--accent); }
.rail-count { color: var(--ink-3); }
.ledger-body { padding: 28px clamp(20px, 3vw, 40px) 48px; min-width: 0; }

/* Home summary strip */
.summary-strip { display: grid; grid-template-columns: repeat(4, 1fr); border: 1px solid var(--rule); margin-bottom: 34px; }
.summary-cell { padding: 18px 20px; border-left: 1px solid var(--rule); }
.summary-cell:first-child { border-left: 0; }
.summary-value { display: block; font-size: 26px; font-weight: 700; letter-spacing: 0.02em; margin-bottom: 4px; }
.summary-key { font-size: 9px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--ink-2); }

.page-title { font-size: clamp(20px, 2.4vw, 30px); font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; margin: 0 0 6px; }
.page-sub { margin: 0 0 26px; color: var(--ink-2); font-size: 12px; }

/* Tabular rows */
.ledger-table { border-top: 1px solid var(--rule); }
.ledger-head, .ledger-row {
  display: grid; grid-template-columns: 52px 76px minmax(220px, 1.6fr) minmax(140px, 1fr) 58px 92px;
  gap: 18px; align-items: center;
}
.ledger-head { padding: 10px 8px; border-bottom: 1px solid var(--rule); font-size: 9px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--ink-3); }
.ledger-row {
  padding: 14px 8px; border-bottom: 1px solid var(--rule); text-decoration: none; color: inherit;
  transition: background 140ms ease, box-shadow 140ms ease;
}
.ledger-row:hover { background: var(--wash); box-shadow: inset 3px 0 0 var(--accent); }
.ledger-row.is-spotlight { box-shadow: inset 3px 0 0 var(--accent); }
.ledger-row.is-spotlight .row-no { color: var(--accent); }
.row-no { font-size: 11px; color: var(--ink-3); font-weight: 700; }
.row-thumb { width: 64px; height: 96px; object-fit: cover; border: 1px solid var(--rule); background: var(--paper); }
.row-title-block { min-width: 0; }
.row-title { margin: 0 0 3px; font-family: var(--serif); font-size: 17px; font-weight: 560; line-height: 1.25; letter-spacing: 0.005em; }
.row-contrib { margin: 0; font-size: 10.5px; color: var(--ink-2); letter-spacing: 0.04em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row-publisher { font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; }
.row-year { font-size: 11px; color: var(--ink-2); }
.row-format { justify-self: start; font-size: 9px; letter-spacing: 0.16em; text-transform: uppercase; border: 1px solid var(--rule); padding: 4px 8px; white-space: nowrap; }

/* Spotlight note */
.spotlight-note { border: 1px solid var(--rule); border-left: 4px solid var(--accent); padding: 20px 24px; margin: 0 0 34px; background: var(--wash); }
.spotlight-note .label { display: block; margin-bottom: 8px; }
.spotlight-note-title { font-family: var(--serif); font-size: 22px; font-weight: 560; margin: 0 0 6px; }
.spotlight-note-text { margin: 0; color: var(--ink-2); font-size: 12px; max-width: 72ch; }

/* Fallback cover (ledger: flat, ruled) */
.fallback-cover {
  position: relative; display: flex; flex-direction: column; justify-content: space-between;
  width: 64px; height: 96px; padding: 7px; overflow: hidden;
  background: var(--paper); border: 1px solid var(--rule); color: var(--ink);
}
.fallback-cover.fb-hero { width: 100%; height: auto; aspect-ratio: 2 / 3; padding: 18px; }
.fb-grain { position: absolute; inset: 0; pointer-events: none; opacity: 0.45; background-image: radial-gradient(rgba(21, 18, 11, 0.06) 1px, transparent 1px); background-size: 3px 3px; }
.fb-publisher { position: relative; margin: 0; text-align: center; font-size: 6px; letter-spacing: 0.2em; text-transform: uppercase; opacity: 0.85; }
.fb-body { position: relative; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 6px; padding: 6px 2px; }
.fb-rule { width: 26px; height: 1px; background: var(--rule-soft); }
.fb-title { margin: 0; font-family: var(--serif); font-size: 9px; font-weight: 600; line-height: 1.2; }
.fb-byline { margin: 0; font-family: var(--serif); font-style: italic; font-size: 7px; opacity: 0.85; }
.fb-foot { position: relative; display: flex; justify-content: space-between; gap: 4px; border-top: 1px solid var(--rule-soft); padding-top: 4px; font-size: 5.5px; letter-spacing: 0.12em; text-transform: uppercase; opacity: 0.75; }
.fb-series { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.fb-hero .fb-publisher { font-size: 9px; }
.fb-hero .fb-title { font-size: 1.3rem; }
.fb-hero .fb-byline { font-size: 0.85rem; }
.fb-hero .fb-foot { font-size: 8px; padding-top: 10px; }
.fb-hero .fb-rule { width: 42px; }

/* Search + filters (browse) */
.search-block { margin: 0 0 22px; }
.search-label { display: block; margin-bottom: 8px; font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--ink-2); }
.search-input {
  width: 100%; max-width: 560px; background: var(--paper); border: 1px solid var(--rule); border-radius: 0;
  font-family: var(--mono); font-size: 13px; color: var(--ink); padding: 12px 14px;
}
.search-input::placeholder { color: var(--ink-3); }
.search-input:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
.chips { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 30px; }
.chip {
  display: inline-flex; align-items: baseline; gap: 8px;
  border: 1px solid var(--rule); border-radius: 0; padding: 6px 10px;
  font-size: 9.5px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-2);
  transition: background 140ms ease, color 140ms ease;
}
.chip:hover { background: var(--wash); color: var(--ink); }
.chip-count { color: var(--ink-3); }
.chip-series { border-color: var(--accent); color: var(--accent); }

/* Book dossier */
.dossier { display: grid; grid-template-columns: 300px 1fr; gap: clamp(28px, 4vw, 56px); align-items: start; }
.dossier-cover { border: 1px solid var(--rule); position: sticky; top: 88px; }
.dossier-cover .cover-img { width: 100%; aspect-ratio: 2 / 3; object-fit: cover; }
.dossier-title { font-family: var(--serif); font-size: clamp(26px, 3vw, 38px); font-weight: 560; line-height: 1.15; margin: 0 0 8px; }
.dossier-byline { margin: 0 0 24px; font-size: 12px; color: var(--ink-2); }
.dossier-description { font-family: var(--serif); font-size: 16px; line-height: 1.7; max-width: 64ch; margin: 0 0 30px; }
.field-table { border-top: 1px solid var(--rule); margin: 0 0 32px; max-width: 680px; }
.field-row { display: grid; grid-template-columns: 170px 1fr; gap: 18px; padding: 11px 0; border-bottom: 1px solid var(--rule); }
.field-row dt { margin: 0; font-size: 9.5px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--ink-2); padding-top: 2px; }
.field-row dd { margin: 0; font-size: 12.5px; }
.praise { border: 1px solid var(--rule); border-left: 4px solid var(--accent); padding: 18px 22px; margin: 0 0 32px; max-width: 62ch; background: var(--wash); }
.praise-quote { font-family: var(--serif); font-style: italic; font-size: 17px; line-height: 1.55; margin: 0 0 8px; }
.praise-source { margin: 0; font-size: 9.5px; letter-spacing: 0.16em; text-transform: uppercase; color: var(--ink-2); }
.subject-list { display: flex; flex-wrap: wrap; gap: 6px; list-style: none; margin: 0; padding: 0; }
.subject-list li { font-size: 9px; letter-spacing: 0.12em; text-transform: uppercase; border: 1px solid var(--rule-soft); padding: 3px 7px; color: var(--ink-2); }
.button {
  display: inline-block; background: var(--ink); color: var(--paper); border: 1px solid var(--ink); border-radius: 0;
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase;
  text-decoration: none; padding: 13px 22px; transition: background 140ms ease, color 140ms ease;
}
.button:hover { background: var(--accent); border-color: var(--accent); }
.button-ghost { background: transparent; color: var(--ink); }
.button-ghost:hover { background: var(--wash); color: var(--accent); border-color: var(--accent); }

/* Publishers table */
.publisher-rows { border-top: 1px solid var(--rule); }
.publisher-row {
  display: grid; grid-template-columns: 52px minmax(200px, 1.2fr) minmax(180px, 1.4fr) 130px;
  gap: 18px; align-items: baseline; padding: 13px 8px; border-bottom: 1px solid var(--rule);
  text-decoration: none; color: inherit; transition: background 140ms ease, box-shadow 140ms ease;
}
.publisher-row:hover { background: var(--wash); box-shadow: inset 3px 0 0 var(--accent); }
.publisher-no { font-size: 11px; color: var(--ink-3); font-weight: 700; }
.publisher-name { margin: 0; font-size: 12px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; }
.publisher-sample { margin: 0; font-family: var(--serif); font-style: italic; font-size: 13.5px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.publisher-count { font-size: 10.5px; letter-spacing: 0.08em; color: var(--ink-2); text-align: right; }
.publisher-count strong { color: var(--accent); }

/* Footer */
.site-footer { border-top: 1px solid var(--rule); margin-top: 48px; }
.footer-grid { display: grid; grid-template-columns: 1.3fr 0.8fr 1.5fr; gap: 36px; padding: 36px clamp(18px, 3.4vw, 40px) 32px; }
.footer-wordmark { font-weight: 700; letter-spacing: 0.22em; text-transform: uppercase; font-size: 14px; margin: 0 0 10px; }
.footer-tagline { font-family: var(--serif); font-style: italic; color: var(--ink-2); margin: 0; max-width: 32ch; font-size: 14px; }
.footer-heading { margin: 0 0 12px; font-size: 9px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--ink-3); }
.footer-nav { display: flex; flex-direction: column; gap: 7px; }
.footer-link { font-size: 10.5px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--ink-2); text-decoration: none; width: fit-content; }
.footer-link:hover { color: var(--accent); }
.footer-note { color: var(--ink-2); font-size: 11px; margin: 0 0 10px; max-width: 52ch; }
.footer-legal { border-top: 1px solid var(--rule); padding: 14px clamp(18px, 3.4vw, 40px); font-size: 9px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--ink-3); }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition-duration: 0.01ms !important; }
}

@media (max-width: 980px) {
  .ledger-shell { grid-template-columns: 1fr; }
  .rail { position: static; max-height: none; border-right: 0; border-bottom: 1px solid var(--rule); display: flex; flex-wrap: wrap; gap: 6px 22px; padding: 16px 20px; }
  .rail-heading { width: 100%; margin-bottom: 4px; }
  .rail-list { display: flex; flex-wrap: wrap; gap: 4px 14px; margin-bottom: 0; }
  .rail-link { border-bottom: 0; padding: 4px 2px; }
  .dossier { grid-template-columns: 1fr; }
  .dossier-cover { position: static; max-width: 300px; }
  .summary-strip { grid-template-columns: repeat(2, 1fr); }
  .summary-cell:nth-child(3) { border-left: 0; }
  .summary-cell:nth-child(n+3) { border-top: 1px solid var(--rule); }
  .footer-grid { grid-template-columns: 1fr; gap: 28px; }
}
@media (max-width: 720px) {
  .site-nav { display: none; }
  .mobile-menu { display: block; }
}
@media (max-width: 390px) {
  .ledger-head { display: none; }
  .ledger-row { grid-template-columns: 40px 64px 1fr; grid-template-rows: auto auto; row-gap: 4px; }
  .row-thumb { width: 56px; height: 84px; grid-row: span 2; }
  .row-contrib { white-space: normal; }
  .row-publisher, .row-year, .row-format { grid-column: 3; justify-self: start; }
  .row-publisher { display: inline; }
  .publisher-row { grid-template-columns: 36px 1fr; }
  .publisher-sample, .publisher-count { grid-column: 2; text-align: left; white-space: normal; }
  .field-row { grid-template-columns: 1fr; gap: 3px; }
  .summary-strip { grid-template-columns: 1fr; }
  .summary-cell { border-left: 0; border-top: 1px solid var(--rule); }
  .summary-cell:first-child { border-top: 0; }
}
"""


def ledger_row(index: int, book: dict, spotlight: bool = False) -> str:
    cls = "ledger-row is-spotlight" if spotlight else "ledger-row"
    thumb = cover_figure(book, "card").replace('class="cover-img cover-card"', 'class="row-thumb"')
    return f"""<a class="{cls}" href="book.html">
  <span class="row-no">{index:03d}</span>
  {thumb}
  <span class="row-title-block">
    <span class="row-title">{esc(book['title'])}</span>
    <span class="row-contrib">{esc(contributor_line(book))}</span>
  </span>
  <span class="row-publisher">{esc(book['publisher'])}</span>
  <span class="row-year">{esc(year_label(book))}</span>
  <span class="row-format">{esc(book['format'])}</span>
</a>"""


def ledger_rail(ctx: dict, active: str = "") -> str:
    publisher_items = []
    sampled_publishers = sorted({book["publisher"] for book in ctx["books"]})
    for publisher in sampled_publishers[:14]:
        count = ctx["corpus_counts"].get(publisher, 0)
        publisher_items.append(
            f'<li><a class="rail-link" href="browse.html"><span>{esc(publisher)}</span><span class="rail-count">{count:,}</span></a></li>'
        )
    return f"""<aside class="rail" aria-label="Index rail">
  <p class="rail-heading">Index</p>
  <ul class="rail-list">
    <li><a class="rail-link{' is-active' if active == 'holdings' else ''}" href="index.html"><span>Holdings ledger</span><span class="rail-count">{len(ctx['books'])}</span></a></li>
    <li><a class="rail-link{' is-active' if active == 'browse' else ''}" href="browse.html"><span>Browse + filters</span><span class="rail-count">{len(ctx['books'])}</span></a></li>
    <li><a class="rail-link{' is-active' if active == 'publishers' else ''}" href="publishers.html"><span>Publisher index</span><span class="rail-count">{len(ctx['corpus_counts'])}</span></a></li>
  </ul>
  <p class="rail-heading">Publishers in sample</p>
  <ul class="rail-list">
{chr(10).join(publisher_items)}
  </ul>
</aside>"""


def ledger_pages(ctx: dict) -> dict[str, str]:
    spotlight = ctx["spotlight"]
    books = ctx["books"]
    rows = "\n".join(ledger_row(i + 1, book, book is spotlight) for i, book in enumerate(books))
    spotlight_index = books.index(spotlight) + 1

    index_body = f"""<div class="ledger-shell">
{ledger_rail(ctx, "holdings")}
  <div class="ledger-body">
    <p class="label label-accent">Accessions register · sampled holdings</p>
    <h1 class="page-title">Holdings ledger</h1>
    <p class="page-sub">{len(books)} volumes sampled deterministically from {ctx['corpus_total']:,} records across {len(ctx['corpus_counts'])} independent presses.</p>
    <div class="summary-strip">
      <div class="summary-cell"><span class="summary-value">{ctx['corpus_total']:,}</span><span class="summary-key">Source records</span></div>
      <div class="summary-cell"><span class="summary-value">{len(ctx['corpus_counts'])}</span><span class="summary-key">Approved presses</span></div>
      <div class="summary-cell"><span class="summary-value">{len(books)}</span><span class="summary-key">Sampled volumes</span></div>
      <div class="summary-cell"><span class="summary-value">{len(format_counts(books))}</span><span class="summary-key">Formats in sample</span></div>
    </div>
    <div class="spotlight-note">
      <span class="label label-accent">Spotlight volume · entry {spotlight_index:03d} — {esc(spotlight['publisher'])}</span>
      <p class="spotlight-note-title">{esc(spotlight['title'])}</p>
      <p class="spotlight-note-text">{esc(excerpt(spotlight['description'], 300))}</p>
    </div>
    <div class="ledger-table">
      <div class="ledger-head" aria-hidden="true">
        <span>No.</span><span>Cover</span><span>Title / contributors</span><span>Publisher</span><span>Year</span><span>Format</span>
      </div>
{rows}
    </div>
  </div>
</div>"""

    browse_body = f"""<div class="ledger-shell">
{ledger_rail(ctx, "browse")}
  <div class="ledger-body">
    <p class="label label-accent">Catalog index · full sample</p>
    <h1 class="page-title">Browse</h1>
    <p class="page-sub">{len(books)} volumes, numbered in accession order. Filters reflect the sampled corpus.</p>
    <div class="search-block" id="catalog-search">
      <label class="search-label" for="q">Search the catalog</label>
      <input class="search-input" id="q" type="search" placeholder="titles / authors / translators / publishers" autocomplete="off">
    </div>
    <div id="filters" class="chips">
{chip_row(books)}
    </div>
    <div class="ledger-table">
      <div class="ledger-head" aria-hidden="true">
        <span>No.</span><span>Cover</span><span>Title / contributors</span><span>Publisher</span><span>Year</span><span>Format</span>
      </div>
{rows}
    </div>
  </div>
</div>"""

    book_body = f"""<div class="ledger-shell">
{ledger_rail(ctx)}
  <div class="ledger-body">
    <p class="label label-accent">Dossier · entry {spotlight_index:03d}</p>
    <div class="dossier">
      <div class="dossier-cover">{cover_figure(spotlight, "hero", eager=True)}</div>
      <div class="dossier-main">
        <h1 class="dossier-title">{esc(spotlight['title'])}</h1>
        <p class="dossier-byline">{esc(contributor_line(spotlight))} · {esc(spotlight['publisher'])} · {esc(year_label(spotlight))}</p>
        <p class="dossier-description">{esc(excerpt(spotlight['description'], DESCRIPTION_DETAIL))}</p>
        {ledger_praise(spotlight)}
        <dl class="field-table">
          <div class="field-row"><dt>Publisher</dt><dd>{esc(spotlight['publisher'])}</dd></div>
          <div class="field-row"><dt>Format</dt><dd>{esc(spotlight['format'])}</dd></div>
          <div class="field-row"><dt>Published</dt><dd>{esc(spotlight['published_on'] or 'n.d.')}</dd></div>
          <div class="field-row"><dt>ISBN-13</dt><dd>{esc(spotlight['isbn'] or 'not recorded')}</dd></div>
          <div class="field-row"><dt>Series</dt><dd>{esc(', '.join(spotlight['series']) if spotlight['series'] else '—')}</dd></div>
          <div class="field-row"><dt>Subjects</dt><dd>{ledger_subjects(spotlight)}</dd></div>
          <div class="field-row"><dt>Source dataset</dt><dd>{esc(spotlight['dataset'])}</dd></div>
        </dl>
        <p style="display:flex; gap:12px; flex-wrap:wrap;">
          <a class="button" href="publishers.html">Publisher index</a>
          <a class="button button-ghost" href="browse.html">Back to browse</a>
        </p>
      </div>
    </div>
  </div>
</div>"""

    publishers_body = ledger_publishers_body(ctx)

    return {
        "index.html": page_shell("ledger", "Ledger", "index", "Holdings", index_body),
        "browse.html": page_shell("ledger", "Ledger", "browse", "Browse", browse_body),
        "book.html": page_shell("ledger", "Ledger", "book", spotlight["title"], book_body),
        "publishers.html": page_shell("ledger", "Ledger", "publishers", "Publishers", publishers_body),
    }


def ledger_praise(book: dict) -> str:
    if not book["praise"]:
        return ""
    first = book["praise"][0]
    return f"""<blockquote class="praise">
  <p class="praise-quote">“{esc(first['quote'])}”</p>
  <p class="praise-source">— {esc(first['source'])}</p>
</blockquote>"""


def ledger_subjects(book: dict) -> str:
    if not book["subjects"]:
        return "—"
    items = "".join(f"<li>{esc(subject)}</li>" for subject in book["subjects"][:8])
    return f'<ul class="subject-list">{items}</ul>'


def ledger_publishers_body(ctx: dict) -> str:
    sampled_by_publisher: dict[str, list[dict]] = {}
    for book in ctx["books"]:
        sampled_by_publisher.setdefault(book["publisher"], []).append(book)
    rows = []
    for index, publisher in enumerate(sorted(ctx["corpus_counts"]), start=1):
        count = ctx["corpus_counts"][publisher]
        sampled = sampled_by_publisher.get(publisher, [])
        if sampled:
            sample = f"{sampled[0]['title']} — {byline(sampled[0])}"
            count_html = f'<span class="publisher-count"><strong>{len(sampled)} sampled</strong> / {count:,} records</span>'
        else:
            sample = "not in sample"
            count_html = f'<span class="publisher-count">{count:,} records</span>'
        rows.append(f"""<a class="publisher-row" href="browse.html">
  <span class="publisher-no">{index:03d}</span>
  <h2 class="publisher-name">{esc(publisher)}</h2>
  <p class="publisher-sample">{esc(sample)}</p>
  {count_html}
</a>""")
    return f"""<div class="ledger-shell">
{ledger_rail(ctx, "publishers")}
  <div class="ledger-body">
    <p class="label label-accent">Source registry · {len(ctx['corpus_counts'])} presses</p>
    <h1 class="page-title">Publisher index</h1>
    <p class="page-sub">Approved independent presses with checked-in source records. Counts reflect the full corpus; the sample column reflects this prototype.</p>
    <div class="publisher-rows">
{chr(10).join(rows)}
    </div>
  </div>
</div>"""


# ---------------------------------------------------------------------------
# NIGHT READING — dark-first warm reading room
# ---------------------------------------------------------------------------

NIGHT_CSS = """/* NIGHT READING — dark-first warm reading room. Lamplight amber, deep shadows, shelf rows. */

@font-face {
  font-family: "Newsreader";
  font-style: normal;
  font-weight: 200 800;
  font-display: swap;
  src: url("fonts/newsreader-variable-normal.woff2") format("woff2");
}
@font-face {
  font-family: "Newsreader";
  font-style: italic;
  font-weight: 200 800;
  font-display: swap;
  src: url("fonts/newsreader-variable-italic.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url("fonts/space-mono-400-normal.woff2") format("woff2");
}
@font-face {
  font-family: "Space Mono";
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url("fonts/space-mono-700-normal.woff2") format("woff2");
}

:root {
  --bg: #16120E;
  --raise: #201A14;
  --raise-2: #28211A;
  --cream: #F1E7D8;
  --cream-2: rgba(241, 231, 216, 0.64);
  --cream-3: rgba(241, 231, 216, 0.4);
  --lamp: #E0A458;
  --ember: #D95B36;
  --line: rgba(241, 231, 216, 0.13);
  --radius: 10px;
  --radius-pill: 999px;
  --shadow-deep: 0 30px 60px -22px rgba(0, 0, 0, 0.72);
  --shadow-lift: 0 18px 44px -16px rgba(0, 0, 0, 0.78), 0 0 0 1px rgba(224, 164, 88, 0.28);
  --glow: radial-gradient(640px 420px at 26% 12%, rgba(224, 164, 88, 0.16), transparent 68%);
  --serif: "Newsreader", "Iowan Old Style", Georgia, serif;
  --mono: "Space Mono", "SFMono-Regular", Menlo, monospace;
  --measure: 1180px;
}

/* Warm-cream light variant: flip the lamp switch (pure CSS, no scripts). */
body:has(#lamp:checked) {
  --bg: #F5EDDE;
  --raise: #FCF7EC;
  --raise-2: #FFFDF6;
  --cream: #26190E;
  --cream-2: rgba(38, 25, 14, 0.66);
  --cream-3: rgba(38, 25, 14, 0.42);
  --lamp: #B0722A;
  --ember: #A33417;
  --line: rgba(38, 25, 14, 0.14);
  --shadow-deep: 0 26px 50px -24px rgba(64, 42, 20, 0.4);
  --shadow-lift: 0 16px 38px -16px rgba(64, 42, 20, 0.45), 0 0 0 1px rgba(176, 114, 42, 0.3);
  --glow: radial-gradient(640px 420px at 26% 12%, rgba(224, 164, 88, 0.22), transparent 68%);
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0; background: var(--bg); color: var(--cream);
  font-family: var(--serif); font-size: 18px; line-height: 1.7;
  -webkit-font-smoothing: antialiased;
  transition: background 320ms ease, color 320ms ease;
}
img { display: block; max-width: 100%; }
a { color: inherit; }

.container { max-width: var(--measure); margin-inline: auto; padding-inline: clamp(20px, 4vw, 48px); }

.skip-link {
  position: absolute; left: -9999px; top: 0; z-index: 60;
  background: var(--lamp); color: #16120E; text-decoration: none;
  font-family: var(--mono); font-size: 12px; letter-spacing: 0.16em; text-transform: uppercase;
  padding: 10px 18px; border-radius: var(--radius);
}
.skip-link:focus { left: 12px; top: 12px; }
:focus-visible { outline: 2px solid var(--lamp); outline-offset: 3px; border-radius: 4px; }

#lamp { position: absolute; opacity: 0; pointer-events: none; }

.proto-strip { margin: 0; background: rgba(0, 0, 0, 0.32); color: var(--cream-3); border-bottom: 1px solid var(--line); }
body:has(#lamp:checked) .proto-strip { background: rgba(38, 25, 14, 0.06); }
.proto-strip-inner { display: block; padding: 6px clamp(20px, 4vw, 48px); font-family: var(--mono); font-size: 10px; letter-spacing: 0.18em; text-transform: uppercase; }

/* Masthead */
.masthead {
  position: sticky; top: 0; z-index: 50;
  background: color-mix(in srgb, var(--bg) 86%, transparent);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line);
}
.masthead-inner { display: flex; align-items: center; gap: 32px; min-height: 68px; }
.wordmark { font-family: var(--serif); font-size: 26px; font-weight: 420; font-style: italic; letter-spacing: 0.01em; text-decoration: none; color: var(--cream); }
.site-nav { display: flex; gap: 26px; margin-left: auto; }
.nav-link {
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase;
  color: var(--cream-2); text-decoration: none; padding: 6px 2px; border-radius: 4px;
  transition: color 200ms ease;
}
.nav-link:hover { color: var(--lamp); }
.nav-link.is-active { color: var(--lamp); }
.lamp-label {
  display: inline-flex; align-items: center; gap: 9px; cursor: pointer; user-select: none;
  font-family: var(--mono); font-size: 10px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--cream-2);
}
.lamp-dot {
  width: 13px; height: 13px; border-radius: 50%;
  background: var(--lamp); box-shadow: 0 0 14px 2px color-mix(in srgb, var(--lamp) 55%, transparent);
  transition: background 240ms ease, box-shadow 240ms ease;
}
.lamp-label:hover .lamp-dot { box-shadow: 0 0 20px 4px color-mix(in srgb, var(--lamp) 70%, transparent); }
.mobile-menu { display: none; margin-left: auto; position: relative; }
.mobile-menu summary { list-style: none; cursor: pointer; font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--cream); padding: 8px 0; }
.mobile-menu summary::-webkit-details-marker { display: none; }
.mobile-menu-panel {
  position: absolute; right: 0; top: calc(100% + 14px); z-index: 55;
  display: flex; flex-direction: column; gap: 2px;
  background: var(--raise); border: 1px solid var(--line); border-radius: var(--radius);
  box-shadow: var(--shadow-deep); padding: 14px 18px; min-width: 210px;
}
.mobile-menu-panel .nav-link { padding: 9px 0; }

/* Typography */
.kicker { font-family: var(--mono); font-size: 11px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--lamp); margin: 0 0 18px; }
.display {
  font-family: var(--serif); font-weight: 320; line-height: 1.12; letter-spacing: -0.01em;
  font-size: clamp(2.5rem, 1.9rem + 2.6vw, 4.4rem); margin: 0 0 24px; max-width: 20ch;
}
.display em { font-style: italic; color: var(--lamp); }

/* Home */
.hero { position: relative; padding: clamp(52px, 8vw, 104px) 0 clamp(40px, 6vw, 72px); overflow: hidden; }
.hero::before { content: ""; position: absolute; inset: 0; background: var(--glow); pointer-events: none; }
.hero-lede { font-size: 1.18rem; font-style: italic; color: var(--cream-2); max-width: 54ch; margin: 0; position: relative; }

/* Spotlight */
.spotlight { position: relative; display: grid; grid-template-columns: minmax(240px, 380px) 1fr; gap: clamp(32px, 5vw, 72px); padding: clamp(36px, 5vw, 64px) 0 clamp(48px, 6vw, 80px); align-items: start; }
.spotlight-cover .cover-img, .spotlight-cover .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover; border-radius: var(--radius);
  box-shadow: var(--shadow-deep), 0 0 90px -30px color-mix(in srgb, var(--lamp) 40%, transparent);
}
.spotlight-title { font-size: clamp(1.9rem, 1.4rem + 1.8vw, 2.9rem); font-weight: 400; line-height: 1.16; margin: 0 0 12px; }
.spotlight-byline { font-size: 1.1rem; font-style: italic; color: var(--cream-2); margin: 0 0 24px; }
.spotlight-excerpt { max-width: 58ch; color: var(--cream-2); margin: 0 0 28px; }
.spotlight-meta { font-family: var(--mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--cream-3); margin: 0 0 30px; }
.text-link {
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase;
  color: var(--ember); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--ember) 45%, transparent);
  padding-bottom: 4px; transition: border-color 200ms ease, color 200ms ease;
}
.text-link:hover { color: var(--lamp); border-bottom-color: var(--lamp); }

/* Shelves */
.shelf-section { padding: clamp(30px, 4vw, 52px) 0; border-top: 1px solid var(--line); }
.shelf-head { display: flex; align-items: baseline; justify-content: space-between; gap: 20px; margin-bottom: 24px; }
.shelf-title { font-size: 1.6rem; font-weight: 400; font-style: italic; margin: 0; }
.shelf-note { font-family: var(--mono); font-size: 10px; letter-spacing: 0.16em; text-transform: uppercase; color: var(--cream-3); }
.shelf {
  display: grid; grid-auto-flow: column; grid-auto-columns: clamp(132px, 14vw, 164px);
  gap: 26px; overflow-x: auto; scroll-snap-type: x proximity;
  padding: 8px 4px 22px;
}
.shelf-item { scroll-snap-align: start; margin: 0; }
.shelf-item a { text-decoration: none; display: block; }
.shelf-item .cover-img, .shelf-item .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover; border-radius: 8px;
  box-shadow: var(--shadow-deep);
  transition: transform 320ms ease, box-shadow 320ms ease;
}
.shelf-item a:hover .cover-img, .shelf-item a:hover .fallback-cover,
.shelf-item a:focus-visible .cover-img, .shelf-item a:focus-visible .fallback-cover {
  transform: translateY(-9px); box-shadow: var(--shadow-lift);
}
.shelf-caption { padding-top: 13px; }
.shelf-card-title { font-size: 0.98rem; font-weight: 500; line-height: 1.3; margin: 0 0 4px; color: var(--cream); }
.shelf-card-meta { font-family: var(--mono); font-size: 9.5px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--cream-3); margin: 0; }
.shelf-edge { border: 0; border-top: 1px solid color-mix(in srgb, var(--lamp) 26%, transparent); margin: 0; opacity: 0.7; }

/* Fallback cover */
.fallback-cover {
  position: relative; display: flex; flex-direction: column; justify-content: space-between;
  padding: 18px; overflow: hidden; user-select: none;
  background: var(--raise-2); color: var(--cream);
  border: 1px solid var(--line);
}
.fb-grain { position: absolute; inset: 0; pointer-events: none; opacity: 0.45; background-image: radial-gradient(rgba(241, 231, 216, 0.06) 1px, transparent 1px); background-size: 3px 3px; }
.fb-grain::after { content: ""; position: absolute; inset: 0; background: radial-gradient(120% 60% at 50% 0%, rgba(224, 164, 88, 0.14), transparent 62%); }
.fb-publisher { position: relative; margin: 0; text-align: center; font-family: var(--mono); font-size: 9px; letter-spacing: 0.22em; text-transform: uppercase; opacity: 0.82; }
.fb-body { position: relative; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 10px; padding: 12px 6px; }
.fb-rule { width: 42px; height: 1px; background: color-mix(in srgb, currentColor 26%, transparent); }
.fb-title { margin: 0; font-family: var(--serif); font-size: 1.22rem; font-weight: 500; line-height: 1.25; }
.fb-byline { margin: 0; font-family: var(--serif); font-style: italic; font-size: 0.82rem; opacity: 0.85; }
.fb-foot { position: relative; display: flex; justify-content: space-between; gap: 8px; border-top: 1px solid color-mix(in srgb, currentColor 26%, transparent); padding-top: 10px; font-family: var(--mono); font-size: 8px; letter-spacing: 0.16em; text-transform: uppercase; opacity: 0.7; }
.fb-series { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Browse */
.browse-masthead { position: relative; padding: clamp(44px, 6vw, 76px) 0 30px; overflow: hidden; }
.browse-masthead::before { content: ""; position: absolute; inset: 0; background: var(--glow); pointer-events: none; }
.browse-title { font-size: clamp(2.1rem, 1.6rem + 2vw, 3.4rem); font-weight: 340; font-style: italic; margin: 0 0 12px; position: relative; }
.browse-sub { color: var(--cream-2); margin: 0; position: relative; max-width: 60ch; }
.search-block { padding: 30px 0 6px; }
.search-label { font-family: var(--mono); font-size: 11px; letter-spacing: 0.18em; text-transform: uppercase; color: var(--cream-2); display: block; margin-bottom: 12px; }
.search-input {
  width: 100%; max-width: 620px; background: var(--raise); color: var(--cream);
  border: 1px solid var(--line); border-radius: var(--radius);
  font-family: var(--serif); font-size: 1.15rem; padding: 14px 18px;
  transition: border-color 220ms ease, box-shadow 220ms ease;
}
.search-input::placeholder { color: var(--cream-3); font-style: italic; }
.search-input:focus { outline: none; border-color: var(--lamp); box-shadow: 0 0 0 3px color-mix(in srgb, var(--lamp) 22%, transparent); }
.filter-block { padding: 24px 0 4px; }
.chips { display: flex; flex-wrap: wrap; gap: 10px; }
.chip {
  display: inline-flex; align-items: baseline; gap: 8px;
  border: 1px solid var(--line); border-radius: var(--radius-pill); padding: 8px 15px;
  font-family: var(--mono); font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--cream-2);
  transition: border-color 200ms ease, color 200ms ease, background 200ms ease;
}
.chip:hover { border-color: var(--lamp); color: var(--lamp); background: color-mix(in srgb, var(--lamp) 8%, transparent); }
.chip-count { color: var(--cream-3); }
.chip-series { border-color: color-mix(in srgb, var(--ember) 55%, transparent); color: var(--ember); }
.browse-grid-wrap { padding: 36px 0 clamp(52px, 6vw, 88px); }
.cover-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 40px 26px; }
.book-card { margin: 0; }
.book-card a { text-decoration: none; display: block; }
.book-card .cover-img, .book-card .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover; border-radius: 8px;
  box-shadow: var(--shadow-deep);
  transition: transform 320ms ease, box-shadow 320ms ease;
}
.book-card a:hover .cover-img, .book-card a:hover .fallback-cover,
.book-card a:focus-visible .cover-img, .book-card a:focus-visible .fallback-cover {
  transform: translateY(-8px); box-shadow: var(--shadow-lift);
}
.card-caption { padding-top: 14px; }
.card-title { font-size: 1.02rem; font-weight: 500; line-height: 1.3; margin: 0 0 5px; }
.card-meta { font-family: var(--mono); font-size: 9.5px; letter-spacing: 0.13em; text-transform: uppercase; color: var(--cream-3); margin: 0; }

/* Book detail — reading layout */
.book-reading { max-width: 880px; margin-inline: auto; padding: clamp(44px, 6vw, 80px) clamp(20px, 4vw, 48px); }
.book-head { display: grid; grid-template-columns: minmax(200px, 280px) 1fr; gap: clamp(28px, 4vw, 56px); align-items: start; margin-bottom: clamp(36px, 5vw, 56px); }
.book-cover-aside .cover-img, .book-cover-aside .fallback-cover {
  width: 100%; aspect-ratio: 2 / 3; object-fit: cover; border-radius: var(--radius);
  box-shadow: var(--shadow-deep), 0 0 90px -30px color-mix(in srgb, var(--lamp) 40%, transparent);
}
.book-title { font-size: clamp(2rem, 1.5rem + 2vw, 3.2rem); font-weight: 380; line-height: 1.14; margin: 0 0 14px; }
.book-byline { font-size: 1.15rem; font-style: italic; color: var(--cream-2); margin: 0 0 26px; }
.book-actions { display: flex; gap: 14px; flex-wrap: wrap; }
.book-description { font-size: 1.16rem; line-height: 1.85; color: var(--cream); max-width: 66ch; margin: 0 0 44px; }
.book-description::first-letter { font-size: 2.6em; float: left; line-height: 0.9; padding-right: 10px; color: var(--lamp); font-weight: 500; }
.praise { margin: 0 0 48px; padding: 30px 34px; background: var(--raise); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow-deep); max-width: 62ch; }
.praise-quote { font-size: 1.35rem; font-style: italic; line-height: 1.6; margin: 0 0 12px; }
.praise-quote::before { content: "“"; color: var(--lamp); }
.praise-quote::after { content: "”"; color: var(--lamp); }
.praise-source { font-family: var(--mono); font-size: 10px; letter-spacing: 0.16em; text-transform: uppercase; color: var(--cream-3); margin: 0; }
.biblio-panel { background: var(--raise); border: 1px solid var(--line); border-radius: var(--radius); padding: 26px 30px; margin: 0 0 44px; box-shadow: var(--shadow-deep); }
.biblio-panel-title { font-family: var(--mono); font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--lamp); margin: 0 0 16px; }
.biblio { margin: 0; }
.biblio-row { display: grid; grid-template-columns: 150px 1fr; gap: 18px; padding: 11px 0; border-top: 1px solid var(--line); }
.biblio dt { font-family: var(--mono); font-size: 10px; letter-spacing: 0.16em; text-transform: uppercase; color: var(--cream-3); margin: 0; padding-top: 3px; }
.biblio dd { margin: 0; font-size: 1.02rem; }
.subject-list { display: flex; flex-wrap: wrap; gap: 8px; list-style: none; margin: 0; padding: 0; }
.subject-list li { font-family: var(--mono); font-size: 9.5px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--cream-2); border: 1px solid var(--line); border-radius: var(--radius-pill); padding: 4px 11px; }
.button {
  display: inline-block; background: var(--lamp); color: #16120E; border-radius: var(--radius-pill);
  font-family: var(--mono); font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; font-weight: 700;
  text-decoration: none; padding: 14px 26px;
  transition: transform 220ms ease, box-shadow 220ms ease;
}
.button:hover { transform: translateY(-2px); box-shadow: 0 12px 30px -12px color-mix(in srgb, var(--lamp) 60%, transparent); }
.button-ghost { background: transparent; color: var(--cream); border: 1px solid var(--line); font-weight: 400; }
.button-ghost:hover { border-color: var(--lamp); color: var(--lamp); box-shadow: none; }

/* Publishers */
.publisher-list { padding: clamp(36px, 5vw, 60px) 0; display: grid; gap: 14px; }
.publisher-row {
  display: grid; grid-template-columns: 1fr auto; gap: 8px 28px; align-items: baseline;
  background: var(--raise); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 22px 26px; text-decoration: none; color: inherit;
  transition: border-color 240ms ease, transform 240ms ease, box-shadow 240ms ease;
}
.publisher-row:hover { border-color: color-mix(in srgb, var(--lamp) 55%, transparent); transform: translateY(-2px); box-shadow: var(--shadow-deep); }
.publisher-name { font-size: 1.4rem; font-weight: 420; margin: 0; }
.publisher-sample { grid-column: 1; font-style: italic; color: var(--cream-2); margin: 0; font-size: 0.98rem; }
.publisher-count { font-family: var(--mono); font-size: 10.5px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--cream-3); grid-row: 1; }
.publisher-count strong { color: var(--lamp); font-weight: 700; }

/* Footer */
.site-footer { border-top: 1px solid var(--line); margin-top: clamp(44px, 6vw, 72px); padding-top: clamp(36px, 5vw, 56px); }
.footer-grid { display: grid; grid-template-columns: 1.4fr 0.8fr 1.4fr; gap: 40px; padding-bottom: 40px; }
.footer-wordmark { font-size: 1.6rem; font-style: italic; font-weight: 420; margin: 0 0 10px; }
.footer-tagline { font-style: italic; color: var(--cream-2); margin: 0; max-width: 30ch; }
.footer-heading { font-family: var(--mono); font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--cream-3); margin: 0 0 14px; }
.footer-nav { display: flex; flex-direction: column; gap: 9px; }
.footer-link { font-family: var(--mono); font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--cream-2); text-decoration: none; width: fit-content; transition: color 200ms ease; }
.footer-link:hover { color: var(--lamp); }
.footer-note { color: var(--cream-2); font-size: 0.95rem; margin: 0 0 10px; max-width: 46ch; }
.footer-legal { border-top: 1px solid var(--line); padding-block: 20px; font-family: var(--mono); font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--cream-3); }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition-duration: 0.01ms !important; }
  html { scroll-behavior: auto; }
}

@media (max-width: 900px) {
  .spotlight { grid-template-columns: 1fr; }
  .spotlight-cover { max-width: 320px; }
  .book-head { grid-template-columns: 1fr; }
  .book-cover-aside { max-width: 300px; }
  .footer-grid { grid-template-columns: 1fr; gap: 30px; }
}
@media (max-width: 720px) {
  .site-nav { display: none; }
  .mobile-menu { display: block; }
}
@media (max-width: 390px) {
  body { font-size: 17px; }
  .cover-grid { grid-template-columns: repeat(2, 1fr); gap: 26px 16px; }
  .shelf { grid-auto-columns: 128px; gap: 18px; }
  .display { font-size: 2.3rem; }
  .masthead-inner { gap: 14px; }
  .lamp-label .lamp-text { display: none; }
  .publisher-row { grid-template-columns: 1fr; }
  .publisher-count { grid-row: auto; }
  .biblio-row { grid-template-columns: 1fr; gap: 3px; }
  .book-description { font-size: 1.08rem; }
}
"""


def night_shelf_item(book: dict) -> str:
    return f"""<figure class="shelf-item">
  <a href="book.html">
    {cover_figure(book, "card")}
    <figcaption class="shelf-caption">
      <p class="shelf-card-title">{esc(book['title'])}</p>
      <p class="shelf-card-meta">{esc(book['publisher'])}</p>
    </figcaption>
  </a>
</figure>"""


def night_card(book: dict) -> str:
    return f"""<figure class="book-card">
  <a href="book.html">
    {cover_figure(book, "card")}
    <figcaption class="card-caption">
      <p class="card-title">{esc(book['title'])}</p>
      <p class="card-meta">{esc(book['publisher'])} · {esc(year_label(book))}</p>
    </figcaption>
  </a>
</figure>"""


def night_pages(ctx: dict) -> dict[str, str]:
    spotlight = ctx["spotlight"]
    books = ctx["books"]
    shelf_recent = books[:12]
    shelf_translation = [book for book in books if book["translators"]]
    shelf_archive = books[12:]
    lamp_toggle = '<label class="lamp-label" for="lamp"><span class="lamp-dot" aria-hidden="true"></span><span class="lamp-text">Reading lamp</span></label>'

    index_body = f"""<input type="checkbox" id="lamp" name="lamp" aria-label="Toggle warm-cream light variant">
<section class="hero">
  <div class="container">
    <p class="kicker">The reading room is open</p>
    <h1 class="display">Stay up late with <em>independent publishing</em>.</h1>
    <p class="hero-lede">{ctx['corpus_total']:,} volumes from {len(ctx['corpus_counts'])} independent presses, shelved by hand and shown by lamplight. Every cover lives in the local cache.</p>
  </div>
</section>
<section class="spotlight container">
  <div class="spotlight-cover">{cover_figure(spotlight, "hero", eager=True)}</div>
  <div class="spotlight-body">
    <p class="kicker">Tonight's reading — {esc(spotlight['publisher'])}</p>
    <h2 class="spotlight-title">{esc(spotlight['title'])}</h2>
    <p class="spotlight-byline">{esc(contributor_line(spotlight))}</p>
    <p class="spotlight-excerpt">{esc(excerpt(spotlight['description'], DESCRIPTION_EXCERPT))}</p>
    <p class="spotlight-meta">{esc(spotlight['format'])} · {esc(year_label(spotlight))}</p>
    <a class="text-link" href="book.html">Open the volume</a>
  </div>
</section>
<section class="shelf-section">
  <div class="container">
    <div class="shelf-head">
      <h2 class="shelf-title">Recently imported</h2>
      <p class="shelf-note">{len(shelf_recent)} volumes</p>
    </div>
    <div class="shelf">
{chr(10).join(night_shelf_item(book) for book in shelf_recent)}
    </div>
    <hr class="shelf-edge">
  </div>
</section>
<section class="shelf-section">
  <div class="container">
    <div class="shelf-head">
      <h2 class="shelf-title">In translation</h2>
      <p class="shelf-note">{len(shelf_translation)} volumes</p>
    </div>
    <div class="shelf">
{chr(10).join(night_shelf_item(book) for book in shelf_translation)}
    </div>
    <hr class="shelf-edge">
  </div>
</section>
<section class="shelf-section">
  <div class="container">
    <div class="shelf-head">
      <h2 class="shelf-title">From the archive</h2>
      <p class="shelf-note">{len(shelf_archive)} volumes</p>
    </div>
    <div class="shelf">
{chr(10).join(night_shelf_item(book) for book in shelf_archive)}
    </div>
    <hr class="shelf-edge">
  </div>
</section>"""

    browse_body = f"""<input type="checkbox" id="lamp" name="lamp" aria-label="Toggle warm-cream light variant">
<section class="browse-masthead">
  <div class="container">
    <p class="kicker">Catalog index</p>
    <h1 class="browse-title">Browse the shelves</h1>
    <p class="browse-sub">{len(books)} volumes sampled from {ctx['corpus_total']:,} records across {len(ctx['corpus_counts'])} independent presses.</p>
  </div>
</section>
<div class="container">
  <div class="search-block" id="catalog-search">
    <label class="search-label" for="q">Search the catalog</label>
    <input class="search-input" id="q" type="search" placeholder="Titles, authors, translators, publishers" autocomplete="off">
  </div>
  <div class="filter-block" id="filters">
    <div class="chips">
{chip_row(books)}
    </div>
  </div>
</div>
<section class="browse-grid-wrap">
  <div class="container">
    <div class="cover-grid">
{chr(10).join(night_card(book) for book in books)}
    </div>
  </div>
</section>"""

    praise_html = ""
    if spotlight["praise"]:
        first = spotlight["praise"][0]
        praise_html = f"""<blockquote class="praise">
  <p class="praise-quote">{esc(first['quote'])}</p>
  <p class="praise-source">— {esc(first['source'])}</p>
</blockquote>"""
    subjects_html = ""
    if spotlight["subjects"]:
        items = "".join(f"<li>{esc(subject)}</li>" for subject in spotlight["subjects"][:8])
        subjects_html = f'<ul class="subject-list">{items}</ul>'
    series_value = ", ".join(spotlight["series"]) if spotlight["series"] else "—"

    book_body = f"""<input type="checkbox" id="lamp" name="lamp" aria-label="Toggle warm-cream light variant">
<article class="book-reading">
  <div class="book-head">
    <aside class="book-cover-aside">{cover_figure(spotlight, "hero", eager=True)}</aside>
    <div class="book-title-block">
      <p class="kicker">Tonight's reading — {esc(spotlight['publisher'])}</p>
      <h1 class="book-title">{esc(spotlight['title'])}</h1>
      <p class="book-byline">{esc(contributor_line(spotlight))}</p>
      <div class="book-actions">
        <a class="button" href="publishers.html">Browse {esc(spotlight['publisher'])}</a>
        <a class="button button-ghost" href="browse.html">Back to the shelves</a>
      </div>
    </div>
  </div>
  <p class="book-description">{esc(excerpt(spotlight['description'], DESCRIPTION_DETAIL))}</p>
  {praise_html}
  <div class="biblio-panel">
    <p class="biblio-panel-title">Bibliographic record</p>
    <dl class="biblio">
      <div class="biblio-row"><dt>Publisher</dt><dd>{esc(spotlight['publisher'])}</dd></div>
      <div class="biblio-row"><dt>Format</dt><dd>{esc(spotlight['format'])}</dd></div>
      <div class="biblio-row"><dt>Published</dt><dd>{esc(spotlight['published_on'] or 'n.d.')}</dd></div>
      <div class="biblio-row"><dt>ISBN-13</dt><dd>{esc(spotlight['isbn'] or 'not recorded')}</dd></div>
      <div class="biblio-row"><dt>Series</dt><dd>{esc(series_value)}</dd></div>
      <div class="biblio-row"><dt>Subjects</dt><dd>{subjects_html or '—'}</dd></div>
    </dl>
  </div>
</article>"""

    publishers_body = night_publishers_body(ctx)

    return {
        "index.html": page_shell("night-reading", "Night Reading", "index", "Home", index_body, lamp_toggle),
        "browse.html": page_shell("night-reading", "Night Reading", "browse", "Browse", browse_body, lamp_toggle),
        "book.html": page_shell("night-reading", "Night Reading", "book", spotlight["title"], book_body, lamp_toggle),
        "publishers.html": page_shell("night-reading", "Night Reading", "publishers", "Publishers", publishers_body, lamp_toggle),
    }


def night_publishers_body(ctx: dict) -> str:
    rows = []
    sampled_by_publisher: dict[str, list[dict]] = {}
    for book in ctx["books"]:
        sampled_by_publisher.setdefault(book["publisher"], []).append(book)
    for publisher in sorted(ctx["corpus_counts"]):
        count = ctx["corpus_counts"][publisher]
        sampled = sampled_by_publisher.get(publisher, [])
        if sampled:
            sample_line = f'<p class="publisher-sample">On the shelves: {esc(sampled[0]["title"])}</p>'
            count_html = f'<p class="publisher-count"><strong>{len(sampled)} sampled</strong> · {count:,} records</p>'
        else:
            sample_line = '<p class="publisher-sample">Not in this sample</p>'
            count_html = f'<p class="publisher-count">{count:,} records</p>'
        rows.append(f"""<a class="publisher-row" href="browse.html">
  <h2 class="publisher-name">{esc(publisher)}</h2>
  {count_html}
  {sample_line}
</a>""")
    return f"""<input type="checkbox" id="lamp" name="lamp" aria-label="Toggle warm-cream light variant">
<section class="browse-masthead">
  <div class="container">
    <p class="kicker">Source registry</p>
    <h1 class="browse-title">Publishers</h1>
    <p class="browse-sub">{len(ctx['corpus_counts'])} approved independent presses; {ctx['corpus_total']:,} source records under provenance.</p>
  </div>
</section>
<section class="publisher-list container">
{chr(10).join(rows)}
</section>"""


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

def write_if_changed(path: Path, content: str) -> bool:
    data = content.encode("utf-8")
    if path.is_file() and path.read_bytes() == data:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return True


def copy_if_changed(src: Path, dest: Path) -> bool:
    if dest.is_file() and dest.stat().st_size == src.stat().st_size:
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
    return True


def main() -> int:
    datasets, corpus_counts = load_datasets()
    corpus_total = sum(corpus_counts.values())
    books = sample_books(datasets)
    spotlight = next((book for book in books if book["praise"]), books[0])
    ctx = {"books": books, "spotlight": spotlight, "corpus_counts": corpus_counts, "corpus_total": corpus_total}

    direction_pages = {
        "gallery": (gallery_pages(ctx), GALLERY_CSS, [
            "newsreader-variable-normal.woff2",
            "newsreader-variable-italic.woff2",
            "space-mono-400-normal.woff2",
            "space-mono-700-normal.woff2",
        ]),
        "ledger": (ledger_pages(ctx), LEDGER_CSS, [
            "newsreader-variable-normal.woff2",
            "newsreader-variable-italic.woff2",
            "space-mono-400-normal.woff2",
            "space-mono-400-italic.woff2",
            "space-mono-700-normal.woff2",
        ]),
        "night-reading": (night_pages(ctx), NIGHT_CSS, [
            "newsreader-variable-normal.woff2",
            "newsreader-variable-italic.woff2",
            "space-mono-400-normal.woff2",
            "space-mono-700-normal.woff2",
        ]),
    }

    written: list[str] = []
    for direction, (pages, css, font_names) in sorted(direction_pages.items()):
        direction_dir = OUT_DIR / direction
        direction_dir.mkdir(parents=True, exist_ok=True)
        for page_name, page_html in sorted(pages.items()):
            if write_if_changed(direction_dir / page_name, page_html):
                written.append(f"{direction}/{page_name}")
        if write_if_changed(direction_dir / "styles.css", css):
            written.append(f"{direction}/styles.css")
        for font_name in font_names:
            if copy_if_changed(FONT_DIR / font_name, direction_dir / "fonts" / font_name):
                written.append(f"{direction}/fonts/{font_name}")
        for book in books:
            for cover_name in (book["cover_full"], book["cover_thumb"]):
                if cover_name and copy_if_changed(COVER_CACHE / cover_name, direction_dir / "covers" / cover_name):
                    written.append(f"{direction}/covers/{cover_name}")

    manifest = {
        "task": "simplify-design-autoingest todo 8",
        "corpus_total_records": corpus_total,
        "corpus_providers": len(corpus_counts),
        "sampled_count": len(books),
        "spotlight_title": spotlight["title"],
        "directions": ["gallery", "ledger", "night-reading"],
        "sampled": [
            {
                "title": book["title"],
                "publisher": book["publisher"],
                "provider": book["provider"],
                "dataset": book["dataset"],
                "year": book["year"],
                "format": book["format"],
                "cover": book["cover_full"],
                "typographic_fallback": book["cover_full"] is None,
            }
            for book in books
        ],
    }
    if write_if_changed(OUT_DIR / "manifest.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n"):
        written.append("manifest.json")

    print(f"sampled {len(books)} volumes from {len(corpus_counts)} providers ({corpus_total:,} records)")
    print(f"spotlight: {spotlight['title']} — {spotlight['publisher']}")
    print(f"files written: {len(written)} (0 means already current)")
    for relative in written:
        print(f"  wrote {relative}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
