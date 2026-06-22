defmodule Hiraeth.Ingestion.CoverPipeline do
  @moduledoc """
  Downloads cover images from source URLs to the local cache, generates thumbnails,
  and validates provenance — all-or-nothing (if any cover fails, returns error).

  This module is used by ingestion workers to cache covers for newly imported
  provider records. It reuses existing `Hiraeth.Covers` helpers for HTTP fetching,
  thumbnail generation, and validation.
  """

  alias Hiraeth.Covers
  alias Hiraeth.RealCatalog.SourcePolicy

  @cache_root "priv/static/covers/cache"
  @default_max_body_size 10 * 1024 * 1024
  @default_max_concurrency 4

  @doc """
  Downloads and caches cover images for new provider records.

  `cover_urls` is a list of maps with the following keys:
    - `:source_url` — the HTTPS URL of the cover image
    - `:provider` — the provider slug (used for host allowlist validation)
    - `:rights_basis` — the rights basis string (e.g. "local_cache_permitted")
    - `:attribution_text` — attribution text for the cover

  `provider_config` is a map with the following optional keys:
    - `:max_concurrency` — max concurrent downloads (default 4)
    - `:max_body_size` — max response body in bytes (default 10MB)
    - `:req_options` — extra options passed to `Req` (e.g. `[plug: plug]` for testing)
    - `:thumbnailer` — a function `fn source_path, thumbnail_path -> result` used
      to generate thumbnails (defaults to `Covers.generate_thumbnail/2`)

  Returns `{:ok, cover_paths}` on success, where `cover_paths` is a map of
  `source_url` → `%{cached_file_path: path, thumbnail_file_path: path}`.

  Returns `{:error, failed_covers}` if any cover download fails, where
  `failed_covers` is a list of `%{source_url: url, reason: reason}`.
  """
  def download_and_cache!(cover_urls, provider_config) do
    cache_root = Path.expand(@cache_root)
    max_concurrency = Map.get(provider_config, :max_concurrency, @default_max_concurrency)
    max_body_size = Map.get(provider_config, :max_body_size, @default_max_body_size)
    req_options = Map.get(provider_config, :req_options, [])
    thumbnailer = Map.get(provider_config, :thumbnailer, &Covers.generate_thumbnail/2)

    File.mkdir_p!(cache_root)

    results =
      cover_urls
      |> Task.async_stream(
        &process_cover(&1, cache_root, max_body_size, req_options, thumbnailer),
        max_concurrency: max_concurrency,
        timeout: :infinity
      )
      |> Enum.to_list()

    {successes, failures} =
      Enum.split_with(results, fn {:ok, result} -> match?({:ok, _, _, _}, result) end)

    if Enum.any?(failures) do
      # All-or-nothing: clean up any successfully cached covers
      Enum.each(successes, fn {:ok, {:ok, _cover, cached_path, thumbnail_path}} ->
        File.rm(cached_path)
        File.rm(thumbnail_path)
      end)

      failed_covers =
        Enum.map(failures, fn {:ok, {:error, cover, reason}} ->
          %{source_url: cover.source_url, reason: reason}
        end)

      {:error, failed_covers}
    else
      cover_paths =
        Enum.into(successes, %{}, fn {:ok, {:ok, cover, cached_path, thumbnail_path}} ->
          {cover.source_url,
           %{cached_file_path: cached_path, thumbnail_file_path: thumbnail_path}}
        end)

      {:ok, cover_paths}
    end
  end

  defp process_cover(cover, cache_root, max_body_size, req_options, thumbnailer) do
    with :ok <- validate_url(cover),
         {:ok, body} <- fetch_cover(cover.source_url, req_options, max_body_size),
         cache_path = cache_path(cover.source_url, cache_root),
         :ok <- ensure_safe_cache_write_path!(cache_path, cache_root),
         :ok <- File.write(cache_path, body),
         thumbnail_path = thumbnail_path(cover.source_url, cache_root),
         {:ok, generated_thumbnail_path} <-
           run_thumbnailer(thumbnailer, cache_path, thumbnail_path) do
      {:ok, cover, cache_path, generated_thumbnail_path}
    else
      {:error, reason} -> {:error, cover, reason}
      nil -> {:error, cover, "thumbnail generation failed"}
    end
  rescue
    exception -> {:error, cover, Exception.message(exception)}
  catch
    kind, reason -> {:error, cover, "#{kind}: #{inspect(reason)}"}
  end

  defp validate_url(%{source_url: url, provider: provider}) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" ->
        {:error, "cover source URL must be HTTPS"}

      not SourcePolicy.cover_host_allowed?(provider, uri.host) ->
        {:error, "cover source URL host is not allowlisted for provider"}

      true ->
        :ok
    end
  end

  defp fetch_cover(url, req_options, max_body_size) do
    {:ok, Covers.req_fetch!(url, req_options, max_body_size)}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp run_thumbnailer(thumbnailer, source_path, thumbnail_path) do
    task = Task.async(fn -> thumbnailer.(source_path, thumbnail_path) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, generated_path}} when is_binary(generated_path) -> {:ok, generated_path}
      {:ok, generated_path} when is_binary(generated_path) -> {:ok, generated_path}
      _result -> {:error, "thumbnail generation failed"}
    end
  end

  defp cache_path(source_url, cache_root) do
    extension = source_url |> URI.parse() |> Map.get(:path) |> extension_from_path()
    Path.join(cache_root, "#{sha256(source_url)}#{extension}")
  end

  defp thumbnail_path(source_url, cache_root) do
    Path.join(cache_root, "#{sha256(source_url)}-thumb.jpg")
  end

  defp ensure_safe_cache_write_path!(cache_path, cache_root) do
    expanded_path = Path.expand(cache_path)
    expanded_root = Path.expand(cache_root)

    if String.starts_with?(expanded_path, expanded_root <> "/") do
      :ok
    else
      {:error, "cover cache path must stay under cache root: #{cache_path}"}
    end
  end

  defp extension_from_path(path) when is_binary(path) do
    case path |> Path.extname() |> String.downcase() do
      extension when extension in [".jpg", ".jpeg", ".png", ".webp", ".gif"] -> extension
      _extension -> ".jpg"
    end
  end

  defp extension_from_path(_path), do: ".jpg"

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
