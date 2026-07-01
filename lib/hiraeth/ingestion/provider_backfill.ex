defmodule Hiraeth.Ingestion.ProviderBackfill do
  @moduledoc """
  Builds and applies the canonical ingestion provider registry.
  """

  alias Hiraeth.Ingestion.{ProviderBackfill.Inventory, ProviderSource}

  @catalog_writer %{id: "provider-backfill", catalog_write?: true}

  def build_inventory(opts \\ []), do: Inventory.build(opts)

  def dry_run(opts \\ []) do
    {:ok, providers} = build_inventory(opts)

    %{
      dry_run: true,
      total: length(providers),
      providers: Enum.map(providers, &serialize_provider/1)
    }
  end

  def apply!(opts \\ []) do
    {:ok, providers} = build_inventory(opts)
    existing = Ash.read!(ProviderSource, authorize?: false)
    existing_by_key = Map.new(existing, &{&1.stable_source_key, &1})

    summary =
      Enum.reduce(providers, %{created: 0, updated: 0}, fn provider, counts ->
        case upsert_provider!(provider, existing_by_key) do
          :created -> Map.update!(counts, :created, &(&1 + 1))
          :updated -> Map.update!(counts, :updated, &(&1 + 1))
        end
      end)

    stale = stale_providers(existing, providers)

    summary
    |> Map.merge(%{
      dry_run: false,
      total: length(providers),
      stale_disabled: reconcile_stale!(stale),
      stale_provider_keys: Enum.map(stale, & &1.stable_source_key),
      providers: Enum.map(providers, &serialize_provider/1)
    })
  end

  def json!(summary), do: Jason.encode!(summary, pretty: true)

  defp upsert_provider!(provider, existing_by_key) do
    attrs = persist_attrs(provider)

    case Map.get(existing_by_key, provider.stable_source_key) do
      nil ->
        ProviderSource
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create!(actor: @catalog_writer)

        :created

      existing ->
        existing
        |> Ash.Changeset.for_update(:update, Map.delete(attrs, :stable_source_key))
        |> Ash.update!(actor: @catalog_writer)

        :updated
    end
  end

  defp stale_providers(existing, providers) do
    provider_keys = providers |> Enum.map(& &1.stable_source_key) |> MapSet.new()

    Enum.reject(existing, &MapSet.member?(provider_keys, &1.stable_source_key))
  end

  defp reconcile_stale!(stale) do
    Enum.each(stale, fn provider ->
      provider
      |> Ash.Changeset.for_update(:update, %{
        source_kind: "manual",
        ingestion_mode: "manual",
        enabled?: false
      })
      |> Ash.update!(actor: @catalog_writer)
    end)

    length(stale)
  end

  defp persist_attrs(provider) do
    Map.take(provider, [
      :stable_source_key,
      :provider_name,
      :source_kind,
      :ingestion_mode,
      :base_uri,
      :manifest_uri,
      :allowed_hosts,
      :rate_limit_per_minute,
      :max_bytes,
      :checksum_algorithm,
      :required_checksum,
      :license_note,
      :enabled?
    ])
  end

  defp serialize_provider(provider) do
    provider
    |> Map.take([
      :stable_source_key,
      :provider_name,
      :source_kind,
      :ingestion_mode,
      :base_uri,
      :manifest_uri,
      :allowed_hosts,
      :rate_limit_per_minute,
      :max_bytes,
      :checksum_algorithm,
      :required_checksum,
      :license_note,
      :enabled?,
      :posture,
      :sources,
      :script_builder
    ])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end
end
