defmodule Hiraeth.Catalog.PublicProjection.Source do
  @moduledoc "Source provenance summary for public catalog metadata."

  @behaviour Access

  @enforce_keys [:source_record_id, :provider, :source_type, :source_uri]
  defstruct [
    :id,
    :source_record_id,
    :provider,
    :source_type,
    :source_uri,
    :license_note,
    :import_run_id,
    :imported_at,
    :source_identity,
    field_sources: %{},
    provider_permissions: %{}
  ]

  defdelegate fetch(projection, key), to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate get_and_update(projection, key, function),
    to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate pop(projection, key), to: Hiraeth.Catalog.PublicProjection.Access
end
