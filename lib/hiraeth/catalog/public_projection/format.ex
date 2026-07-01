defmodule Hiraeth.Catalog.PublicProjection.Format do
  @moduledoc "Edition-format summary nested under a public book."

  @behaviour Access

  @enforce_keys [:edition_slug, :format_label, :identifiers]
  defstruct [
    :edition_slug,
    :format,
    :format_label,
    :source_identity,
    :published_on,
    :language_code,
    :page_count,
    :height_mm,
    :width_mm,
    :depth_mm,
    :dimensions,
    identifiers: []
  ]

  defdelegate fetch(projection, key), to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate get_and_update(projection, key, function),
    to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate pop(projection, key), to: Hiraeth.Catalog.PublicProjection.Access
end
