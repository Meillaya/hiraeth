defmodule Hiraeth.RealCatalog.SourcePolicy do
  @moduledoc """
  Provider-specific rules for approved real-publisher dataset records.
  """

  @allowed_formats MapSet.new(~w(paperback hardcover ebook audiobook))
  @expansion_provider_slugs [
    "new_directions_official_site",
    "transit_books_official_site"
  ]

  @cover_hosts %{
    "deep_vellum_official_store" => MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "dalkey_archive_official_store" => MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "archipelago_books_official_store" =>
      MapSet.new(["archipelagobooks.org", "covers.openlibrary.org"]),
    "new_directions_official_site" => MapSet.new(["cdn.sanity.io", "covers.openlibrary.org"]),
    "transit_books_official_site" =>
      MapSet.new([
        "images.squarespace-cdn.com",
        "static1.squarespace.com",
        "covers.openlibrary.org"
      ]),
    "historical_materialism_official_site" =>
      MapSet.new(["www.historicalmaterialism.org", "covers.openlibrary.org"]),
    "semiotexte_official_site" =>
      MapSet.new([
        "images.squarespace-cdn.com",
        "static1.squarespace.com",
        "covers.openlibrary.org"
      ]),
    "phoneme_media_official_store" => MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "a_strange_object_official_store" =>
      MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "la_reunion_official_store" => MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "fum_destampa_official_store" => MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "nyrb_official_store" => MapSet.new(["cdn.shopify.com", "covers.openlibrary.org"]),
    "tilted_axis_press_official_site" =>
      MapSet.new([
        "images.squarespace-cdn.com",
        "static1.squarespace.com",
        "covers.openlibrary.org"
      ]),
    "mcnally_editions_official_site" =>
      MapSet.new([
        "images.squarespace-cdn.com",
        "static1.squarespace.com",
        "covers.openlibrary.org"
      ]),
    "seven_stories_press_official_site" =>
      MapSet.new(["sevenstories-prod.s3.amazonaws.com", "covers.openlibrary.org"]),
    "unnamed_press_official_site" =>
      MapSet.new([
        "images.squarespace-cdn.com",
        "static1.squarespace.com",
        "covers.openlibrary.org"
      ]),
    "pushkin_press_official_site" =>
      MapSet.new([
        "us.pushkinpress.com",
        "i0.wp.com",
        "i1.wp.com",
        "i2.wp.com",
        "covers.openlibrary.org"
      ]),
    "fitzcarraldo_editions_official_site" =>
      MapSet.new(["fitzcarraldoeditions.com", "covers.openlibrary.org"]),
    "fixture-covers" => MapSet.new(["covers.example.test"])
  }

  @source_hosts %{
    "deep_vellum_official_store" => MapSet.new(["store.deepvellum.org"]),
    "dalkey_archive_official_store" => MapSet.new(["dalkeyarchive.store"]),
    "archipelago_books_official_store" => MapSet.new(["archipelagobooks.org"]),
    "new_directions_official_site" => MapSet.new(["www.ndbooks.com"]),
    "transit_books_official_site" => MapSet.new(["www.transitbooks.org"]),
    "historical_materialism_official_site" => MapSet.new(["www.historicalmaterialism.org"]),
    "semiotexte_official_site" => MapSet.new(["www.semiotexte.com"]),
    "phoneme_media_official_store" => MapSet.new(["store.deepvellum.org"]),
    "a_strange_object_official_store" => MapSet.new(["store.deepvellum.org"]),
    "la_reunion_official_store" => MapSet.new(["store.deepvellum.org"]),
    "fum_destampa_official_store" => MapSet.new(["store.deepvellum.org"]),
    "nyrb_official_store" => MapSet.new(["www.nyrb.com"]),
    "tilted_axis_press_official_site" => MapSet.new(["www.tiltedaxispress.com"]),
    "mcnally_editions_official_site" => MapSet.new(["www.mcnallyeditions.com"]),
    "seven_stories_press_official_site" => MapSet.new(["www.sevenstories.com"]),
    "unnamed_press_official_site" => MapSet.new(["www.unnamedpress.com"]),
    "pushkin_press_official_site" => MapSet.new(["us.pushkinpress.com"]),
    "fitzcarraldo_editions_official_site" => MapSet.new(["fitzcarraldoeditions.com"])
  }

  @source_path_prefixes %{
    "new_directions_official_site" => ~w(/book /books /sitemap-index.xml /sitemap-0.xml),
    "transit_books_official_site" => ~w(/books /catalogs /rights /about),
    "historical_materialism_official_site" => ~w(/book-series /contact),
    "phoneme_media_official_store" => ~w(/products /pages/contact-us),
    "a_strange_object_official_store" => ~w(/products /pages/contact-us),
    "la_reunion_official_store" => ~w(/products /pages/contact-us),
    "fum_destampa_official_store" => ~w(/products /pages/contact-us),
    "nyrb_official_store" => ~w(/collections /products /pages /policies),
    "tilted_axis_press_official_site" => ~w(/books /shop /contact),
    "mcnally_editions_official_site" => ~w(/books /catalog /about),
    "seven_stories_press_official_site" => ~w(/imprints/seven-stories-press /books /pg),
    "unnamed_press_official_site" => ~w(/all-books /about /contact),
    "pushkin_press_official_site" => ~w(/imprint/pushkin-press-classics /book /wp-json),
    "fitzcarraldo_editions_official_site" => ~w(/shop /books /contact)
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

  @manifest_providers %{}
  @default_provider_manifest_files %{
    "deep_vellum_official_store" =>
      Path.join([
        "catalog_sources",
        "provider_manifests",
        "deep_vellum_official_store.json"
      ])
  }

  @provider_gates %{
    "new_directions_official_site" => %{
      provider: "new_directions_official_site",
      name: "New Directions",
      source_urls: ["https://www.ndbooks.com/books/"],
      permission_urls: ["https://www.ndbooks.com/permissions/"],
      contact_urls: ["https://www.ndbooks.com/about/contact/"],
      source_hosts: MapSet.new(["www.ndbooks.com"]),
      cover_hosts: MapSet.new(["cdn.sanity.io", "covers.openlibrary.org"]),
      permission_basis:
        "Official New Directions pages expose public catalog facts and cover assets from an allowlisted image host; public display depends on provenance, HTTPS host allowlists, local cache validation, attribution, and takedown state rather than permission-request state.",
      provenance_notes:
        "Use only source-backed factual bibliographic metadata from official ndbooks.com pages or a checked-in deterministic fixture derived from an approved source. Preserve provider, source URL, field provenance, and import-run evidence for every imported value.",
      cover_cache_policy: "cache_allowed",
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
      cover_hosts:
        MapSet.new([
          "images.squarespace-cdn.com",
          "static1.squarespace.com",
          "covers.openlibrary.org"
        ]),
      permission_basis:
        "Official Transit Books pages expose public catalog facts and cover assets from allowlisted Squarespace image hosts; public display depends on provenance, HTTPS host allowlists, local cache validation, attribution, and takedown state.",
      provenance_notes:
        "Use only source-backed factual bibliographic metadata and cover URLs from official transitbooks.org catalog pages or a checked-in deterministic fixture derived from an approved source. Preserve provider, source URL, field provenance, and import-run evidence for every imported value.",
      cover_cache_policy: "cache_allowed",
      excluded_content: [
        "raw_html",
        "jacket_copy_dumps",
        "author_bios",
        "reviews",
        "user_reviews",
        "prices",
        "inventory",
        "cart_checkout_account",
        "unattributed_cover_images"
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
    |> MapSet.member?(host) or
      manifest_cover_host_allowed?(provider, host)
  end

  def cover_hosts(provider) do
    @cover_hosts
    |> Map.get(provider, MapSet.new())
    |> MapSet.union(manifest_cover_hosts(provider))
  end

  def source_host_allowed?(provider, host) do
    provider
    |> source_hosts()
    |> MapSet.member?(host) or
      manifest_source_host_allowed?(provider, host)
  end

  def source_hosts(provider) do
    @source_hosts
    |> Map.get(provider, MapSet.new())
    |> MapSet.union(manifest_source_hosts(provider))
  end

  def source_path_prefixes(provider), do: Map.get(@source_path_prefixes, provider, [])

  def source_pdf_path_prefixes(provider), do: Map.get(@source_pdf_path_prefixes, provider, [])

  def source_uri_allowed?(provider, uri_string, context \\ nil) do
    cond do
      manifest_source_handle_candidate?(provider, uri_string) ->
        manifest_source_handle_allowed?(provider, uri_string, context)

      uri_allowed?(provider, uri_string, &source_host_allowed?/2, &source_path_allowed?/2) ->
        true

      true ->
        manifest_source_handle_allowed?(provider, uri_string, context)
    end
  end

  def load_provider_manifest(file_path) do
    manifest = Hiraeth.Ingestion.ProviderManifest.load!(file_path)

    cover_hosts = MapSet.new(manifest.cover_hosts || [])
    source_hosts = MapSet.new(manifest.source_hosts || [])

    source_path_prefixes = manifest_source_path_prefixes_from_urls(manifest.source_urls || [])

    provider_entry = %{
      cover_hosts: cover_hosts,
      source_hosts: source_hosts,
      source_path_prefixes: source_path_prefixes,
      source_handle_patterns: source_handle_patterns(manifest)
    }

    current = Process.get(:manifest_providers, %{})
    Process.put(:manifest_providers, Map.put(current, manifest.provider, provider_entry))

    {:ok, manifest.provider}
  end

  def cover_uri_allowed?(provider, uri_string) do
    uri_allowed?(provider, uri_string, &cover_host_allowed?/2, fn _provider, _path -> true end)
  end

  def purchase_uri_allowed?(provider, uri_string, context \\ nil),
    do: source_uri_allowed?(provider, uri_string, context)

  def review_link_allowed?(provider, review, context \\ nil)

  def review_link_allowed?(provider, review, context) when is_map(review) do
    source_uri = map_value(review, :source_uri)

    present?(map_value(review, :source)) and present?(source_uri) and
      review_uri_allowed?(provider, source_uri, context) and
      review_excerpt_allowed?(map_value(review, :excerpt), map_value(review, :rights_basis))
  end

  def review_link_allowed?(_provider, _review, _context), do: false

  def review_excerpt_allowed?(excerpt, rights_basis) when excerpt in [nil, ""],
    do: rights_basis == "link_only"

  def review_excerpt_allowed?(excerpt, rights_basis) do
    present?(excerpt) and String.length(to_string(excerpt)) <= 280 and
      rights_basis in ["publisher_supplied", "licensed_excerpt", "explicit_authorization"]
  end

  def review_uri_allowed?(provider, uri_string, context \\ nil),
    do: source_uri_allowed?(provider, uri_string, context)

  def cover_cache_allowed?(provider) do
    provider_permission_metadata!(provider).cover_hosts != []
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

  defp cover_hosts_metadata_ready?(%{cover_cache_policy: "no_covers_sourced"} = metadata),
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

    prefixes =
      case Map.fetch(@source_path_prefixes, provider) do
        {:ok, hardcoded} -> hardcoded
        :error -> []
      end ++ manifest_source_path_prefixes(provider)

    if prefixes == [] do
      true
    else
      safe_path_for_prefix_match?(path) and
        (Enum.any?(prefixes, &path_matches_prefix?(path, &1)) or
           source_pdf_path_allowed?(provider, path))
    end
  end

  defp source_pdf_path_allowed?(provider, path) do
    @source_pdf_path_prefixes
    |> Map.get(provider, [])
    |> Enum.any?(fn prefix ->
      String.starts_with?(path, prefix) and String.ends_with?(String.downcase(path), ".pdf")
    end)
  end

  defp manifest_source_handle_candidate?(provider, uri_string) do
    case URI.parse(to_string(uri_string)) do
      %URI{scheme: "https", host: host, path: path, query: nil} when is_binary(host) ->
        path = path || "/"

        source_host_allowed?(provider, host) and safe_path_for_prefix_match?(path) and
          Enum.any?(
            manifest_source_handle_patterns(provider),
            &source_handle_matches?(&1, host, path)
          )

      _invalid_or_query_uri ->
        false
    end
  end

  defp manifest_source_handle_allowed?(provider, uri_string, context) do
    case URI.parse(to_string(uri_string)) do
      %URI{scheme: "https", host: host, path: path, query: nil} when is_binary(host) ->
        path = path || "/"

        source_host_allowed?(provider, host) and
          safe_path_for_prefix_match?(path) and
          Enum.any?(manifest_source_handle_patterns(provider), fn pattern ->
            source_handle_matches?(pattern, host, path) and
              source_handle_vendor_allowed?(pattern, context)
          end)

      _invalid_or_query_uri ->
        false
    end
  end

  defp source_handle_matches?(
         %{host: host, path_prefix: prefix, handle_pattern: pattern},
         host,
         path
       ) do
    with true <- String.starts_with?(path, prefix),
         handle when handle != "" <-
           path |> String.replace_prefix(prefix, "") |> String.trim_trailing("/"),
         false <- String.contains?(handle, "/") do
      safe_source_handle?(handle, pattern)
    else
      _not_match -> false
    end
  end

  defp source_handle_matches?(_pattern, _host, _path), do: false

  defp source_handle_vendor_allowed?(%{allowed_vendors: allowed_vendors}, context)
       when is_list(allowed_vendors) and allowed_vendors != [] do
    context
    |> context_vendor()
    |> vendor_in_allowlist?(allowed_vendors)
  end

  defp source_handle_vendor_allowed?(_pattern_without_vendor_gate, _context), do: true

  defp context_vendor(context) when is_map(context) do
    map_value(context, :vendor) || map_value(context, :imprint) || map_value(context, :publisher) ||
      map_value(context, :provider)
  end

  defp context_vendor(_context), do: nil

  defp vendor_in_allowlist?(vendor, allowed_vendors) when is_binary(vendor) do
    normalized = String.downcase(String.trim(vendor))

    Enum.any?(allowed_vendors, fn allowed ->
      is_binary(allowed) and String.downcase(String.trim(allowed)) == normalized
    end)
  end

  defp vendor_in_allowlist?(_vendor, _allowed_vendors), do: false

  defp safe_source_handle?(handle, "[a-z0-9][a-z0-9-]*"),
    do: String.match?(handle, ~r/^[a-z0-9][a-z0-9-]*$/)

  defp safe_source_handle?(_handle, _unsafe_or_unknown_pattern), do: false

  defp source_handle_patterns(manifest) do
    api = map_value(manifest, :api) || %{}

    api
    |> map_value(:source_handle_patterns)
    |> normalize_source_handle_patterns()
  end

  defp normalize_source_handle_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.map(&normalize_source_handle_pattern/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_source_handle_patterns(_patterns), do: []

  defp normalize_source_handle_pattern(pattern) when is_map(pattern) do
    host = map_value(pattern, :host)
    path_prefix = map_value(pattern, :path_prefix)
    handle_pattern = map_value(pattern, :handle_pattern)

    if safe_source_handle_pattern?(host, path_prefix, handle_pattern) do
      %{
        host: host,
        path_prefix: path_prefix,
        handle_pattern: handle_pattern,
        allowed_vendors: normalize_allowed_vendors(map_value(pattern, :allowed_vendors))
      }
    end
  end

  defp normalize_source_handle_pattern(_pattern), do: nil

  defp normalize_allowed_vendors(vendors) when is_list(vendors) do
    vendors
    |> Enum.filter(&present?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_vendors(_vendors), do: []

  defp safe_source_handle_pattern?(host, path_prefix, handle_pattern) do
    present?(host) and host == String.downcase(host) and
      present?(path_prefix) and String.starts_with?(path_prefix, "/") and
      String.ends_with?(path_prefix, "/") and safe_path_for_prefix_match?(path_prefix) and
      handle_pattern == "[a-z0-9][a-z0-9-]*"
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

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_value, _key), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp gate_field_present?(gate, :cover_hosts) do
    case Map.get(gate, :cover_cache_policy) do
      "no_covers_sourced" -> Map.get(gate, :cover_hosts) == MapSet.new([])
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

  # --- Manifest provider runtime helpers ---

  defp manifest_cover_host_allowed?(provider, host) do
    provider
    |> manifest_cover_hosts()
    |> MapSet.member?(host)
  end

  defp manifest_source_host_allowed?(provider, host) do
    provider
    |> manifest_source_hosts()
    |> MapSet.member?(host)
  end

  defp manifest_cover_hosts(provider) do
    provider
    |> manifest_provider_entry()
    |> Map.get(:cover_hosts, MapSet.new())
  end

  defp manifest_source_hosts(provider) do
    provider
    |> manifest_provider_entry()
    |> Map.get(:source_hosts, MapSet.new())
  end

  defp manifest_source_path_prefixes(provider) do
    provider
    |> manifest_provider_entry()
    |> Map.get(:source_path_prefixes, [])
  end

  defp manifest_source_handle_patterns(provider) do
    provider
    |> manifest_provider_entry()
    |> Map.get(:source_handle_patterns, [])
  end

  defp manifest_provider_entry(provider) do
    process_manifests = Process.get(:manifest_providers, @manifest_providers)

    case Map.fetch(process_manifests, provider) do
      {:ok, entry} -> entry
      :error -> default_manifest_provider_entry(provider)
    end
  end

  defp default_manifest_provider_entry(provider) do
    case Map.get(@default_provider_manifest_files, provider) do
      nil ->
        provider
        |> provider_manifest_filename()
        |> default_provider_manifest_path()
        |> load_manifest_provider_entry()

      file ->
        file |> default_provider_manifest_path() |> load_manifest_provider_entry()
    end
  end

  defp provider_manifest_filename(provider),
    do: Path.join("catalog_sources/provider_manifests", "#{provider}.json")

  defp default_provider_manifest_path(file) do
    case :code.priv_dir(:hiraeth) do
      priv_dir when is_list(priv_dir) -> Path.join(to_string(priv_dir), file)
      {:error, _reason} -> Path.join("priv", file)
    end
  end

  defp load_manifest_provider_entry(file_path) do
    if File.exists?(file_path) do
      manifest = Hiraeth.Ingestion.ProviderManifest.load!(file_path)

      %{}
      |> Map.put(:cover_hosts, MapSet.new(manifest.cover_hosts || []))
      |> Map.put(:source_hosts, MapSet.new(manifest.source_hosts || []))
      |> Map.put(
        :source_path_prefixes,
        manifest_source_path_prefixes_from_urls(manifest.source_urls || [])
      )
      |> Map.put(:source_handle_patterns, source_handle_patterns(manifest))
    else
      %{}
    end
  end

  defp manifest_source_path_prefixes_from_urls(source_urls) do
    source_urls
    |> Enum.map(fn url ->
      case URI.parse(url) do
        %URI{path: path} when is_binary(path) -> path
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
