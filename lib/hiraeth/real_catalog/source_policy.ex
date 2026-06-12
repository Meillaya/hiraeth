defmodule Hiraeth.RealCatalog.SourcePolicy do
  @moduledoc """
  Provider-specific rules for approved real-publisher dataset records.
  """

  @allowed_formats MapSet.new(~w(paperback hardcover ebook audiobook))

  @cover_hosts %{
    "deep_vellum_official_store" => MapSet.new(["cdn.shopify.com"]),
    "dalkey_archive_official_store" => MapSet.new(["cdn.shopify.com"]),
    "archipelago_books_official_store" => MapSet.new(["archipelagobooks.org"]),
    "fixture-covers" => MapSet.new(["covers.example.test"])
  }

  @source_hosts %{
    "deep_vellum_official_store" => MapSet.new(["store.deepvellum.org"]),
    "dalkey_archive_official_store" => MapSet.new(["dalkeyarchive.store"]),
    "archipelago_books_official_store" => MapSet.new(["archipelagobooks.org"])
  }

  def allowed_format?(format), do: MapSet.member?(@allowed_formats, to_string(format))

  def cover_host_allowed?(provider, host) do
    provider
    |> cover_hosts()
    |> MapSet.member?(host)
  end

  def cover_hosts(provider), do: Map.get(@cover_hosts, provider, MapSet.new())

  def source_host_allowed?(provider, host) do
    provider
    |> source_hosts()
    |> MapSet.member?(host)
  end

  def source_hosts(provider), do: Map.get(@source_hosts, provider, MapSet.new())
end
