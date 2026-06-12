defmodule Hiraeth.Sources do
  use Ash.Domain

  alias Hiraeth.Sources.CurationOverride

  resources do
    resource Hiraeth.Sources.SourceRecord
    resource Hiraeth.Sources.CurationOverride
    resource Hiraeth.Sources.SourceLedgerEntry
  end

  def resolve_value(entity_type, entity_id, field_name, raw_value, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    override =
      CurationOverride
      |> Ash.Query.for_read(:by_entity_field, %{
        entity_type: entity_type,
        entity_id: entity_id,
        field_name: field_name
      })
      |> Ash.read_one!(actor: actor)

    case override do
      nil -> raw_value
      %{curated_value: nil} -> raw_value
      %{curated_value: curated_value} -> curated_value
    end
  end
end
