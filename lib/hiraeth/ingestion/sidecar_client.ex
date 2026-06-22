defmodule Hiraeth.Ingestion.SidecarClient do
  @moduledoc """
  Req-based HTTP client for communicating with the Scrapling FastAPI sidecar.

  Provides `health/0`, `fetch/1`, and `scrape/1` functions that return
  `{:ok, result}` or `{:error, reason}` tuples and never raise.
  """

  @health_timeout 30_000
  @scrape_timeout 300_000
  @detail_timeout 10_000
  @detail_max_retries 3

  @doc """
  Checks sidecar health via GET /health/.

  Returns `{:ok, %{status: "ok", scrapling: true}}` on success,
  or `{:error, reason}` on failure.
  """
  def health(opts \\ []) do
    base_url = base_url()
    req_options = Keyword.get(opts, :req_options, [])

    default_options = [
      receive_timeout: @health_timeout,
      retry: false
    ]

    case Req.get("#{base_url}/health/", Keyword.merge(default_options, req_options)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: body["status"], scrapling: body["scrapling"]}}

      {:ok, %{status: status}} ->
        {:error, "sidecar health check failed with status #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  @doc """
  Fetches records from the sidecar via POST /fetch/.

  `provider_config` is a map with `provider` (slug) and `config` (manifest map).
  Returns `{:ok, %{records: [...]}}` on success, or `{:error, reason}` on failure.
  """
  def fetch(provider_config, opts \\ []) do
    base_url = base_url()
    req_options = Keyword.get(opts, :req_options, [])

    default_options = [
      json: provider_config,
      receive_timeout: @scrape_timeout,
      retry: false
    ]

    case Req.post("#{base_url}/fetch/", Keyword.merge(default_options, req_options)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        status_message = body["status"] || ""

        if String.starts_with?(status_message, "error:") do
          {:error, status_message}
        else
          {:ok, %{records: body["records"] || []}}
        end

      {:ok, %{status: status}} ->
        {:error, "sidecar fetch failed with status #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  @doc """
  Scrapes records from the sidecar via POST /scrape/.

  `provider_config` is a map with `provider` (slug) and `config` (manifest map).
  Returns `{:ok, %{records: [...]}}` on success, or `{:error, reason}` on failure.
  """
  def scrape(provider_config, opts \\ []) do
    base_url = base_url()
    req_options = Keyword.get(opts, :req_options, [])

    default_options = [
      json: provider_config,
      receive_timeout: @scrape_timeout,
      retry: false
    ]

    case Req.post("#{base_url}/scrape/", Keyword.merge(default_options, req_options)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        status_message = body["status"] || ""

        if String.starts_with?(status_message, "error:") do
          {:error, status_message}
        else
          {:ok, %{records: body["records"] || []}}
        end

      {:ok, %{status: status}} ->
        {:error, "sidecar scrape failed with status #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  @doc """
  Fetches detail-page enrichment from the sidecar via POST /scrape/detail.

  Returns `{:ok, detail}` on success, or `{:error, reason}` on failure.
  The detail endpoint is intentionally bounded because worker ingestion can
  proceed with the original record if detail enrichment is unavailable.
  """
  def detail(source_uri, vendor, opts \\ []) when is_binary(source_uri) and is_binary(vendor) do
    base_url = base_url()
    req_options = Keyword.get(opts, :req_options, [])

    default_options = [
      json: detail_request_body(source_uri, vendor, opts),
      receive_timeout: @detail_timeout,
      retry: :transient,
      max_retries: @detail_max_retries
    ]

    case Req.post("#{base_url}/scrape/detail", Keyword.merge(default_options, req_options)) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "sidecar detail failed with status #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp base_url do
    Application.get_env(:hiraeth, :scrapling_sidecar)[:base_url]
  end

  defp detail_request_body(source_uri, vendor, opts) do
    case Keyword.get(opts, :max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        %{url: source_uri, vendor: vendor, max_bytes: max_bytes}

      _max_bytes ->
        %{url: source_uri, vendor: vendor}
    end
  end
end
