# Real publisher catalog sources

This directory contains Hiraeth's first curated real-book pilot dataset: 50 factual edition records each for Deep Vellum, Dalkey Archive, and Archipelago Books.

## Next provider gate: New Directions

New Directions is the default next expansion candidate, but this gate is not an import authorization by itself. It is a preflight record that must stay machine-checkable before any New Directions fixture or cover data is added.

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

## Source URLs

- Deep Vellum: official Shopify product JSON and product pages under `https://store.deepvellum.org/products/...`; source probe: `https://store.deepvellum.org/products.json?limit=250`.
- Dalkey Archive: official Shopify product JSON and product pages under `https://dalkeyarchive.store/products/...`; source probes: `https://dalkeyarchive.store/products.json?limit=250` and `https://dalkeyarchive.store/collections/dalkey-archive-essentials/products.json?limit=250`.
- Archipelago Books: official WooCommerce/WordPress product data and product pages under `https://archipelagobooks.org/book/...`; source probe: `https://archipelagobooks.org/wp-json/wc/store/products?per_page=100&page=1`.

## Included metadata

Only factual bibliographic/display metadata is stored by default: title, contributor names and roles, publisher/imprint, edition format, publication date when structured, ISBN-13, source URL, and cacheable cover provenance. The schema also permits public prose fields (`description`, `synopsis`, `editorial_praise`, and `storefront_url`) only when they are explicitly sourced to the same allowlisted official source URI and covered by the dataset license note. The tracked publisher records currently omit prose unless a curated source payload supplies it; do not fabricate missing descriptions or add user reviews.

## Excluded content

The dataset intentionally excludes unsourced jacket copy, blurbs, author bios, user reviews, prices, inventory status, availability, cart/checkout/account data, raw HTML, rendered content dumps, and any long unapproved prose fields.

## Cover and rights assumptions

Covers are imported from explicit source URLs in this repository dataset and marked `cache_allowed` so the app can maintain local cached originals and card thumbnails. Each cover carries provider, rights basis, attribution text/link, and is subject to takedown handling in the application.

The tracked records use `rights_basis: local_cache_permitted` only for cover URLs explicitly included in this repository dataset. Any future publisher, bookstore, or bulk-source expansion must document the source permission model before switching covers to `cache_allowed`.

## Takedown/contact policy

If a rights holder asks for removal or correction, hide the relevant cover assignment through the admin cover takedown flow first, then update or remove the dataset record in a follow-up commit with source notes preserved. Publisher/source links should remain auditable in source records unless legal removal requires otherwise.

## Validation

Run:

```bash
MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs --trace
```

The validator requires exactly 50 approved records per provider, valid ISBN-13 values, approved formats, HTTPS allowlisted source/cover hosts, no duplicate ISBNs, no non-book formats/SKUs, no commerce state, no raw HTML/content dumps, and provenance for every approved public prose field.
