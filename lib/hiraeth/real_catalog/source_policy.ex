defmodule Hiraeth.RealCatalog.SourcePolicy do
  @moduledoc """
  Provider-specific rules for approved real-publisher dataset records.
  """

  @allowed_formats MapSet.new(~w(paperback hardcover ebook audiobook))

  @cover_hosts %{
    "deep_vellum_official_store" => MapSet.new(["cdn.shopify.com"]),
    "dalkey_archive_official_store" => MapSet.new(["cdn.shopify.com"]),
    "archipelago_books_official_store" => MapSet.new(["archipelagobooks.org"]),
    "new_directions_official_site" => MapSet.new(["cdn.sanity.io"]),
    "fixture-covers" => MapSet.new(["covers.example.test"])
  }

  @source_hosts %{
    "deep_vellum_official_store" => MapSet.new(["store.deepvellum.org"]),
    "dalkey_archive_official_store" => MapSet.new(["dalkeyarchive.store"]),
    "archipelago_books_official_store" => MapSet.new(["archipelagobooks.org"]),
    "new_directions_official_site" => MapSet.new(["www.ndbooks.com"])
  }

  @required_gate_fields ~w(
    provider
    name
    source_urls
    permission_urls
    contact_urls
    source_hosts
    cover_hosts
    permission_basis
    provenance_notes
    cover_cache_policy
    excluded_content
    takedown_contact
    not_legal_advice?
  )a

  @provider_gates %{
    "new_directions_official_site" => %{
      provider: "new_directions_official_site",
      name: "New Directions",
      source_urls: ["https://www.ndbooks.com/books/"],
      permission_urls: ["https://www.ndbooks.com/permissions/"],
      contact_urls: ["https://www.ndbooks.com/about/contact/"],
      source_hosts: MapSet.new(["www.ndbooks.com"]),
      cover_hosts: MapSet.new(["cdn.sanity.io"]),
      permission_basis:
        "Official New Directions pages expose public catalog facts; the permissions page states that New Directions books are protected under copyright law and directs reuse/license requests to permissions [at] ndbooks.com.",
      provenance_notes:
        "Use only source-backed factual bibliographic metadata from official ndbooks.com pages or a checked-in deterministic fixture derived from an approved source. Preserve provider, source URL, field provenance, and import-run evidence for every imported value.",
      cover_cache_policy: "link_only_until_explicit_cache_permission",
      excluded_content: [
        "raw_html",
        "jacket_copy_dumps",
        "author_bios",
        "reviews",
        "user_reviews",
        "prices",
        "inventory",
        "cart_checkout_account"
      ],
      takedown_contact:
        "Use the New Directions permissions/contact path: permissions [at] ndbooks.com, or the contact page at https://www.ndbooks.com/about/contact/.",
      not_legal_advice?: true
    }
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

  def provider_gate!(provider) do
    case Map.fetch(@provider_gates, provider) do
      {:ok, gate} -> gate
      :error -> raise ArgumentError, "unknown provider gate: #{provider}"
    end
  end

  def provider_gate_ready?(provider) do
    with {:ok, gate} <- Map.fetch(@provider_gates, provider) do
      Enum.all?(@required_gate_fields, &gate_field_present?(gate, &1)) and
        Map.get(gate, :source_hosts) == source_hosts(provider) and
        Map.get(gate, :cover_hosts) == cover_hosts(provider)
    else
      :error -> false
    end
  end

  defp gate_field_present?(gate, field) do
    value = Map.get(gate, field)

    case value do
      nil -> false
      false -> false
      "" -> false
      [] -> false
      %MapSet{} = set -> MapSet.size(set) > 0
      _present -> true
    end
  end
end
