defmodule Hiraeth.Catalog.PublicProjection.Cover do
  @moduledoc "Publicly renderable local cover projection."

  @behaviour Access

  defstruct [
    :source_url,
    :public_url,
    :provider,
    :rights_basis,
    :attribution_text,
    :attribution_url,
    :cache_policy,
    :takedown_state,
    :cached_file_path,
    :thumbnail_file_path,
    :thumbnail_url
  ]

  defdelegate fetch(projection, key), to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate get_and_update(projection, key, function),
    to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate pop(projection, key), to: Hiraeth.Catalog.PublicProjection.Access
end
