# Hiraeth Architecture

Hiraeth is an Elixir-first Phoenix application for browsing carefully curated indie publisher and bookstore catalogs. The initial product emphasizes rich, provenance-backed book metadata and beautiful catalog discovery rather than public social networking.

## Stack boundaries

- LiveView owns the browser UI. Phoenix LiveView, HEEx templates, Phoenix components, Tailwind CSS, and `assets/js/app.js` / `assets/css/app.css` are the only v1 browser UI surface.
- No React, no Vite SPA, and no separate frontend application in v1.
- Use the `agy` CLI for UI design exploration before substantial visual implementation work.
- JSON APIs are not part of v1 unless a later task explicitly adds a narrow integration endpoint.

## Domain model ownership

- Ash resources and Ash actions are the domain source of truth for catalog, source, cover, import, search, audit, and account behavior.
- AshPostgres owns persistence mapping for Ash resources.
- AshPhoenix owns Phoenix-facing form, route, and LiveView integration where needed.
- Controllers, LiveViews, and templates should orchestrate user interaction, not contain catalog business rules.

## Background work boundary

- No Oban in v1. Imports, normalization, cover processing, and provenance audits should remain synchronous or Mix-task driven until a later task proves background scheduling is required.
- If background jobs are introduced later, they must keep provenance and idempotency semantics explicit. Add Oban only in a future plan when imports exceed synchronous limits or enrichment/audit work requires retries, scheduling, cancellation, or replay controls.

## Data and provenance rules

- Tests must use deterministic fixtures for publishers, books, contributors, editions, external identifiers, imports, and covers.
- Do not use random data or Faker-style generators for catalog/import tests.
- Do not scrape publisher or bookstore websites. Use explicit fixtures, user-provided files, documented public APIs, or sources with clear permission.
- Every imported metadata value and cover asset should be traceable to a source provider, source record, and import run.


## Public discovery surfaces

The public LiveView catalog currently exposes home, browse, search, publisher, series, contributor, and book detail routes. Contributor discovery is role-aware through query filters such as `/contributors?role=translator`; author and translator pages remain one contributor surface instead of separate social/profile systems. Browse and search filters are URL-backed so publisher, contributor role, format, language, year, subject, series, and sort state can be shared without client-side in-memory filtering.

Book detail, publisher, and series pages surface enriched source-backed metadata only when present: descriptions, storefront links, original language/title, subjects, edition language, page counts, dimensions, ISBNs, formats, and field-level provenance.

## v1 product scope

- Focus on elegant browsing for indie publishers and selected bookstore catalogs.
- Public social features, reviews, follows, activity feeds, and Letterboxd-style networking are out of scope for this project version.
