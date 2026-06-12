defmodule Hiraeth.Covers do
  use Ash.Domain

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}

  resources do
    resource Hiraeth.Covers.CoverAsset
    resource Hiraeth.Covers.CoverAssignment
  end

  def fallback_cover do
    %{
      source_url: nil,
      provider: "hiraeth",
      rights_basis: "fallback_placeholder",
      cache_policy: "generated_placeholder",
      attribution_text: "No public cover available"
    }
  end

  def public_cover_for_edition(edition_id) do
    assignment =
      CoverAssignment
      |> Ash.Query.for_read(:public_for_edition, %{edition_id: edition_id})
      |> Ash.read!()
      |> Ash.load!(:cover_asset)
      |> Enum.find(fn assignment -> public_cover_asset?(assignment.cover_asset) end)

    case assignment do
      nil -> fallback_cover()
      %{cover_asset: cover_asset} -> public_cover_map(cover_asset)
    end
  end

  def audit_public_cover_provenance!(path) do
    assignments =
      CoverAssignment
      |> Ash.Query.for_read(:public)
      |> Ash.read!()
      |> Ash.load!([:cover_asset, :edition])

    invalid_public_covers =
      assignments
      |> Enum.reject(fn assignment -> public_cover_asset?(assignment.cover_asset) end)
      |> Enum.map(fn assignment ->
        %{
          cover_assignment_id: assignment.id,
          cover_asset_id: assignment.cover_asset_id,
          edition_id: assignment.edition_id,
          reason: "public assignment does not have valid visible cover provenance"
        }
      end)

    audit = %{
      checked_public_assignments: Enum.count(assignments),
      invalid_public_covers: invalid_public_covers
    }

    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(audit, pretty: true))

    audit
  end

  defp public_cover_asset?(%CoverAsset{} = cover_asset) do
    cover_asset.takedown_state == "visible" and present?(cover_asset.source_url) and
      present?(cover_asset.provider) and present?(cover_asset.rights_basis)
  end

  defp public_cover_map(%CoverAsset{} = cover_asset) do
    %{
      id: cover_asset.id,
      source_url: cover_asset.source_url,
      provider: cover_asset.provider,
      rights_basis: cover_asset.rights_basis,
      attribution_text: cover_asset.attribution_text,
      attribution_url: cover_asset.attribution_url,
      cache_policy: cover_asset.cache_policy,
      cached_file_path: cover_asset.cached_file_path
    }
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
