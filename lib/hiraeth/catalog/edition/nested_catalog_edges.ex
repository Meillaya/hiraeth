defmodule Hiraeth.Catalog.Edition.NestedCatalogEdges do
  @moduledoc false

  alias Hiraeth.Catalog.{Contribution, Contributor, Identifier}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}

  def apply!(changeset, edition, actor) do
    contributor = Ash.Changeset.get_argument(changeset, :contributor) || %{}
    identifier = Ash.Changeset.get_argument(changeset, :identifier) || %{}
    cover = Ash.Changeset.get_argument(changeset, :cover) || %{}

    with {:ok, _contributor_name} <- create_contributor(edition, contributor, actor),
         {:ok, _identifier_value} <- create_identifier(edition, identifier, actor),
         {:ok, _cover_status} <- create_cover_assignment(edition, cover, actor) do
      {:ok, edition}
    end
  end

  defp create_contributor(edition, params, actor) do
    display_name = required_param(params, "display_name")

    contributor =
      Contributor
      |> Ash.Changeset.for_create(:create, %{
        display_name: display_name,
        sort_name: blank_to_nil(params["sort_name"]),
        slug: blank_to_nil(params["slug"]) || slugify(display_name)
      })
      |> Ash.create!(actor: actor)

    Contribution
    |> Ash.Changeset.for_create(:create, %{
      contributor_id: contributor.id,
      edition_id: edition.id,
      role: blank_to_nil(params["role"]) || "author",
      position: 1
    })
    |> Ash.create!(actor: actor)

    {:ok, contributor.display_name}
  rescue
    error -> {:error, error}
  end

  defp create_identifier(edition, params, actor) do
    value = required_param(params, "value")

    Identifier
    |> Ash.Changeset.for_create(:create, %{
      identifier_type: blank_to_nil(params["identifier_type"]) || "isbn_13",
      value: value,
      edition_id: edition.id
    })
    |> Ash.create!(actor: actor)

    {:ok, value}
  rescue
    error -> {:error, error}
  end

  defp create_cover_assignment(_edition, params, _actor) when params in [%{}, nil],
    do: {:ok, :skipped}

  defp create_cover_assignment(edition, params, actor) do
    if Enum.any?(~w(provider source_url rights_basis), &(blank_to_nil(params[&1]) != nil)) do
      asset =
        CoverAsset
        |> Ash.Changeset.for_create(:create, %{
          provider: required_param(params, "provider"),
          source_url: required_param(params, "source_url"),
          rights_basis: required_param(params, "rights_basis"),
          cache_policy: "link_only",
          attribution_text:
            blank_to_nil(params["attribution_text"]) || blank_to_nil(params["attribution"])
        })
        |> Ash.create!(actor: actor)

      CoverAssignment
      |> Ash.Changeset.for_create(:create, %{
        edition_id: edition.id,
        cover_asset_id: asset.id,
        position: 1
      })
      |> Ash.create!(actor: actor)
    end

    {:ok, :cover_saved}
  rescue
    error -> {:error, error}
  end

  defp required_param(params, key),
    do: blank_to_nil(params[key]) || raise(ArgumentError, "#{key} is required")

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp slugify(value) do
    base =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "#{base}-#{System.unique_integer([:positive])}"
  end
end
