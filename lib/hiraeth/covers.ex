defmodule Hiraeth.Covers do
  use Ash.Domain

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.RealCatalog.SourcePolicy

  @cache_root "priv/static/covers/cache"
  @thumbnail_timeout 5_000
  @thumbnail_command_timeout "5s"

  resources do
    resource Hiraeth.Covers.CoverAsset
    resource Hiraeth.Covers.CoverAssignment
  end

  def fallback_cover do
    %{
      source_url: nil,
      provider: "hiraeth",
      rights_basis: "fallback_placeholder",
      cache_policy: "generated_placeholder",
      attribution_text: "No public cover available"
    }
  end

  def public_cover_for_edition(edition_id) do
    assignment =
      CoverAssignment
      |> Ash.Query.for_read(:public_for_edition, %{edition_id: edition_id})
      |> Ash.read!()
      |> Ash.load!(:cover_asset)
      |> Enum.find(fn assignment -> public_cover_asset?(assignment.cover_asset) end)

    case assignment do
      nil -> fallback_cover()
      %{cover_asset: cover_asset} -> public_cover_map(cover_asset)
    end
  end

  def audit_public_cover_provenance!(path) do
    assignments =
      CoverAssignment
      |> Ash.Query.for_read(:public)
      |> Ash.read!()
      |> Ash.load!([:cover_asset, :edition])

    invalid_public_covers =
      assignments
      |> Enum.reject(fn assignment -> public_cover_provenance_valid?(assignment.cover_asset) end)
      |> Enum.map(fn assignment ->
        %{
          cover_assignment_id: assignment.id,
          cover_asset_id: assignment.cover_asset_id,
          edition_id: assignment.edition_id,
          reason: "public assignment does not have valid visible cover provenance"
        }
      end)

    audit = %{
      checked_public_assignments: Enum.count(assignments),
      invalid_public_covers: invalid_public_covers
    }

    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(audit, pretty: true))

    audit
  end

  def public_cover_asset?(%CoverAsset{} = cover_asset) do
    uri = parse_uri(cover_asset.source_url)

    cover_asset.takedown_state == "visible" and present?(cover_asset.source_url) and
      present?(cover_asset.provider) and present?(cover_asset.rights_basis) and
      uri.scheme == "https" and SourcePolicy.cover_host_allowed?(cover_asset.provider, uri.host) and
      cache_policy_public?(cover_asset)
  end

  def public_cover_asset?(_cover_asset), do: false

  def public_cover_provenance_valid?(%CoverAsset{} = cover_asset) do
    uri = parse_uri(cover_asset.source_url)

    cover_asset.takedown_state == "visible" and present?(cover_asset.source_url) and
      present?(cover_asset.provider) and present?(cover_asset.rights_basis) and
      uri.scheme == "https" and SourcePolicy.cover_host_allowed?(cover_asset.provider, uri.host) and
      cache_policy_provenance_valid?(cover_asset)
  end

  def public_cover_provenance_valid?(_cover_asset), do: false

  def public_cover_rejection_reason(nil), do: "cover assignment has no cover asset"

  def public_cover_rejection_reason(%CoverAsset{} = asset) do
    uri = parse_uri(asset.source_url)

    cond do
      asset.takedown_state != "visible" ->
        "cover is hidden or under takedown"

      not present?(asset.source_url) ->
        "cover source URL is missing"

      not present?(asset.provider) ->
        "cover provider is missing"

      not present?(asset.rights_basis) ->
        "cover rights basis is missing"

      uri.scheme != "https" ->
        "cover source URL must be HTTPS"

      not SourcePolicy.cover_host_allowed?(asset.provider, uri.host) ->
        "cover source URL host is not allowlisted for provider"

      asset.cache_policy == "link_only" and
          (present?(asset.cached_file_path) or present?(asset.thumbnail_file_path)) ->
        "cover cache file path is not allowed for link-only public display"

      asset.cache_policy == "cache_allowed" and asset.rights_basis != "local_cache_permitted" ->
        "cached cover requires local cache rights basis"

      asset.cache_policy == "cache_allowed" and not present?(asset.cached_file_path) ->
        "cached cover file path is required for cacheable public display"

      asset.cache_policy == "cache_allowed" and present?(asset.cached_file_path) and
          not safe_cached_file_path?(asset.cached_file_path) ->
        "cached cover file path must be under priv/static/covers/cache"

      asset.cache_policy not in ["link_only", "cache_allowed"] ->
        "cover cache_policy must be link_only or cache_allowed"

      true ->
        "cover provenance is incomplete"
    end
  end

  def cache_public_covers!(opts \\ []) do
    cache_root = opts |> Keyword.get(:cache_root, @cache_root) |> ensure_safe_cache_root!()
    force? = Keyword.get(opts, :force?, false)
    req_options = Keyword.get(opts, :req_options, [])
    fetch = Keyword.get(opts, :fetch, fn url -> req_fetch!(url, req_options) end)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    timeout = Keyword.get(opts, :timeout, 15_000)
    thumbnailer = Keyword.get(opts, :thumbnailer, &generate_thumbnail/2)
    thumbnail_timeout = Keyword.get(opts, :thumbnail_timeout, @thumbnail_timeout)
    strict? = Keyword.get(opts, :strict?, false)
    source_urls = Keyword.get(opts, :source_urls, :all)

    File.mkdir_p!(cache_root)

    CoverAsset
    |> Ash.read!(authorize?: false)
    |> filter_source_urls(source_urls)
    |> Enum.filter(&cache_candidate?/1)
    |> Task.async_stream(
      &cover_cache_plan(&1, cache_root, force?, fetch),
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{cached: 0, skipped: 0, failed: 0, failures: [], assets: []}, fn
      {:ok, {:skip, _asset}}, summary ->
        %{summary | skipped: summary.skipped + 1}

      {:ok, {:thumbnail, asset, cache_path, thumbnail_path}}, summary ->
        thumbnail_file_path =
          maybe_generate_thumbnail(cache_path, thumbnail_path, thumbnailer, thumbnail_timeout)

        cached_asset =
          asset
          |> Ash.Changeset.for_update(:update, %{thumbnail_file_path: thumbnail_file_path})
          |> Ash.update!(authorize?: false)

        %{summary | cached: summary.cached + 1, assets: [cached_asset | summary.assets]}

      {:ok, {:cache, asset, cache_path, body}}, summary ->
        File.write!(cache_path, body)

        thumbnail_file_path =
          maybe_generate_thumbnail(
            cache_path,
            thumbnail_path(asset, cache_root),
            thumbnailer,
            thumbnail_timeout
          )

        cached_asset =
          asset
          |> Ash.Changeset.for_update(:update, %{
            cache_policy: "cache_allowed",
            cached_file_path: cache_path,
            thumbnail_file_path: thumbnail_file_path,
            cached_at: DateTime.utc_now(:second)
          })
          |> Ash.update!(authorize?: false)

        %{summary | cached: summary.cached + 1, assets: [cached_asset | summary.assets]}

      {:ok, {:error, asset, reason}}, summary ->
        handle_cache_failure(summary, asset.source_url, reason, strict?)

      {:exit, reason}, summary ->
        handle_cache_failure(summary, nil, inspect(reason), strict?)
    end)
    |> Map.update!(:assets, &Enum.reverse/1)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  defp filter_source_urls(assets, :all), do: assets

  defp filter_source_urls(assets, source_urls) when is_list(source_urls) do
    allowed = MapSet.new(source_urls)
    Enum.filter(assets, &MapSet.member?(allowed, &1.source_url))
  end

  defp cover_cache_plan(%CoverAsset{} = asset, cache_root, force?, fetch) do
    cache_path = cache_path(asset, cache_root)
    thumbnail_path = thumbnail_path(asset, cache_root)

    cond do
      not force? and cached_file_present?(asset.cached_file_path) and
          cached_file_present?(asset.thumbnail_file_path) ->
        {:skip, asset}

      not force? and cached_file_present?(asset.cached_file_path) ->
        {:thumbnail, asset, asset.cached_file_path, thumbnail_path}

      true ->
        try do
          {:cache, asset, cache_path, fetch.(asset.source_url)}
        rescue
          exception -> {:error, asset, Exception.message(exception)}
        catch
          kind, reason -> {:error, asset, "#{kind}: #{inspect(reason)}"}
        end
    end
  end

  defp handle_cache_failure(_summary, source_url, reason, true) do
    raise "cover cache failed for #{source_url || "unknown source"}: #{reason}"
  end

  defp handle_cache_failure(summary, source_url, reason, false) do
    failure = %{source_url: source_url, reason: reason}

    summary
    |> Map.update!(:failed, &(&1 + 1))
    |> Map.update!(:failures, &[failure | &1])
  end

  def purge_cached_cover!(%CoverAsset{} = asset) do
    if safe_cached_file_path?(asset.cached_file_path) and File.exists?(asset.cached_file_path) do
      File.rm!(asset.cached_file_path)
    end

    if safe_cached_file_path?(asset.thumbnail_file_path) and
         File.exists?(asset.thumbnail_file_path) do
      File.rm!(asset.thumbnail_file_path)
    end

    asset
    |> Ash.Changeset.for_update(:update, %{
      cached_file_path: nil,
      thumbnail_file_path: nil,
      cached_at: nil
    })
    |> Ash.update!(authorize?: false)
  end

  def cache_path(%CoverAsset{} = asset, cache_root \\ @cache_root) do
    extension = asset.source_url |> URI.parse() |> Map.get(:path) |> extension_from_path()
    Path.join(cache_root, "#{sha256(asset.source_url)}#{extension}")
  end

  def thumbnail_path(%CoverAsset{} = asset, cache_root \\ @cache_root) do
    Path.join(cache_root, "#{sha256(asset.source_url)}-thumb.jpg")
  end

  defp public_cover_map(%CoverAsset{} = cover_asset) do
    %{
      id: cover_asset.id,
      source_url: cover_asset.source_url,
      public_url: public_cover_url(cover_asset),
      provider: cover_asset.provider,
      rights_basis: cover_asset.rights_basis,
      attribution_text: cover_asset.attribution_text,
      attribution_url: cover_asset.attribution_url,
      cache_policy: cover_asset.cache_policy,
      cached_file_path: cover_asset.cached_file_path,
      thumbnail_file_path: cover_asset.thumbnail_file_path,
      thumbnail_url: public_thumbnail_url(cover_asset.thumbnail_file_path)
    }
  end

  defp public_cover_url(%CoverAsset{cache_policy: "cache_allowed", cached_file_path: path})
       when is_binary(path) do
    static_path(path) || path
  end

  defp public_cover_url(%CoverAsset{} = cover_asset), do: cover_asset.source_url

  defp public_thumbnail_url(path) do
    if safe_cached_file_path?(path), do: static_path(path)
  end

  defp cache_policy_public?(%CoverAsset{cache_policy: "link_only"} = asset),
    do: not present?(asset.cached_file_path) and not present?(asset.thumbnail_file_path)

  defp cache_policy_public?(%CoverAsset{cache_policy: "cache_allowed"} = asset),
    do:
      asset.rights_basis == "local_cache_permitted" and
        safe_cached_file_path?(asset.cached_file_path)

  defp cache_policy_public?(_asset), do: false

  defp cache_policy_provenance_valid?(%CoverAsset{cache_policy: "link_only"} = asset),
    do: not present?(asset.cached_file_path) and not present?(asset.thumbnail_file_path)

  defp cache_policy_provenance_valid?(%CoverAsset{cache_policy: "cache_allowed"} = asset),
    do:
      asset.rights_basis == "local_cache_permitted" and
        (not present?(asset.cached_file_path) or safe_cached_file_path?(asset.cached_file_path))

  defp cache_policy_provenance_valid?(_asset), do: false

  defp maybe_generate_thumbnail(source_path, thumbnail_path, thumbnailer, timeout) do
    with true <- safe_cached_file_path?(source_path),
         true <- String.starts_with?(Path.expand(thumbnail_path), expanded_cache_root() <> "/"),
         {:ok, generated_path} <-
           run_thumbnailer(thumbnailer, source_path, thumbnail_path, timeout),
         true <- safe_cached_file_path?(generated_path) do
      generated_path
    else
      _ -> nil
    end
  end

  defp run_thumbnailer(thumbnailer, source_path, thumbnail_path, timeout)
       when is_function(thumbnailer, 2) do
    task = Task.async(fn -> thumbnailer.(source_path, thumbnail_path) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, generated_path}} when is_binary(generated_path) -> {:ok, generated_path}
      {:ok, generated_path} when is_binary(generated_path) -> {:ok, generated_path}
      _result -> :error
    end
  end

  defp run_thumbnailer(_thumbnailer, _source_path, _thumbnail_path, _timeout), do: :error

  defp generate_thumbnail(source_path, thumbnail_path) do
    with magick when is_binary(magick) <- System.find_executable("magick"),
         timeout when is_binary(timeout) <- System.find_executable("timeout"),
         {_, 0} <-
           System.cmd(
             timeout,
             [
               @thumbnail_command_timeout,
               magick,
               source_path,
               "-auto-orient",
               "-thumbnail",
               "400x600>",
               "-strip",
               "-quality",
               "82",
               thumbnail_path
             ],
             stderr_to_stdout: true
           ),
         true <- File.exists?(thumbnail_path) do
      {:ok, thumbnail_path}
    else
      _ -> nil
    end
  end

  defp cache_candidate?(%CoverAsset{} = asset) do
    uri = parse_uri(asset.source_url)

    asset.takedown_state == "visible" and asset.cache_policy == "cache_allowed" and
      asset.rights_basis == "local_cache_permitted" and present?(asset.source_url) and
      uri.scheme == "https" and SourcePolicy.cover_host_allowed?(asset.provider, uri.host)
  end

  defp safe_cached_file_path?(path) when is_binary(path) do
    path = Path.expand(path)
    cache_root = expanded_cache_root()

    with true <- String.starts_with?(path, cache_root <> "/"),
         true <- cache_root_directory?(cache_root),
         true <- no_symlink_components?(path, cache_root),
         true <- File.regular?(path) do
      true
    else
      _ -> false
    end
  end

  defp safe_cached_file_path?(_path), do: false

  defp cache_root_directory?(cache_root) do
    case File.lstat(cache_root) do
      {:ok, %{type: :directory}} -> true
      _ -> false
    end
  end

  defp no_symlink_components?(path, cache_root) do
    path
    |> Path.relative_to(cache_root)
    |> Path.split()
    |> Enum.reduce_while(cache_root, fn component, parent ->
      current = Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, false}
        {:ok, _stat} -> {:cont, current}
        {:error, _reason} -> {:halt, false}
      end
    end)
    |> is_binary()
  end

  defp cached_file_present?(path) when is_binary(path) do
    safe_cached_file_path?(path)
  end

  defp cached_file_present?(_path), do: false

  defp static_path(path) when is_binary(path) do
    path = Path.expand(path)
    static_root = Path.expand("priv/static")

    if String.starts_with?(path, static_root <> "/") do
      "/" <> Path.relative_to(path, static_root)
    end
  end

  defp static_path(_path), do: nil

  defp ensure_safe_cache_root!(cache_root) when is_binary(cache_root) do
    expanded_root = Path.expand(cache_root)
    allowed_root = expanded_cache_root()

    if expanded_root == allowed_root or String.starts_with?(expanded_root, allowed_root <> "/") do
      cache_root
    else
      raise ArgumentError,
            "cover cache_root must stay under #{@cache_root}, got: #{cache_root}"
    end
  end

  defp ensure_safe_cache_root!(cache_root) do
    raise ArgumentError, "cover cache_root must be a path string, got: #{inspect(cache_root)}"
  end

  defp expanded_cache_root, do: Path.expand(@cache_root)

  defp req_fetch!(url, req_options) do
    req_options =
      req_options
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:redirect, false)

    response = Req.get!(url, req_options)

    if response.status in 200..299 do
      response.body
    else
      raise "cover cache request failed with status #{response.status} for #{url}"
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

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp parse_uri(value) when is_binary(value), do: URI.parse(value)
  defp parse_uri(_value), do: %URI{}
end
