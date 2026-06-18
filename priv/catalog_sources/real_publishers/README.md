# Real publisher catalog sources

This directory contains Hiraeth's curated real-book pilot dataset: 50 factual edition records each for Deep Vellum, Dalkey Archive, Archipelago Books, and New Directions. Transit Books is approved only as a future source-policy gate; no Transit records, fixtures, or covers are checked in yet.

## New Directions provider gate and fixture

New Directions is the fourth curated provider. The checked-in fixture is a deterministic 50-record factual metadata batch derived from official New Directions catalog/book pages under the gate below. It keeps covers as explicit no-cover fallbacks because local cover-cache permission has not been recorded.

- Provider slug: `new_directions_official_site`.
- Official source URL: `https://www.ndbooks.com/books/`.
- Permission URL: `https://www.ndbooks.com/permissions/`.
- Contact/takedown URL: `https://www.ndbooks.com/about/contact/`.
- Allowed source host: `www.ndbooks.com`.
- Observed cover host for public book-grid images: `cdn.sanity.io`.
- Explicitly excluded hosts for this gate: `ndpublishing.myshopify.com` storefront/account links and any off-host cover source.
- Permission/provenance note: use only source-backed factual bibliographic metadata from official New Directions pages or a checked-in deterministic fixture derived from an approved source. Preserve provider, source URL, field provenance, and import-run evidence for every imported value.
- Cover cache policy: `link_only_until_explicit_cache_permission`; do not cache New Directions covers locally unless a later provider policy records explicit cache permission.
- Excluded content: raw HTML, jacket-copy dumps, author bios, reviews, user reviews, prices, inventory, availability, cart/checkout/account data, and unsupported long prose.
- Takedown/contact note: route removal/correction requests through the same cover takedown flow used by the pilot dataset, then update fixtures with source notes; New Directions lists permissions/contact paths on its official site.
- Not legal advice: this gate is an engineering provenance control, not a legal conclusion.

`Hiraeth.RealCatalog.SourcePolicy` also exposes the machine-readable expansion
policy for New Directions. Its `provider_permission_metadata!/1` projection
mirrors the JSON `provider_permissions` shape included in the fixture, while
`source_uri_allowed?/2` and `cover_uri_allowed?/2` keep New
Directions sources limited to `www.ndbooks.com` and `cdn.sanity.io`. The current
New Directions cover policy remains `link_only_until_explicit_cache_permission`;
records therefore use `no_cover_reason` and do not create cover assignments until
a later task records explicit cache permission or link-only rendering behavior.


## Transit Books provider gate (future fixture only)

Transit Books is registered as an expansion provider gate for a future deterministic fixture. This gate allows only factual bibliographic metadata from official Transit Books source surfaces and keeps all covers disallowed until explicit cover permission is recorded. No Transit catalog records, source fixture payloads, or cover files are included in this directory.

- Provider slug: `transit_books_official_site`.
- Official catalog source URLs: `https://www.transitbooks.org/books` and `https://www.transitbooks.org/catalogs`.
- Permission URL: `https://www.transitbooks.org/rights`.
- Contact/takedown URL: `https://www.transitbooks.org/about` (with rights requests routed through the rights page when applicable).
- Allowed source host: `www.transitbooks.org` only.
- Allowed cover hosts: none. Transit covers are not approved for link rendering or local cache in this policy gate.
- Permission/provenance note: use only source-backed factual bibliographic metadata from official Transit pages or a later checked-in deterministic fixture derived from approved sources. Preserve provider, source URL, field provenance, and import-run evidence for every imported value.
- Cover cache policy: `no_covers_until_explicit_permission`; do not import, hotlink, link-only render, or locally cache Transit cover images unless a later provider policy records explicit permission.
- Excluded content: raw HTML, jacket-copy dumps, author bios, reviews, user reviews, prices, inventory, availability, cart/checkout/account data, cover images, and unsupported long prose.
- Not legal advice: this gate is an engineering provenance control, not a legal conclusion.

`Hiraeth.RealCatalog.SourcePolicy` exposes the Transit gate so a future fixture can
be machine-checked before import. The provider-permission projection intentionally
uses an empty cover-host list and `no_covers_until_explicit_permission`, so cover
validation rejects Transit cover URLs and `cover_cache_allowed?/1` remains false.

## Source URLs

- Deep Vellum: official Shopify product JSON and product pages under `https://store.deepvellum.org/products/...`; source probe: `https://store.deepvellum.org/products.json?limit=250`.
- Dalkey Archive: official Shopify product JSON and product pages under `https://dalkeyarchive.store/products/...`; source probes: `https://dalkeyarchive.store/products.json?limit=250` and `https://dalkeyarchive.store/collections/dalkey-archive-essentials/products.json?limit=250`.
- Archipelago Books: official WooCommerce/WordPress product data and product pages under `https://archipelagobooks.org/book/...`; source probe: `https://archipelagobooks.org/wp-json/wc/store/products?per_page=100&page=1`.
- New Directions: official catalog and book pages under `https://www.ndbooks.com/books/` and `https://www.ndbooks.com/book/...`; cover URLs are observed from `cdn.sanity.io` but are not cached in this fixture.
- Transit Books: future fixture gate only; official catalog/source surfaces under `https://www.transitbooks.org/books`, `https://www.transitbooks.org/catalogs`, `https://www.transitbooks.org/rights`, and `https://www.transitbooks.org/about`; no Transit records or covers are checked in.

## Included metadata

Only factual bibliographic/display metadata is stored by default: title, contributor names and roles, publisher/imprint, edition format, publication date when structured, ISBN-13, source URL, and cacheable cover provenance or explicit no-cover fallback reason. The schema also permits public prose fields (`description`, `synopsis`, `editorial_praise`, and `storefront_url`) only when they are explicitly sourced to the same allowlisted official source URI and covered by the dataset license note. The tracked publisher records currently omit prose unless a curated source payload supplies it; do not fabricate missing descriptions or add user reviews.

## Excluded content

The dataset intentionally excludes unsourced jacket copy, blurbs, author bios, user reviews, prices, inventory status, availability, cart/checkout/account data, raw HTML, rendered content dumps, and any long unapproved prose fields.

## Cover and rights assumptions

Covers are imported from explicit source URLs in the first three provider fixtures and marked `cache_allowed` so the app can maintain local cached originals and card thumbnails. New Directions records intentionally omit cover assets and carry `no_cover_reason` until a later policy records safe link-only or local-cache behavior. Transit Books has no checked-in records and its future-provider gate disallows all cover hosts, link rendering, and local caching until explicit permission is recorded. Each imported cover carries provider, rights basis, attribution text/link, and is subject to takedown handling in the application.

The tracked records use `rights_basis: local_cache_permitted` only for cover URLs explicitly included in this repository dataset. Any future publisher, bookstore, or bulk-source expansion must document the source permission model before switching covers to `cache_allowed`.

## Takedown/contact policy

If a rights holder asks for removal or correction, hide the relevant cover assignment through the admin cover takedown flow first, then update or remove the dataset record in a follow-up commit with source notes preserved. Publisher/source links should remain auditable in source records unless legal removal requires otherwise.

## Validation

Run:

```bash
MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs --trace
```

The validator requires exactly 50 approved records per provider, valid ISBN-13 values, approved formats, HTTPS allowlisted source/cover hosts or explicit no-cover reasons, no duplicate ISBNs, no non-book formats/SKUs, no commerce state, no raw HTML/content dumps, and provenance for every approved public prose field.
