defmodule Hiraeth.RealCatalog.SourcePolicy do
  @moduledoc """
  Provider-specific rules for approved real-publisher dataset records.
  """

  @allowed_formats MapSet.new(~w(paperback hardcover ebook audiobook))
  @expansion_provider_slugs ["new_directions_official_site", "transit_books_official_site"]

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
    "new_directions_official_site" => MapSet.new(["www.ndbooks.com"]),
    "transit_books_official_site" => MapSet.new(["www.transitbooks.org"])
  }

  @source_path_prefixes %{
    "transit_books_official_site" => ~w(/books /catalogs /rights /about)
  }

  @source_pdf_path_prefixes %{
    "transit_books_official_site" => ["/s/"]
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
    },
    "transit_books_official_site" => %{
      provider: "transit_books_official_site",
      name: "Transit Books",
      source_urls: [
        "https://www.transitbooks.org/books",
        "https://www.transitbooks.org/catalogs"
      ],
      permission_urls: ["https://www.transitbooks.org/rights"],
      contact_urls: ["https://www.transitbooks.org/about"],
      source_hosts: MapSet.new(["www.transitbooks.org"]),
      cover_hosts: MapSet.new([]),
      permission_basis:
        "Official Transit Books pages expose public catalog facts and rights/contact surfaces for permission review; this gate records no covers and disallows local cover caching until explicit cache permission is documented.",
      provenance_notes:
        "Use only source-backed factual bibliographic metadata from official transitbooks.org catalog pages or a checked-in deterministic fixture derived from an approved source. Preserve provider, source URL, field provenance, and import-run evidence for every imported value. Do not import, link, or cache Transit cover images without a later explicit cover policy update.",
      cover_cache_policy: "no_covers_until_explicit_permission",
      excluded_content: [
        "raw_html",
        "jacket_copy_dumps",
        "author_bios",
        "reviews",
        "user_reviews",
        "prices",
        "inventory",
        "cart_checkout_account",
        "cover_images"
      ],
      takedown_contact:
        "Use the Transit Books rights/about paths for permission, correction, or takedown requests: https://www.transitbooks.org/rights and https://www.transitbooks.org/about.",
      not_legal_advice?: true
    }
  }

  def allowed_format?(format), do: MapSet.member?(@allowed_formats, to_string(format))

  def expansion_provider_slugs, do: @expansion_provider_slugs

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

  def source_uri_allowed?(provider, uri_string) do
    uri_allowed?(provider, uri_string, &source_host_allowed?/2, &source_path_allowed?/2)
  end

  def cover_uri_allowed?(provider, uri_string) do
    uri_allowed?(provider, uri_string, &cover_host_allowed?/2, fn _provider, _path -> true end)
  end

  def cover_cache_allowed?(provider) do
    provider_permission_metadata!(provider).cover_cache_policy == "cache_allowed"
  rescue
    ArgumentError -> false
  end

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

  def provider_policy_ready?(provider) do
    provider in @expansion_provider_slugs and provider_gate_ready?(provider) and
      provider_permission_metadata_ready?(provider)
  rescue
    ArgumentError -> false
  end

  def provider_permission_metadata!(provider) do
    gate = provider_gate!(provider)

    %{
      provider: gate.provider,
      source_urls: gate.source_urls,
      source_hosts: sorted_set(gate.source_hosts),
      cover_hosts: sorted_set(gate.cover_hosts),
      permission_basis: gate.permission_basis,
      cover_cache_policy: gate.cover_cache_policy,
      excluded_content: gate.excluded_content,
      takedown_contact: gate.takedown_contact,
      not_legal_advice:
        "This provider source policy is an engineering provenance control and is not legal advice."
    }
  end

  defp provider_permission_metadata_ready?(provider) do
    metadata = provider_permission_metadata!(provider)

    Enum.all?(
      ~w(provider source_urls source_hosts permission_basis cover_cache_policy excluded_content takedown_contact not_legal_advice)a,
      &(metadata |> Map.get(&1) |> gate_field_present_value?())
    ) and cover_hosts_metadata_ready?(metadata) and
      metadata.source_hosts == sorted_set(source_hosts(provider)) and
      metadata.cover_hosts == sorted_set(cover_hosts(provider))
  end

  defp cover_hosts_metadata_ready?(
         %{cover_cache_policy: "no_covers_until_explicit_permission"} = metadata
       ),
       do: metadata.cover_hosts == []

  defp cover_hosts_metadata_ready?(metadata), do: gate_field_present_value?(metadata.cover_hosts)

  defp uri_allowed?(provider, uri_string, host_allowed?, path_allowed?) do
    case URI.parse(to_string(uri_string)) do
      %URI{scheme: "https", host: host, path: path} when is_binary(host) ->
        host_allowed?.(provider, host) and path_allowed?.(provider, path)

      _invalid ->
        false
    end
  end

  defp source_path_allowed?(provider, path) do
    path = path || "/"

    case Map.fetch(@source_path_prefixes, provider) do
      {:ok, prefixes} ->
        safe_path_for_prefix_match?(path) and
          (Enum.any?(prefixes, &path_matches_prefix?(path, &1)) or
             source_pdf_path_allowed?(provider, path))

      :error ->
        true
    end
  end

  defp source_pdf_path_allowed?(provider, path) do
    @source_pdf_path_prefixes
    |> Map.get(provider, [])
    |> Enum.any?(fn prefix ->
      String.starts_with?(path, prefix) and String.ends_with?(String.downcase(path), ".pdf")
    end)
  end

  defp path_matches_prefix?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp safe_path_for_prefix_match?(path) do
    not String.contains?(path, "%") and
      not String.contains?(path, "\\") and
      not dot_segment_path?(path)
  end

  defp dot_segment_path?(path) do
    path
    |> String.split(~r{[/\\]})
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp sorted_set(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()

  defp gate_field_present?(gate, :cover_hosts) do
    case Map.get(gate, :cover_cache_policy) do
      "no_covers_until_explicit_permission" -> Map.get(gate, :cover_hosts) == MapSet.new([])
      _policy -> gate |> Map.get(:cover_hosts) |> gate_field_present_value?()
    end
  end

  defp gate_field_present?(gate, field) do
    value = Map.get(gate, field)

    gate_field_present_value?(value)
  end

  defp gate_field_present_value?(value) do
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
