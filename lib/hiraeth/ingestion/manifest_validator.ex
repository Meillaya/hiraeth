defmodule Hiraeth.Ingestion.ManifestValidator do
  @moduledoc """
  Validates provider config manifests before they are accepted into the ingestion orchestration system.
  """

  import Bitwise, only: [band: 2, bor: 2, bsl: 2, bsr: 2]

  defmodule Finding do
    @moduledoc false
    defstruct [:provider, :field, :reason]
  end

  @required_fields ~w(
    provider
    name
    source_urls
    source_hosts
    cover_hosts
    permission_basis
    takedown_contact
    excluded_content
    cover_cache_policy
    not_legal_advice
  )a

  @allowed_source_modes MapSet.new(["api", "scrape"])
  @allowed_api_types MapSet.new(["shopify", "woocommerce", "squarespace", "wordpress"])

  @doc """
  Validates an atomized manifest map and returns `{:ok, manifest}` or `{:error, findings}`.
  """
  def validate(manifest) when is_map(manifest) do
    findings =
      []
      |> add_required_field_findings(manifest)
      |> add_source_mode_presence_finding(manifest)
      |> add_source_mode_finding(manifest)
      |> add_source_urls_finding(manifest)
      |> add_api_type_finding(manifest)
      |> add_api_endpoint_finding(manifest)
      |> add_spider_module_finding(manifest)
      |> add_spider_start_urls_finding(manifest)
      |> add_expected_record_count_finding(manifest)

    if findings == [] do
      {:ok, manifest}
    else
      {:error, findings}
    end
  end

  # --- Required fields ---

  defp add_required_field_findings(findings, manifest) do
    Enum.reduce(@required_fields, findings, fn field, acc ->
      value = Map.get(manifest, field) || Map.get(manifest, to_string(field))
      add_blank(acc, manifest, field, value, "#{field} is required")
    end)
  end

  # --- source_mode ---

  defp add_source_mode_presence_finding(findings, manifest) do
    mode = get_field(manifest, :source_mode)

    add_if(
      findings,
      blank?(mode) and not config_present?(manifest, :spider) and
        not config_present?(manifest, :api),
      manifest,
      :source_mode,
      "source_mode is required"
    )
  end

  defp add_source_mode_finding(findings, manifest) do
    mode = get_field(manifest, :source_mode)

    add_if(
      findings,
      present?(mode) and mode not in @allowed_source_modes,
      manifest,
      :source_mode,
      "source_mode must be \"api\" or \"scrape\""
    )
  end

  # --- source_urls must be HTTPS ---

  defp add_source_urls_finding(findings, manifest) do
    urls = Map.get(manifest, :source_urls) || Map.get(manifest, "source_urls") || []

    Enum.reduce(urls, findings, fn url, acc ->
      add_url_policy_findings(
        acc,
        manifest,
        :source_urls,
        "source_url",
        url,
        source_hosts(manifest)
      )
    end)
  end

  # --- api.type when effective source_mode is "api" ---

  defp add_api_type_finding(findings, manifest) do
    mode = effective_source_mode_for_validation(manifest)
    api = get_field(manifest, :api) || %{}
    api_type = Map.get(api, :type) || Map.get(api, "type")

    findings
    |> add_if(
      mode == "api" and blank?(api_type),
      manifest,
      :api,
      "api.type is required when source_mode is \"api\""
    )
    |> add_if(
      mode == "api" and present?(api_type) and api_type not in @allowed_api_types,
      manifest,
      :api,
      "api.type must be one of: #{Enum.join(@allowed_api_types, ", ")}"
    )
  end

  defp add_api_endpoint_finding(findings, manifest) do
    mode = effective_source_mode_for_validation(manifest)
    api = get_field(manifest, :api) || %{}
    endpoint = Map.get(api, :endpoint) || Map.get(api, "endpoint")
    uri = parse_uri(endpoint)
    source_hosts = source_hosts(manifest)
    endpoint_host = normalized_host(uri.host)

    findings
    |> add_if(
      mode == "api" and blank?(endpoint),
      manifest,
      :api,
      "api.endpoint is required when source_mode is \"api\""
    )
    |> add_if(
      mode == "api" and present?(endpoint) and uri.scheme != "https",
      manifest,
      :api,
      "api.endpoint must be HTTPS"
    )
    |> add_if(
      mode == "api" and present?(endpoint) and present?(uri.userinfo),
      manifest,
      :api,
      "api.endpoint must not include userinfo"
    )
    |> add_if(
      mode == "api" and present?(endpoint) and blank?(uri.host),
      manifest,
      :api,
      "api.endpoint must include a host"
    )
    |> add_if(
      mode == "api" and present?(endpoint) and present?(endpoint_host) and
        endpoint_host not in source_hosts,
      manifest,
      :api,
      "api.endpoint host must be listed in source_hosts"
    )
    |> add_if(
      mode == "api" and present?(endpoint) and private_endpoint_host?(endpoint_host),
      manifest,
      :api,
      "api.endpoint host must not be private, loopback, or link-local"
    )
  end

  # --- spider.module when effective source_mode is "scrape" ---

  defp add_spider_module_finding(findings, manifest) do
    mode = effective_source_mode_for_validation(manifest)
    spider = get_field(manifest, :spider) || %{}
    spider_module = Map.get(spider, :module) || Map.get(spider, "module")

    add_if(
      findings,
      mode == "scrape" and blank?(spider_module),
      manifest,
      :spider,
      "spider.module is required when source_mode is \"scrape\""
    )
  end

  defp add_spider_start_urls_finding(findings, manifest) do
    mode = effective_source_mode_for_validation(manifest)
    spider = get_field(manifest, :spider) || %{}
    start_urls = Map.get(spider, :start_urls) || Map.get(spider, "start_urls") || []

    if mode == "scrape" do
      start_urls
      |> List.wrap()
      |> Enum.reduce(findings, fn url, acc ->
        add_url_policy_findings(
          acc,
          manifest,
          :spider,
          "spider.start_url",
          url,
          source_hosts(manifest)
        )
      end)
    else
      findings
    end
  end

  # --- expected_record_count must be positive integer ---

  defp add_expected_record_count_finding(findings, manifest) do
    count =
      Map.get(manifest, :expected_record_count) || Map.get(manifest, "expected_record_count")

    findings
    |> add_if(
      present?(count) and not is_integer(count),
      manifest,
      :expected_record_count,
      "expected_record_count must be a positive integer"
    )
    |> add_if(
      is_integer(count) and count < 1,
      manifest,
      :expected_record_count,
      "expected_record_count must be a positive integer"
    )
  end

  defp add_url_policy_findings(findings, manifest, field, label, url, source_hosts) do
    uri = parse_uri(url)
    host = normalized_host(uri.host)

    findings
    |> add_if(
      present?(url) and uri.scheme != "https",
      manifest,
      field,
      "#{label} must be HTTPS"
    )
    |> add_if(
      present?(url) and present?(uri.userinfo),
      manifest,
      field,
      "#{label} must not include userinfo"
    )
    |> add_if(
      present?(url) and blank?(uri.host),
      manifest,
      field,
      "#{label} must include a host"
    )
    |> add_if(
      present?(url) and present?(host) and host not in source_hosts,
      manifest,
      field,
      "#{label} host must be listed in source_hosts"
    )
    |> add_if(
      present?(url) and private_endpoint_host?(host),
      manifest,
      field,
      "#{label} host must not be private, loopback, link-local, or unspecified"
    )
  end

  # --- Helpers (mirror existing Validator patterns) ---

  defp add_blank(findings, manifest, field, value, reason) do
    add_if(findings, blank?(value), manifest, field, reason)
  end

  defp add_if(findings, true, manifest, field, reason),
    do: [finding(manifest, field, reason) | findings]

  defp add_if(findings, false, _manifest, _field, _reason), do: findings

  defp finding(manifest, field, reason) do
    %Finding{
      provider: Map.get(manifest, :provider) || Map.get(manifest, "provider"),
      field: field,
      reason: reason
    }
  end

  defp effective_source_mode_for_validation(manifest) do
    mode = get_field(manifest, :source_mode)

    cond do
      present?(mode) and mode in @allowed_source_modes -> mode
      config_present?(manifest, :spider) -> "scrape"
      config_present?(manifest, :api) -> "api"
      true -> nil
    end
  end

  defp config_present?(manifest, key) when is_atom(key) do
    value = get_field(manifest, key) || %{}
    is_map(value) and value != %{} and value != nil
  end

  defp get_field(manifest, key) when is_atom(key) do
    Map.get(manifest, key) || Map.get(manifest, to_string(key))
  end

  defp source_hosts(manifest) do
    manifest
    |> get_field(:source_hosts)
    |> List.wrap()
    |> Enum.map(&normalized_host/1)
    |> Enum.filter(&present?/1)
    |> Enum.reject(&private_endpoint_host?/1)
  end

  defp parse_uri(value) when is_binary(value), do: URI.parse(value)
  defp parse_uri(_value), do: %URI{}

  defp normalized_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalized_host(_host), do: nil

  defp private_endpoint_host?(host) when is_binary(host) do
    normalized = normalized_host(host)

    cond do
      normalized in ["localhost", "localhost.localdomain"] ->
        true

      address = parsed_ip_address(normalized) ->
        private_address?(address)

      true ->
        false
    end
  end

  defp private_endpoint_host?(_host), do: false

  defp parsed_ip_address(host) do
    case host |> String.to_charlist() |> :inet.parse_address() do
      {:ok, address} -> address
      {:error, :einval} -> legacy_ipv4_address(host)
    end
  end

  defp legacy_ipv4_address(host) do
    with true <- Regex.match?(~r/\A[0-9A-Fa-fxX.]+\z/, host),
         {:ok, integer} <- legacy_ipv4_integer(String.split(host, ".")),
         true <- integer in 0..0xFFFF_FFFF do
      {band(bsr(integer, 24), 0xFF), band(bsr(integer, 16), 0xFF), band(bsr(integer, 8), 0xFF),
       band(integer, 0xFF)}
    else
      _ -> nil
    end
  end

  defp legacy_ipv4_integer(parts) when length(parts) in 1..4 do
    with {:ok, numbers} <- parse_legacy_ipv4_parts(parts) do
      legacy_ipv4_integer_from_parts(numbers)
    end
  end

  defp legacy_ipv4_integer(_parts), do: :error

  defp parse_legacy_ipv4_parts(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_legacy_ipv4_part(part) do
        {:ok, number} -> {:cont, {:ok, [number | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp parse_legacy_ipv4_part(""), do: :error

  defp parse_legacy_ipv4_part(part) do
    {base, digits} = legacy_ipv4_base_and_digits(part)

    case Integer.parse(digits, base) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp legacy_ipv4_base_and_digits("0x" <> digits), do: {16, digits}
  defp legacy_ipv4_base_and_digits("0X" <> digits), do: {16, digits}

  defp legacy_ipv4_base_and_digits("0" <> digits) when digits != "",
    do: {8, digits}

  defp legacy_ipv4_base_and_digits(digits), do: {10, digits}

  defp legacy_ipv4_integer_from_parts([address]) when address in 0..0xFFFF_FFFF,
    do: {:ok, address}

  defp legacy_ipv4_integer_from_parts([a, b]) when a in 0..0xFF and b in 0..0xFF_FFFF,
    do: {:ok, bor(bsl(a, 24), b)}

  defp legacy_ipv4_integer_from_parts([a, b, c])
       when a in 0..0xFF and b in 0..0xFF and c in 0..0xFFFF,
       do: {:ok, bor(bor(bsl(a, 24), bsl(b, 16)), c)}

  defp legacy_ipv4_integer_from_parts([a, b, c, d])
       when a in 0..0xFF and b in 0..0xFF and c in 0..0xFF and d in 0..0xFF,
       do: {:ok, bor(bor(bor(bsl(a, 24), bsl(b, 16)), bsl(c, 8)), d)}

  defp legacy_ipv4_integer_from_parts(_parts), do: :error

  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({172, second, _, _}) when second in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({_, _, _, _}), do: false
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    high
    |> ipv4_tuple_from_words(low)
    |> private_address?()
  end

  defp private_address?({first, _, _, _, _, _, _, _})
       when band(first, 0xFFC0) == 0xFE80,
       do: true

  defp private_address?({first, _, _, _, _, _, _, _})
       when band(first, 0xFE00) == 0xFC00,
       do: true

  defp private_address?({_, _, _, _, _, _, _, _}), do: false

  defp ipv4_tuple_from_words(high, low) do
    {band(bsr(high, 8), 0xFF), band(high, 0xFF), band(bsr(low, 8), 0xFF), band(low, 0xFF)}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp blank?(value),
    do: value in [nil, []] or (is_binary(value) and String.trim(value) == "")
end
