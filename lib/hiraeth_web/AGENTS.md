# WEB KNOWLEDGE BASE

## OVERVIEW
Phoenix LiveView browser boundary for public discovery pages.

## STRUCTURE
| Area | Owns |
|---|---|
| `router.ex` | browser scope with hard CSP (self-contained pages), `:ops` JSON pipeline (/health, /ready), `live_session` boundaries |
| `live/` | public LiveViews: home, browse, search, book, edition, publishers, series, contributors (role filter) |
| `components/` | layouts, core components, catalog UI components |
| `public_catalog.ex` | public read facade: raw `Repo.query` SQL projected into PublicProjection structs + `:persistent_term` TTL cache (`clear_cache/0`, `:public_catalog_cache_ttl_ms`) |
| `controllers/` | health probe |

## WHERE TO LOOK
| Task | Location |
|---|---|
| Add public page | `live/*_live.ex`, route in public scope, stable shell DOM id |
| Catalog data for UI | `HiraethWeb.PublicCatalog`, not raw resources in templates |
| Query params/filtering | `catalog_filter_params.ex` (web root) |
| Shared public UI | `components/catalog_components.ex` |
| Layout/current scope | `components/layouts.ex` and router sessions |

## CONVENTIONS
- Build in the existing LiveView/HEEx/Tailwind stack; avoid separate browser runtimes, external script tags, or daisyUI.
- Every LiveView template starts with `<Layouts.app flash={@flash} ...>`.
- Public layouts pass an empty/current public scope.
- Use stable DOM IDs for QA: `home-shell`, `browse-shell`, `catalog-grid`, `search-results`, `book-detail-shell`.
- Use LiveView streams for large or changing collections: parent `phx-update="stream"`, child stream IDs, and re-stream when assigns affect items.
- Forms are driven by `to_form` assigns and `<.input>`; icons use `<.icon>`.
- `PublicCatalog` re-implements the Covers symlink/path guard for the read path (`safe_cached_file_path?`/`no_symlink_components?`); keep cache-path rules in sync across both files.

## ANTI-PATTERNS
- Calling `<.flash_group>` outside `layouts.ex`.
- Accessing changesets directly in templates or using `<.form let=...>`.
- Raw `Phoenix.HTML.form_for`, `live_redirect`, `live_patch`, inline `<script>`, `@apply`.
- Serializing sidecar payloads, SQL rows, or Ash resources directly to the browser.
- Exposing provider IDs, field-level provenance, or source-record URLs in public reading paths.
