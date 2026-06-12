defmodule Hiraeth.RealCatalog.Validator do
  @moduledoc """
  Validates curated real-publisher dataset files before they are allowed to seed Hiraeth.
  """

  alias Hiraeth.RealCatalog.{Dataset, ISBN, SourcePolicy}

  defmodule Finding do
    @moduledoc false
    defstruct [:provider, :file, :source_uri, :isbn_13, :reason]
  end

  @allowed_displayed_fields ~w(title subtitle contributors publisher imprint format published_on isbn_13 cover source_url description synopsis editorial_praise storefront_url)
  @canonical_prose_fields ~w(description synopsis editorial_praise storefront_url)
  @commerce_state_keys ~w(price inventory availability cart checkout account)
  @raw_content_keys ~w(body_html content excerpt html rendered_html)
  @disallowed_prose_keys ~w(blurb bio author_bio review reviews user_review user_reviews jacket_copy)
  @disallowed_formats ~w(bundle subscription gift_card merch shirt supporter_only)

  def validate_dir(dir) do
    case Dataset.load_dir(dir) do
      {:ok, datasets} -> validate_datasets(datasets)
      {:error, reason} -> {:error, [%Finding{reason: inspect(reason)}]}
    end
  end

  def validate_datasets(datasets) do
    findings =
      datasets
      |> Enum.flat_map(&dataset_findings/1)
      |> Kernel.++(duplicate_findings(datasets))

    if findings == [] do
      {:ok, summary(datasets)}
    else
      {:error, findings}
    end
  end

  defp dataset_findings(dataset) do
    records = Map.get(dataset, :records, []) || []

    []
    |> add_blank(dataset, nil, dataset[:provider], "provider is required")
    |> add_if(records == [], dataset, nil, "dataset has no records")
    |> add_if(
      length(records) != 50,
      dataset,
      nil,
      "dataset must contain exactly 50 approved records"
    )
    |> Kernel.++(Enum.flat_map(records, &record_findings(dataset, &1)))
  end

  defp record_findings(dataset, record) do
    provider = dataset.provider

    []
    |> add_blank(dataset, record, record[:source_uri], "source_uri is required")
    |> add_source_uri_finding(dataset, record)
    |> add_blank(dataset, record, record[:publisher], "publisher is required")
    |> add_blank(dataset, record, get_in(record, [:work, :title]), "work title is required")
    |> add_blank(dataset, record, get_in(record, [:edition, :title]), "edition title is required")
    |> add_if(
      record[:contributors] in [nil, []],
      dataset,
      record,
      "at least one contributor is required"
    )
    |> add_isbn_finding(dataset, record)
    |> add_format_finding(dataset, record)
    |> add_supporter_sku_finding(dataset, record)
    |> add_curation_finding(dataset, record)
    |> Kernel.++(cover_findings(dataset, record))
    |> Kernel.++(displayed_field_findings(dataset, record))
    |> Kernel.++(prose_provenance_findings(dataset, record))
    |> Kernel.++(copy_risk_findings(dataset, record))
    |> Kernel.++(provider_mismatch_findings(provider, dataset, record))
  end

  defp add_blank(findings, dataset, record, value, reason) do
    add_if(findings, blank?(value), dataset, record, reason)
  end

  defp add_if(findings, true, dataset, record, reason),
    do: [finding(dataset, record, reason) | findings]

  defp add_if(findings, false, _dataset, _record, _reason), do: findings

  defp add_isbn_finding(findings, dataset, record) do
    isbn = get_in(record, [:edition, :isbn_13])

    case ISBN.normalize(isbn) do
      {:ok, _isbn} -> findings
      {:error, _reason} -> [finding(dataset, record, "invalid isbn_13 check digit") | findings]
    end
  end

  defp add_source_uri_finding(findings, dataset, record) do
    source_uri = Map.get(record, :source_uri)
    uri = parse_uri(source_uri)

    findings
    |> add_if(
      present?(source_uri) and uri.scheme != "https",
      dataset,
      record,
      "source_uri must be HTTPS"
    )
    |> add_if(
      present?(source_uri) and uri.scheme == "https" and
        not SourcePolicy.source_host_allowed?(dataset.provider, uri.host),
      dataset,
      record,
      "source_uri host is not allowlisted for provider"
    )
  end

  defp add_format_finding(findings, dataset, record) do
    format = get_in(record, [:edition, :format]) |> to_string()

    findings
    |> add_if(format in @disallowed_formats, dataset, record, "non-book format is not allowed")
    |> add_if(
      format not in @disallowed_formats and not SourcePolicy.allowed_format?(format),
      dataset,
      record,
      "edition format is not valid"
    )
  end

  defp add_supporter_sku_finding(findings, dataset, record) do
    sku = record |> Map.get(:source_sku, "") |> to_string() |> String.downcase()

    add_if(
      findings,
      String.contains?(sku, "supporter"),
      dataset,
      record,
      "supporter-only SKU is not allowed"
    )
  end

  defp add_curation_finding(findings, dataset, record) do
    add_if(
      findings,
      get_in(record, [:curation, :status]) != "approved",
      dataset,
      record,
      "curation status must be approved"
    )
  end

  defp cover_findings(dataset, record) do
    cover = Map.get(record, :cover, %{}) || %{}
    no_cover_reason = Map.get(record, :no_cover_reason) || Map.get(record, :cover_fallback_reason)
    source_url = Map.get(cover, :source_url)
    uri = parse_uri(source_url)

    if blank?(source_url) do
      add_blank(
        [],
        dataset,
        record,
        no_cover_reason,
        "cover source_url or no_cover_reason is required"
      )
    else
      []
      |> add_blank(dataset, record, Map.get(cover, :provider), "cover provider is required")
      |> add_blank(
        dataset,
        record,
        Map.get(cover, :rights_basis),
        "cover rights_basis is required"
      )
      |> add_if(uri.scheme != "https", dataset, record, "cover source_url must be HTTPS")
      |> add_if(
        uri.scheme == "https" and
          not SourcePolicy.cover_host_allowed?(dataset.provider, uri.host),
        dataset,
        record,
        "cover source_url host is not allowlisted for provider"
      )
      |> add_if(
        Map.get(cover, :cache_policy) != "link_only",
        dataset,
        record,
        "cover cache_policy must be link_only"
      )
    end
  end

  defp displayed_field_findings(dataset, record) do
    record
    |> Map.get(:displayed_fields, [])
    |> Enum.flat_map(fn field ->
      cond do
        field not in @allowed_displayed_fields ->
          [finding(dataset, record, "displayed field is not factual metadata")]

        blank?(displayed_field_value(record, field)) ->
          [finding(dataset, record, "displayed field value is missing")]

        true ->
          []
      end
    end)
  end

  defp displayed_field_value(record, field)
       when field in ["title", "subtitle", "format", "published_on", "isbn_13"] do
    get_in(record, [:edition, String.to_existing_atom(field)]) ||
      get_in(record, [:work, String.to_existing_atom(field)])
  end

  defp displayed_field_value(record, "source_url"), do: get_in(record, [:cover, :source_url])

  defp displayed_field_value(record, "description"),
    do: Map.get(record, :description) || get_in(record, [:work, :description])

  defp displayed_field_value(record, "synopsis"),
    do: Map.get(record, :synopsis) || get_in(record, [:work, :synopsis])

  defp displayed_field_value(record, "storefront_url"),
    do: Map.get(record, :storefront_url) || Map.get(record, :source_uri)

  defp displayed_field_value(record, "editorial_praise"), do: Map.get(record, :editorial_praise)
  defp displayed_field_value(record, "contributors"), do: Map.get(record, :contributors)
  defp displayed_field_value(record, "publisher"), do: Map.get(record, :publisher)
  defp displayed_field_value(record, "imprint"), do: Map.get(record, :imprint)
  defp displayed_field_value(record, "cover"), do: Map.get(record, :cover)
  defp displayed_field_value(_record, _field), do: nil

  defp prose_provenance_findings(dataset, record) do
    if public_prose_present?(record) do
      findings =
        []
        |> add_blank(
          dataset,
          record,
          record[:source_uri],
          "public prose requires source provenance"
        )
        |> add_blank(
          dataset,
          record,
          dataset[:license_note],
          "public prose requires source provenance"
        )
        |> add_storefront_url_finding(dataset, record)

      praise_provenance_findings(findings, dataset, record)
    else
      []
    end
  end

  defp add_storefront_url_finding(findings, dataset, record) do
    storefront_url = Map.get(record, :storefront_url)
    uri = parse_uri(storefront_url)

    findings
    |> add_if(
      present?(storefront_url) and uri.scheme != "https",
      dataset,
      record,
      "public prose requires source provenance"
    )
    |> add_if(
      present?(storefront_url) and uri.scheme == "https" and
        not SourcePolicy.source_host_allowed?(dataset.provider, uri.host),
      dataset,
      record,
      "public prose requires source provenance"
    )
  end

  defp praise_provenance_findings(findings, dataset, record) do
    record
    |> Map.get(:editorial_praise, [])
    |> List.wrap()
    |> Enum.reduce(findings, fn praise, acc ->
      source_uri = map_value(praise, :source_uri)
      uri = parse_uri(source_uri)

      acc
      |> add_blank(
        dataset,
        record,
        map_value(praise, :quote),
        "public prose requires source provenance"
      )
      |> add_blank(
        dataset,
        record,
        map_value(praise, :source),
        "public prose requires source provenance"
      )
      |> add_blank(dataset, record, source_uri, "public prose requires source provenance")
      |> add_if(
        present?(source_uri) and uri.scheme != "https",
        dataset,
        record,
        "public prose requires source provenance"
      )
      |> add_if(
        present?(source_uri) and uri.scheme == "https" and
          not SourcePolicy.source_host_allowed?(dataset.provider, uri.host),
        dataset,
        record,
        "public prose requires source provenance"
      )
    end)
    |> Enum.uniq_by(&{&1.source_uri, &1.reason})
  end

  defp public_prose_present?(record) do
    canonical_values_present? =
      not blank?(Map.get(record, :description)) or not blank?(Map.get(record, :synopsis)) or
        not blank?(Map.get(record, :storefront_url)) or
        not blank?(Map.get(record, :editorial_praise)) or
        not blank?(get_in(record, [:work, :description])) or
        not blank?(get_in(record, [:work, :synopsis]))

    displayed_prose? =
      record
      |> Map.get(:displayed_fields, [])
      |> Enum.any?(&(&1 in @canonical_prose_fields))

    canonical_values_present? or displayed_prose?
  end

  defp copy_risk_findings(dataset, record) do
    record
    |> flatten_values()
    |> Enum.flat_map(fn {key, value} ->
      key = String.downcase(to_string(key))

      cond do
        key in @commerce_state_keys ->
          [finding(dataset, record, "commerce state is not public catalog metadata")]

        key in @raw_content_keys or executable_html?(value) ->
          [
            finding(
              dataset,
              record,
              "raw HTML or executable content is not allowed in public prose"
            )
          ]

        key in @disallowed_prose_keys ->
          [finding(dataset, record, "long copied text or disallowed prose field is present")]

        is_binary(value) and String.length(value) > 280 and not safe_long_value_key?(key) ->
          [finding(dataset, record, "long copied text or disallowed prose field is present")]

        true ->
          []
      end
    end)
    |> Enum.uniq_by(&{&1.source_uri, &1.reason})
  end

  defp provider_mismatch_findings(provider, dataset, record) do
    cover_provider = get_in(record, [:cover, :provider])

    if cover_provider in [nil, provider],
      do: [],
      else: [finding(dataset, record, "cover provider must match dataset provider")]
  end

  defp duplicate_findings(datasets) do
    datasets
    |> Enum.flat_map(fn dataset ->
      Enum.map(dataset.records || [], fn record ->
        isbn =
          case ISBN.normalize(get_in(record, [:edition, :isbn_13])) do
            {:ok, normalized} -> normalized
            {:error, _reason} -> nil
          end

        {isbn, dataset, record}
      end)
    end)
    |> Enum.reject(fn {isbn, _dataset, _record} -> blank?(isbn) end)
    |> Enum.group_by(fn {isbn, _dataset, _record} -> isbn end)
    |> Enum.flat_map(fn {_isbn, rows} ->
      if length(rows) > 1 do
        Enum.map(rows, fn {_isbn, dataset, record} ->
          finding(dataset, record, "duplicate isbn_13")
        end)
      else
        []
      end
    end)
  end

  defp summary(datasets) do
    providers =
      Map.new(datasets, fn dataset ->
        records = dataset.records || []

        {dataset.provider,
         %{
           file: dataset.file,
           record_count: length(records),
           approved_count: Enum.count(records, &(get_in(&1, [:curation, :status]) == "approved"))
         }}
      end)

    %{
      providers: providers,
      total_records: datasets |> Enum.map(&length(&1.records || [])) |> Enum.sum(),
      duplicate_isbns: [],
      copy_risk_findings: [],
      cover_findings: []
    }
  end

  defp finding(dataset, record, reason) do
    %Finding{
      provider: Map.get(dataset, :provider),
      file: Map.get(dataset, :file),
      source_uri: Map.get(record || %{}, :source_uri),
      isbn_13: get_in(record || %{}, [:edition, :isbn_13]),
      reason: reason
    }
  end

  defp parse_uri(value) when is_binary(value), do: URI.parse(value)
  defp parse_uri(_value), do: %URI{}

  defp flatten_values(term), do: flatten_values(term, [])

  defp flatten_values(%_struct{} = struct, acc),
    do: struct |> Map.from_struct() |> flatten_values(acc)

  defp flatten_values(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, values ->
      flatten_values(value, [{key, value} | values])
    end)
  end

  defp flatten_values(list, acc) when is_list(list), do: Enum.reduce(list, acc, &flatten_values/2)
  defp flatten_values(_value, acc), do: acc

  defp safe_long_value_key?(key),
    do:
      String.ends_with?(key, "url") or
        key in ~w(source_uri source_url attribution_url storefront_url license_note description synopsis quote)

  defp executable_html?(value) when is_binary(value),
    do:
      value
      |> String.downcase()
      |> String.contains?([
        "<p",
        "<br",
        "<div",
        "<span",
        "<section",
        "<article",
        "<script",
        "javascript:",
        "<iframe"
      ])

  defp executable_html?(_value), do: false

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_value, _key), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp blank?(value), do: value in [nil, []] or (is_binary(value) and String.trim(value) == "")
end
