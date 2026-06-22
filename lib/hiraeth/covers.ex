defmodule Hiraeth.Covers do
  use Ash.Domain

  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.RealCatalog.SourcePolicy

  @cache_root "priv/static/covers/cache"
  @thumbnail_timeout 5_000
  @thumbnail_command_timeout "5s"
  @default_max_body_size 10 * 1024 * 1024

  @accepted_content_types %{
    "image/jpeg" => :jpeg,
    "image/jpg" => :jpeg,
    "image/png" => :png,
    "image/webp" => :webp,
    "image/gif" => :gif
  }

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

      asset.cache_policy == "link_only" ->
        "public cover display requires cache_allowed with a validated local cached file"

      asset.cache_policy == "cache_allowed" and asset.rights_basis != "local_cache_permitted" ->
        "cached cover requires local cache rights basis"

      asset.cache_policy == "cache_allowed" and not present?(asset.cached_file_path) ->
        "cached cover file path is required for cacheable public display"

      asset.cache_policy == "cache_allowed" and present?(asset.cached_file_path) and
          not safe_cached_file_path?(asset.cached_file_path) ->
        "cached cover file path must be under priv/static/covers/cache"

      asset.cache_policy not in ["link_only", "cache_allowed"] ->
        "cover cache_policy must be cache_allowed with a validated local cached file"

      true ->
        "cover provenance is incomplete"
    end
  end

  def cache_public_covers!(opts \\ []) do
    cache_root = opts |> Keyword.get(:cache_root, @cache_root) |> ensure_safe_cache_root!()
    force? = Keyword.get(opts, :force?, false)
    req_options = Keyword.get(opts, :req_options, [])
    max_body_size = Keyword.get(opts, :max_body_size, @default_max_body_size)
    fetch = Keyword.get(opts, :fetch, fn url -> req_fetch!(url, req_options, max_body_size) end)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    timeout = Keyword.get(opts, :timeout, 15_000)
    thumbnailer = Keyword.get(opts, :thumbnailer, &generate_thumbnail/2)
    thumbnail_timeout = Keyword.get(opts, :thumbnail_timeout, @thumbnail_timeout)
    strict? = Keyword.get(opts, :strict?, false)
    source_urls = Keyword.get(opts, :source_urls, :all)

    File.mkdir_p!(cache_root)
    verify_safe_cache_root!(cache_root)

    CoverAsset
    |> Ash.read!(authorize?: false)
    |> filter_source_urls(source_urls)
    |> Enum.filter(&cache_candidate?/1)
    |> Task.async_stream(
      &cover_cache_plan(&1, cache_root, force?, fetch, max_body_size),
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

      {:ok, {:adopt, asset, cache_path, thumbnail_path}}, summary ->
        cached_asset =
          asset
          |> Ash.Changeset.for_update(:update, %{
            cache_policy: "cache_allowed",
            cached_file_path: cache_path,
            thumbnail_file_path: thumbnail_path,
            cached_at: DateTime.utc_now(:second)
          })
          |> Ash.update!(authorize?: false)

        %{summary | cached: summary.cached + 1, assets: [cached_asset | summary.assets]}

      {:ok, {:cache, asset, cache_path, body}}, summary ->
        ensure_safe_cache_write_path!(cache_path, cache_root)
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

  defp cover_cache_plan(%CoverAsset{} = asset, cache_root, force?, fetch, max_body_size) do
    cache_path = cache_path(asset, cache_root)
    thumbnail_path = thumbnail_path(asset, cache_root)

    cond do
      not force? and cached_file_present?(asset.cached_file_path) and
          cached_file_present?(asset.thumbnail_file_path) ->
        {:skip, asset}

      not force? and cached_file_present?(asset.cached_file_path) ->
        {:thumbnail, asset, asset.cached_file_path, thumbnail_path}

      not force? and cached_file_present?(cache_path) and cached_file_present?(thumbnail_path) ->
        {:adopt, asset, cache_path, thumbnail_path}

      true ->
        try do
          {:cache, asset, cache_path,
           fetch.(asset.source_url) |> validate_fetched_cover!(asset.source_url, max_body_size)}
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
    static_path(path)
  end

  defp public_cover_url(%CoverAsset{}), do: nil

  defp public_thumbnail_url(path) do
    if safe_cached_file_path?(path), do: static_path(path)
  end

  defp cache_policy_public?(%CoverAsset{cache_policy: "cache_allowed"} = asset),
    do:
      asset.rights_basis == "local_cache_permitted" and
        safe_cached_file_path?(asset.cached_file_path)

  defp cache_policy_public?(_asset), do: false

  defp cache_policy_provenance_valid?(%CoverAsset{cache_policy: "cache_allowed"} = asset),
    do:
      asset.rights_basis == "local_cache_permitted" and
        (not present?(asset.cached_file_path) or safe_cached_file_path?(asset.cached_file_path))

  defp cache_policy_provenance_valid?(_asset), do: false

  defp maybe_generate_thumbnail(source_path, thumbnail_path, thumbnailer, timeout) do
    with true <- safe_cached_file_path?(source_path),
         true <- safe_cache_write_path?(thumbnail_path, expanded_cache_root()),
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

  @doc false
  def generate_thumbnail(source_path, thumbnail_path) do
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

    cond do
      expanded_root != allowed_root and
          not String.starts_with?(expanded_root, allowed_root <> "/") ->
        raise ArgumentError,
              "cover cache_root must stay under #{@cache_root}, got: #{cache_root}"

      symlink_path_component?(expanded_root, allowed_root) ->
        raise ArgumentError,
              "cover cache_root must not include symlink path components, got: #{cache_root}"

      true ->
        cache_root
    end
  end

  defp ensure_safe_cache_root!(cache_root) do
    raise ArgumentError, "cover cache_root must be a path string, got: #{inspect(cache_root)}"
  end

  defp verify_safe_cache_root!(cache_root) do
    expanded_root = Path.expand(cache_root)
    allowed_root = expanded_cache_root()

    with true <-
           expanded_root == allowed_root or
             String.starts_with?(expanded_root, allowed_root <> "/"),
         false <- symlink_path_component?(expanded_root, allowed_root),
         {:ok, %{type: :directory}} <- File.lstat(expanded_root) do
      :ok
    else
      _ ->
        raise ArgumentError,
              "cover cache_root must be a non-symlink directory under #{@cache_root}, got: #{cache_root}"
    end
  end

  defp ensure_safe_cache_write_path!(cache_path, cache_root) do
    unless safe_cache_write_path?(cache_path, cache_root) do
      raise ArgumentError,
            "cover cache path must stay under a non-symlink cache_root before writes: #{cache_path}"
    end
  end

  defp safe_cache_write_path?(cache_path, cache_root)
       when is_binary(cache_path) and is_binary(cache_root) do
    expanded_path = Path.expand(cache_path)
    expanded_root = Path.expand(cache_root)

    with true <- String.starts_with?(expanded_path, expanded_root <> "/"),
         false <- symlink_path_component?(Path.dirname(expanded_path), expanded_root),
         false <- symlink_file?(expanded_path) do
      true
    else
      _ -> false
    end
  end

  defp safe_cache_write_path?(_cache_path, _cache_root), do: false

  defp symlink_path_component?(path, root) do
    root = Path.expand(root)

    path
    |> Path.expand()
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn component, parent ->
      current = Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, true}
        {:ok, _stat} -> {:cont, current}
        {:error, :enoent} -> {:halt, false}
        {:error, _reason} -> {:halt, false}
      end
    end)
    |> Kernel.==(true)
  end

  defp symlink_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  defp expanded_cache_root, do: Path.expand(@cache_root)

  @doc false
  def req_fetch!(url, req_options, max_body_size) do
    request_url = encoded_cover_request_url(url)

    req_options =
      req_options
      |> Keyword.put(:decode_body, false)
      |> Keyword.put(:redirect, false)
      |> Keyword.put(:into, bounded_cover_body_collector(max_body_size))

    response =
      request_url
      |> Req.get!(req_options)
      |> maybe_follow_open_library_cover_redirect(request_url, req_options)

    cond do
      response.status not in 200..299 ->
        raise "cover cache request failed with status #{response.status} for #{url}"

      response.private[:hiraeth_cover_body_too_large?] ->
        received_bytes = response.private[:hiraeth_cover_received_bytes] || 0

        raise "cover cache body size #{received_bytes} exceeds max body size #{max_body_size} for #{url}"

      true ->
        response
        |> put_streamed_cover_body()
        |> validate_fetched_cover!(url, max_body_size)
    end
  end

  defp encoded_cover_request_url(url) when is_binary(url) do
    uri = URI.parse(url)

    uri
    |> Map.put(:path, percent_encode_path(uri.path))
    |> URI.to_string()
  end

  defp percent_encode_path(nil), do: nil

  defp percent_encode_path(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.map(&URI.encode(&1, fn char -> URI.char_unreserved?(char) or char == ?% end))
    |> Enum.join("/")
  end

  defp maybe_follow_open_library_cover_redirect(response, request_url, req_options),
    do: follow_safe_open_library_cover_redirects(response, request_url, req_options, 3)

  defp follow_safe_open_library_cover_redirects(response, _request_url, _req_options, 0),
    do: response

  defp follow_safe_open_library_cover_redirects(
         %Req.Response{status: status} = response,
         request_url,
         req_options,
         remaining_hops
       )
       when status in 300..399 do
    with [location | _] <- Req.Response.get_header(response, "location"),
         {:ok, redirect_url} <- safe_open_library_cover_redirect_url(request_url, location) do
      redirect_url
      |> Req.get!(req_options)
      |> follow_safe_open_library_cover_redirects(redirect_url, req_options, remaining_hops - 1)
    else
      _not_safe_or_not_present -> response
    end
  end

  defp follow_safe_open_library_cover_redirects(
         response,
         _request_url,
         _req_options,
         _remaining_hops
       ),
       do: response

  defp safe_open_library_cover_redirect_url(request_url, location) do
    source_uri = URI.parse(request_url)
    target_uri = request_url |> URI.merge(location)

    if safe_open_library_cover_redirect?(source_uri.host, target_uri) do
      {:ok, URI.to_string(target_uri)}
    else
      :error
    end
  end

  defp safe_open_library_cover_redirect?("covers.openlibrary.org", %{
         scheme: "https",
         host: "archive.org",
         path: "/download/" <> _rest
       }),
       do: true

  defp safe_open_library_cover_redirect?("covers.openlibrary.org", %{scheme: "https", host: host}),
    do: internet_archive_cover_host?(host)

  defp safe_open_library_cover_redirect?("archive.org", %{scheme: "https", host: host}),
    do: internet_archive_cover_host?(host)

  defp safe_open_library_cover_redirect?(_source_host, _target_uri), do: false

  defp internet_archive_cover_host?(host) when is_binary(host),
    do: String.ends_with?(host, ".us.archive.org")

  defp internet_archive_cover_host?(_host), do: false

  defp bounded_cover_body_collector(max_body_size) do
    fn {:data, data}, {request, response} ->
      received_bytes = (response.private[:hiraeth_cover_received_bytes] || 0) + byte_size(data)

      private =
        response.private
        |> Map.put(:hiraeth_cover_received_bytes, received_bytes)

      if received_bytes > max_body_size do
        response = %{response | private: Map.put(private, :hiraeth_cover_body_too_large?, true)}
        {:halt, {request, response}}
      else
        private =
          Map.update(private, :hiraeth_cover_body_chunks, [data], fn chunks -> [data | chunks] end)

        {:cont, {request, %{response | private: private}}}
      end
    end
  end

  defp put_streamed_cover_body(%Req.Response{} = response) do
    body =
      response.private
      |> Map.get(:hiraeth_cover_body_chunks, [])
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    %{response | body: body}
  end

  defp validate_fetched_cover!(fetched, url, max_body_size) do
    {body, content_type} = fetched_cover_body_and_content_type(fetched)

    unless is_binary(body) do
      raise "cover cache body for #{url} must be binary raster image bytes"
    end

    body_size = byte_size(body)

    if body_size > max_body_size do
      raise "cover cache body size #{body_size} exceeds max body size #{max_body_size} for #{url}"
    end

    expected_type = validate_content_type!(content_type, url)
    detected_type = validate_raster_magic_bytes!(body, url)

    if expected_type && expected_type != detected_type do
      raise "cover cache content-type #{content_type} does not match raster magic bytes #{detected_type} for #{url}"
    end

    body
  end

  defp fetched_cover_body_and_content_type(%Req.Response{} = response) do
    content_type = response |> Req.Response.get_header("content-type") |> List.first()
    {response.body, content_type}
  end

  defp fetched_cover_body_and_content_type(%{body: body} = fetched) do
    content_type =
      fetched
      |> fetched_content_type()
      |> first_header_value()

    {body, content_type}
  end

  defp fetched_cover_body_and_content_type(body), do: {body, nil}

  defp fetched_content_type(fetched) do
    Map.get(fetched, :content_type) ||
      Map.get(fetched, "content-type") ||
      content_type_from_headers(Map.get(fetched, :headers))
  end

  defp content_type_from_headers(nil), do: nil

  defp content_type_from_headers(headers) when is_map(headers) do
    headers["content-type"] || headers["Content-Type"]
  end

  defp content_type_from_headers(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == "content-type", do: value

      _entry ->
        nil
    end)
  end

  defp content_type_from_headers(_headers), do: nil

  defp first_header_value([value | _rest]), do: value
  defp first_header_value(value), do: value

  defp validate_content_type!(nil, _url), do: nil

  defp validate_content_type!(content_type, url) when is_binary(content_type) do
    normalized =
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    case Map.fetch(@accepted_content_types, normalized) do
      {:ok, type} ->
        type

      :error ->
        raise "cover cache content-type must be image/jpeg, image/png, image/webp, or image/gif raster image/ bytes for #{url}; got #{content_type}"
    end
  end

  defp validate_content_type!(content_type, url) do
    raise "cover cache content-type must be an image/ raster value for #{url}; got #{inspect(content_type)}"
  end

  defp validate_raster_magic_bytes!(body, url) do
    cond do
      jpeg?(body) -> :jpeg
      png?(body) -> :png
      webp?(body) -> :webp
      gif?(body) -> :gif
      true -> raise "cover cache magic bytes do not identify an accepted raster image for #{url}"
    end
  end

  defp jpeg?(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: true
  defp jpeg?(_body), do: false

  defp png?(<<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: true
  defp png?(_body), do: false

  defp webp?(<<"RIFF", _size::little-32, "WEBP", _rest::binary>>), do: true
  defp webp?(_body), do: false

  defp gif?(<<"GIF87a", _rest::binary>>), do: true
  defp gif?(<<"GIF89a", _rest::binary>>), do: true
  defp gif?(_body), do: false

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
