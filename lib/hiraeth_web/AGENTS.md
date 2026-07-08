# WEB KNOWLEDGE BASE

## OVERVIEW
Phoenix LiveView browser boundary for public discovery pages and admin ingestion/quarantine tools.

## STRUCTURE
| Area | Owns |
|---|---|
| `router.ex` | browser/admin scopes, pipelines, `live_session` boundaries |
| `live/` | public LiveViews: home, browse, search, books, publishers, series |
| `live/admin/` | admin ingestion/quarantine/provider/run/candidate surfaces |
| `components/` | layouts, core components, catalog UI components |
| `public_catalog.ex` | public query/filter/projection facade used by LiveViews |
| `controllers/admin_auth.ex` | admin session plugs and LiveView `on_mount` auth |

## WHERE TO LOOK
| Task | Location |
|---|---|
| Add public page | `live/*_live.ex`, route in public scope, stable shell DOM id |
| Add admin page | `live/admin/*`, admin scope + `live_session :admin` |
| Catalog data for UI | `HiraethWeb.PublicCatalog`, not raw resources in templates |
| Query params/filtering | `live/helpers/catalog_filter_params.ex` |
| Shared public UI | `components/catalog_components.ex` |
| Layout/current scope | `components/layouts.ex` and router sessions |

## CONVENTIONS
- Build in the existing LiveView/HEEx/Tailwind stack; avoid separate browser runtimes, external script tags, or daisyUI.
- Every LiveView template starts with `<Layouts.app flash={@flash} ...>`.
- Public layouts pass an empty/current public scope; admin layouts pass `%{admin: @current_admin_user}`.
- Keep public and admin route scopes separate; admin uses dedicated pipeline plus `on_mount` authorization.
- Use stable DOM IDs for QA: `home-shell`, `browse-shell`, `catalog-grid`, `search-results`, `book-detail-shell`, `admin-ingestion-shell`, `admin-quarantine-*`.
- Use LiveView streams for large or changing collections: parent `phx-update="stream"`, child stream IDs, and re-stream when assigns affect items.
- Forms are driven by `to_form` assigns and `<.input>`; icons use `<.icon>`.

## ANTI-PATTERNS
- Calling `<.flash_group>` outside `layouts.ex`.
- Accessing changesets directly in templates or using `<.form let=...>`.
- Raw `Phoenix.HTML.form_for`, `live_redirect`, `live_patch`, inline `<script>`, `@apply`.
- Serializing sidecar payloads, SQL rows, or Ash resources directly to the browser.
- Exposing provider IDs, field-level provenance, or source-record URLs in public reading paths.
- Reusing admin components in public pages when they leak operator/provenance detail.
