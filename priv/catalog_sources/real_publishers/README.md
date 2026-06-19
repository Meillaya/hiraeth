# Real publisher catalog sources

This directory contains Hiraeth's production real-book corpus for eighteen approved providers: Deep Vellum (352 records), Dalkey Archive (944), Archipelago Books (497), New Directions (2,389), Transit Books (66), Historical Materialism (384), Semiotext(e) (265), Phoneme Media (78), A Strange Object (35), La Reunion (32), Fum d'Estampa (2), NYRB (859), Tilted Axis Press (109), McNally Editions (66), Seven Stories Press (703), Unnamed Press (159), Pushkin Press (74), and Fitzcarraldo Editions (392), for 7,406 checked-in records total. Public covers render only from local cached `/covers/cache/...` URLs; missing, uncached, hidden, or unsafe covers render typographic fallbacks.

Exact completeness statement: the imported production-grade corpus is the full approved checked-in source corpus for the current eighteen providers. It is not a claim that Hiraeth has every historically published title from those publishers. Missing cover URLs, uncached cover assets, missing purchase links, missing reviews, and missing/pre-ISBN identifiers are represented as explicit gap states instead of being fabricated or silently treated as complete.

## Provider gates and fixtures

New Directions and Transit Books retain explicit runtime provider gates in `Hiraeth.RealCatalog.SourcePolicy` because they were the first official-page expansion providers. All eighteen providers are now governed by `source_authority_manifest.json`, provider-specific source/cover host allowlists, deterministic checked-in datasets, and the same validator contract.

### New Directions

New Directions is a curated provider. The checked-in corpus is a deterministic 2,389-record factual metadata batch derived from official New Directions catalog/book pages. Records include source-backed cover URLs; public display still depends on local cache availability and cover policy checks.

- Provider slug: `new_directions_official_site`.
- Official source URLs: `https://www.ndbooks.com/books/`, `https://www.ndbooks.com/sitemap-index.xml`, and `https://www.ndbooks.com/sitemap-0.xml`.
- Contact/takedown URLs: `https://www.ndbooks.com/permissions/` and `https://www.ndbooks.com/about/contact/`.
- Allowed source host: `www.ndbooks.com`.
- Allowed cover hosts: `cdn.sanity.io` and bounded OpenLibrary cover enrichment.

### Transit Books

Transit Books is a curated provider. The checked-in corpus is a deterministic 66-record factual metadata batch derived from official Transit Books catalog/books surfaces. Records include source-backed cover URLs from allowlisted Squarespace image hosts; public display still depends on local cache availability and cover policy checks.

- Provider slug: `transit_books_official_site`.
- Official catalog source URLs: `https://www.transitbooks.org/books` and `https://www.transitbooks.org/catalogs`.
- Checked-in corpus: `transit_books.json`, with 66 records whose `source_uri` values point to official Transit books/catalog pages.
- Contact/takedown URL: `https://www.transitbooks.org/about` (with rights/contact surface at `https://www.transitbooks.org/rights`).
- Allowed source host: `www.transitbooks.org` only.
- Allowed cover hosts: `images.squarespace-cdn.com`, `static1.squarespace.com`, and bounded OpenLibrary cover enrichment where present.

### Additional imported publishers

- Historical Materialism: official book-series pages under `https://www.historicalmaterialism.org/book-series/`; 384 source-backed records.
- Semiotext(e): official listing at `https://www.semiotexte.com/books-1`; 265 source-backed records.
- Phoneme Media: Deep Vellum official store product feed rows with vendor `Phoneme`; 78 ISBN-bearing records.
- A Strange Object: Deep Vellum official store product feed rows with vendor `A Strange Object`; 35 ISBN-bearing records.
- La Reunion: Deep Vellum official store product feed rows with vendor `La Reunion`; 32 ISBN-bearing records.
- Fum d'Estampa: Deep Vellum official store product feed rows with vendor `Fum d'Estampa`; 2 ISBN-bearing records.
- NYRB: official Shopify collection feeds for NYRB Classics, New York Review Books, and NYRB Poets; 859 source-backed edition records with series memberships.
- Tilted Axis Press: official Squarespace shop collection JSON linked from `/books`; 109 source-backed records.
- McNally Editions: official Squarespace Books collection JSON; 66 source-backed records.
- Seven Stories Press: official Seven Stories Press imprint listing pages; 703 source-backed records imported with ISBN/detail gaps where listing pages omit them.
- Unnamed Press: official Squarespace All Books collection JSON; 159 source-backed records.
- Pushkin Press: official WordPress book API for Pushkin Press Classics; 74 source-backed records with `Pushkin Press Classics` series memberships.
- Fitzcarraldo Editions: official shop category and book pages for Fiction, Essays, and Poetry; 392 source-backed edition records with `Fitzcarraldo Editions Fiction`, `Fitzcarraldo Editions Essays`, and `Fitzcarraldo Editions Poetry` series memberships.

## Source authority manifest

`source_authority_manifest.json` is the execution checklist for regenerating or expanding the production corpus. It defines the eighteen-provider scope, the approved-source-corpus completeness boundary, source/API/page allowlists, blocked unsafe modes, review excerpt rules, ISBN enrichment precedence, and bounded network requirements. Full catalog work must update that manifest before adding or replacing records, and tests treat it as the source of truth for whether a provider is available, partial, or expansion-blocked.

`source_artifacts_manifest.json` records the deterministic checked-in source artifacts used for this corpus. `source_coverage_report.json` records the generated provider-level coverage/gap report consumed by coverage checks and final release checks.

Important current states:

- Deep Vellum, Dalkey Archive, Archipelago Books, Phoneme Media, A Strange Object, La Reunion, and Fum d'Estampa have approved machine-readable commerce/catalog feeds that may be used as official source artifacts under bounded retrieval.
- New Directions, Transit Books, Historical Materialism, Semiotext(e), Seven Stories Press, and Pushkin Press are approved for deterministic official page/API/catalog extraction and source-backed cover URLs from allowlisted hosts.
- NYRB, Tilted Axis Press, McNally Editions, Unnamed Press, and Fitzcarraldo Editions have approved official Shopify/Squarespace collection feeds or JSON collection exports for bounded refreshes.

## Source URLs

- Deep Vellum: official Shopify product JSON and product pages under `https://store.deepvellum.org/products/...`; source probe: `https://store.deepvellum.org/products.json?limit=250`.
- Dalkey Archive: official Shopify product JSON and product pages under `https://dalkeyarchive.store/products/...`; source probes: `https://dalkeyarchive.store/products.json?limit=250` and `https://dalkeyarchive.store/collections/dalkey-archive-essentials/products.json?limit=250`.
- Archipelago Books: official WooCommerce/WordPress product data and product pages under `https://archipelagobooks.org/book/...`; source probe: `https://archipelagobooks.org/wp-json/wc/store/products?per_page=100&page=1`.
- New Directions: official catalog and book pages under `https://www.ndbooks.com/books/` and `https://www.ndbooks.com/book/...`; cover hosts `cdn.sanity.io` and bounded OpenLibrary cover enrichment are allowlisted.
- Transit Books: official catalog/source surfaces under `https://www.transitbooks.org/books` and `https://www.transitbooks.org/catalogs`; cover hosts `images.squarespace-cdn.com`, `static1.squarespace.com`, and bounded OpenLibrary cover enrichment are allowlisted.
- Historical Materialism: official book-series pages under `https://www.historicalmaterialism.org/book-series/...`; cover host `www.historicalmaterialism.org` is allowlisted.
- Semiotext(e): official book listing/cards under `https://www.semiotexte.com/books-1`; Squarespace image hosts are allowlisted.
- Phoneme Media, A Strange Object, La Reunion, and Fum d'Estampa: official Deep Vellum Shopify product JSON plus product pages under `https://store.deepvellum.org/products/...`; `cdn.shopify.com` cover URLs are allowlisted.
- NYRB: official Shopify collection JSON under `https://www.nyrb.com/collections/.../products.json` plus product pages under `https://www.nyrb.com/products/...`; `cdn.shopify.com` cover URLs are allowlisted.
- Tilted Axis Press, McNally Editions, and Unnamed Press: official Squarespace JSON collection exports plus source pages under their `/shop`, `/books`, and `/all-books` paths; Squarespace image hosts are allowlisted.
- Seven Stories Press: official imprint listing pages and book pages under `https://www.sevenstories.com/imprints/seven-stories-press` and `/books/...`; `sevenstories-prod.s3.amazonaws.com` cover URLs are allowlisted.
- Pushkin Press: official WordPress REST book API for the Pushkin Press Classics imprint and book pages under `https://us.pushkinpress.com/book/...`; `us.pushkinpress.com` cover URLs are allowlisted.

## Included metadata

Only factual bibliographic/display metadata is stored by default: title, contributor names and roles, publisher/imprint, edition format, publication date when structured, ISBN-13 when available, source URL/source-record identity, and cacheable cover provenance or explicit no-cover fallback reason. The schema also permits public prose fields (`description`, `synopsis`, `editorial_praise`, and `storefront_url`) only when they are explicitly sourced to the same allowlisted official source URI and covered by the dataset license note. Review metadata is link-first: `review_links` may point to approved source/review references, and displayable excerpts require an explicit `rights_basis` such as `publisher_supplied`, `licensed_excerpt`, or `explicit_authorization`. The tracked publisher records omit prose only when no curated source payload supplies it; do not fabricate missing descriptions, purchase links, reviews, or user reviews.

## Excluded content

The dataset intentionally excludes unsourced jacket copy, blurbs, author bios, user reviews, prices, inventory status, availability, cart/checkout/account data, raw HTML, rendered content dumps, and any long unapproved prose fields.

## Cover and rights assumptions

Covers are imported from explicit source URLs in provider fixtures and marked `cache_allowed` only when the app can maintain local cached originals and card thumbnails. The current corpus has source-backed cover assignments for records whose approved source includes a cover URL; records without cover URLs carry explicit gap states. Each imported cover carries provider, rights basis, attribution text/link, local cache path, thumbnail path, and is subject to takedown handling in the application.

The tracked records use `rights_basis: local_cache_permitted` only for cover URLs explicitly included in this repository dataset. Any future publisher, bookstore, or bulk-source expansion must document the source/provenance model before switching covers to `cache_allowed`.

## Takedown/contact policy

If a rights holder asks for removal or correction, hide the relevant cover assignment through the cover takedown state first, then update or remove the dataset record in a follow-up commit with source notes preserved. Publisher/source links should remain auditable in source records unless legal removal requires otherwise.

## Validation

Run:

```bash
MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs --trace
```

The validator uses `source_authority_manifest.json` for expected provider counts. Current fixtures require 7,406 approved records across eighteen providers, valid ISBN-13 values when present, explicit `missing_fields.isbn_13` for source-only/pre-ISBN records, approved formats, HTTPS allowlisted source/cover hosts or explicit no-cover reasons, no duplicate ISBNs among ISBN-bearing records, no non-book formats/SKUs, no commerce state, no raw HTML/content dumps, and provenance for every approved public prose or review-excerpt field.

Additional deterministic corpus checks:

```bash
mix hiraeth.real_catalog.source_artifacts --dataset-dir priv/catalog_sources/real_publishers --output priv/catalog_sources/real_publishers/source_artifacts_manifest.json
mix hiraeth.real_catalog.coverage_report --dataset-dir priv/catalog_sources/real_publishers --output priv/catalog_sources/real_publishers/source_coverage_report.json
```
