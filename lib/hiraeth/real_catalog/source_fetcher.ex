defmodule Hiraeth.RealCatalog.SourceFetcher do
  @moduledoc """
  Bounded retrieval guard for approved real-catalog source artifacts.

  Normal tests should use checked-in fixture artifacts, not live network. This
  module exists for explicit operator-driven refreshes and enforces the source
  authority manifest before any request is made.
  """

  alias Hiraeth.RealCatalog.Dataset

  @default_receive_timeout_ms 15_000

  defmodule SourceError do
    defexception [:message]
  end

  def plan_sources(dir \\ Dataset.default_dir()) do
    with {:ok, manifest} <- Dataset.load_source_authority_manifest(dir) do
      manifest
      |> Map.get("providers", [])
      |> Enum.flat_map(&provider_sources/1)
      |> Enum.sort_by(&{&1.provider, &1.url})
      |> then(&{:ok, &1})
    end
  end

  def fetch!(provider, url, output_dir, opts \\ []) do
    dir = Keyword.get(opts, :dataset_dir, Dataset.default_dir())
    manifest = Keyword.get_lazy(opts, :manifest, fn -> load_manifest!(dir) end)
    provider_policy = provider_policy!(manifest, provider)
    source = source_policy!(provider_policy, url)
    max_bytes = get_in(provider_policy, ["max_bytes", "response"]) || 0

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise SourceError, "source response max_bytes must be a positive integer for #{provider}"
    end

    File.mkdir_p!(output_dir)

    into = bounded_body_collector(max_bytes)
    req_options = Keyword.get(opts, :req_options, [])

    response =
      req_options
      |> Keyword.merge(
        decode_body: false,
        into: into,
        redirect: false,
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout_ms)
      )
      |> then(&Req.get!(url, &1))

    unless response.status in 200..299 do
      raise SourceError,
            "source response for #{provider} returned HTTP #{response.status}: #{url}"
    end

    body = IO.iodata_to_binary(response.body || "")
    byte_size = response.private[:hiraeth_source_fetcher_bytes] || byte_size(body)

    if max_bytes > 0 and byte_size > max_bytes do
      raise SourceError,
            "source response for #{provider} exceeds max_bytes #{max_bytes}: #{byte_size}"
    end

    if html_response?(response, body) do
      raise SourceError, "HTML source responses are not approved for #{provider}: #{url}"
    end

    checksum = sha256(body)
    artifact_path = Path.join(output_dir, artifact_filename(provider, checksum, url))
    metadata_path = artifact_path <> ".metadata.json"

    File.write!(artifact_path, body)

    metadata = %{
      "provider" => provider,
      "url" => url,
      "source_type" => source.source_type,
      "status" => response.status,
      "byte_size" => byte_size,
      "sha256" => checksum,
      "retrieved_at" =>
        Keyword.get(opts, :retrieved_at, DateTime.utc_now(:second) |> DateTime.to_iso8601()),
      "max_bytes" => max_bytes,
      "headers" => response.headers
    }

    File.write!(metadata_path, Jason.encode!(metadata, pretty: true))
    Map.put(metadata, "artifact_path", artifact_path)
  end

  def validate_source!(provider, url, dir \\ Dataset.default_dir()) do
    dir
    |> load_manifest!()
    |> provider_policy!(provider)
    |> source_policy!(url)
  end

  defp provider_sources(provider_policy) do
    provider = Map.fetch!(provider_policy, "provider")

    provider_policy
    |> Map.get("allowed_source_urls", [])
    |> Enum.flat_map(fn url ->
      case source_type(provider_policy, url) do
        nil ->
          []

        source_type ->
          [
            %{
              provider: provider,
              url: url,
              source_type: source_type,
              max_bytes: get_in(provider_policy, ["max_bytes", "response"]),
              rate_limit: Map.get(provider_policy, "rate_limit", %{})
            }
          ]
      end
    end)
  end

  defp load_manifest!(dir) do
    case Dataset.load_source_authority_manifest(dir) do
      {:ok, manifest} ->
        manifest

      {:error, reason} ->
        raise SourceError, "cannot load source authority manifest: #{inspect(reason)}"
    end
  end

  defp provider_policy!(manifest, provider) do
    manifest
    |> Map.get("providers", [])
    |> Enum.find(&(&1["provider"] == provider)) ||
      raise SourceError, "provider #{provider} is not listed in source authority manifest"
  end

  defp source_policy!(provider_policy, url) do
    cond do
      url not in Map.get(provider_policy, "allowed_source_urls", []) ->
        raise SourceError,
              "source URL is not allowlisted for #{provider_policy["provider"]}: #{url}"

      source_type = source_type(provider_policy, url) ->
        %{provider: provider_policy["provider"], url: url, source_type: source_type}

      true ->
        raise SourceError,
              "allowlisted URL is not a machine-readable source artifact for #{provider_policy["provider"]}: #{url}"
    end
  end

  defp source_type(provider_policy, url) do
    provider_policy
    |> Map.get("allowed_source_types", [])
    |> Enum.find(fn type -> source_type_matches_url?(type, url) end)
  end

  defp source_type_matches_url?("official_shopify_products_json", url),
    do: String.contains?(url, "products.json")

  defp source_type_matches_url?("official_woocommerce_store_api", url),
    do: String.contains?(url, "/wp-json/wc/store/products")

  defp source_type_matches_url?("official_catalog_pdf", url),
    do: String.ends_with?(URI.parse(url).path || "", ".pdf")

  defp source_type_matches_url?(_type, _url), do: false

  defp bounded_body_collector(max_bytes) do
    fn {:data, data}, {request, response} ->
      byte_size = (response.private[:hiraeth_source_fetcher_bytes] || 0) + byte_size(data)
      response = put_in(response.private[:hiraeth_source_fetcher_bytes], byte_size)

      if max_bytes > 0 and byte_size > max_bytes do
        {:halt, {request, response}}
      else
        {:cont, {request, %{response | body: [response.body, data]}}}
      end
    end
  end

  defp html_response?(response, body) do
    content_type =
      response.headers |> Map.get("content-type", []) |> List.wrap() |> Enum.join(";")

    String.contains?(String.downcase(content_type), "text/html") or
      binary_starts_with?(body, "<!doctype html") or
      binary_starts_with?(body, "<!DOCTYPE html") or
      binary_starts_with?(body, "<html")
  end

  defp binary_starts_with?(body, prefix),
    do: :binary.match(body, prefix) == {0, byte_size(prefix)}

  defp artifact_filename(provider, checksum, url) do
    ext = if String.ends_with?(URI.parse(url).path || "", ".pdf"), do: ".pdf", else: ".bin"
    "#{provider}-#{String.slice(checksum, 0, 16)}#{ext}"
  end

  defp sha256(body) do
    body
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
