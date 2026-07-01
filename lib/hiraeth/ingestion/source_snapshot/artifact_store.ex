defmodule Hiraeth.Ingestion.SourceSnapshot.ArtifactStore do
  @moduledoc """
  Private artifact retention for ingestion source snapshots.

  Retained bytes live under a private retention root. Paths are intentionally
  relative storage references so database rows cannot point at public/static
  namespaces or escape the configured root.
  """

  @checksum_prefix "sha256:"
  @default_extension ".bin"
  @public_path_prefixes [
    ["priv", "static"],
    ["public"],
    ["static"],
    ["uploads"]
  ]

  def retain!(provider, source_url, payload, opts \\ [])
      when is_binary(provider) and is_binary(source_url) and is_binary(payload) do
    checksum = checksum(payload)
    byte_size = byte_size(payload)
    artifact_path = artifact_path(provider, source_url, checksum, Keyword.get(opts, :extension))
    root = retention_root(opts)
    full_path = private_path!(artifact_path, root)

    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, payload)

    %{
      artifact_path: artifact_path,
      checksum: checksum,
      byte_size: byte_size
    }
  end

  def checksum(payload) when is_binary(payload) do
    @checksum_prefix <>
      (payload |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end

  def load!(snapshot_or_path, opts \\ []) do
    snapshot_or_path
    |> path_from()
    |> private_path!(retention_root(opts))
    |> File.read!()
  end

  def private_path!(artifact_path, root \\ retention_root())
      when is_binary(artifact_path) do
    case validate_relative_path(artifact_path, root) do
      {:ok, full_path} -> full_path
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def validate_relative_path(artifact_path, root \\ retention_root())
      when is_binary(artifact_path) and is_binary(root) do
    root = Path.expand(root)
    parts = Path.split(artifact_path)

    cond do
      Path.type(artifact_path) != :relative ->
        {:error, "artifact_path must be a relative path under the private retention root"}

      Enum.any?(parts, &(&1 in ["", ".", ".."])) ->
        {:error, "artifact_path must not traverse outside the private retention root"}

      public_path_namespace?(parts) ->
        {:error,
         "artifact_path must not target public/static paths; use the private retention root"}

      true ->
        full_path = Path.expand(artifact_path, root)

        if full_path == root or String.starts_with?(full_path, root <> "/") do
          {:ok, full_path}
        else
          {:error, "artifact_path must remain under the private retention root"}
        end
    end
  end

  def retention_root(opts \\ []) do
    Keyword.get_lazy(opts, :retention_root, fn ->
      Application.get_env(:hiraeth, :source_snapshot_retention_root) ||
        Path.expand("priv/source_snapshots")
    end)
  end

  defp path_from(path) when is_binary(path), do: path
  defp path_from(%{artifact_path: path}) when is_binary(path), do: path
  defp path_from(%{storage_ref: path}) when is_binary(path), do: path

  defp path_from(value) do
    raise ArgumentError,
          "cannot load source snapshot payload without an artifact_path: #{inspect(value)}"
  end

  defp artifact_path(provider, source_url, checksum, extension) do
    safe_provider = slug(provider)

    safe_source =
      source_url
      |> URI.parse()
      |> Map.get(:host)
      |> case do
        nil -> "source"
        host -> slug(host)
      end

    checksum_slug = String.replace_prefix(checksum, @checksum_prefix, "")

    "source-snapshots/#{safe_provider}/#{safe_source}/#{checksum_slug}#{safe_extension(extension)}"
  end

  defp safe_extension(nil), do: @default_extension

  defp safe_extension(extension) when is_binary(extension) do
    extension = String.trim(extension)

    if String.starts_with?(extension, ".") and not String.contains?(extension, ["/", "\\"]) do
      extension
    else
      @default_extension
    end
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "source"
      slug -> slug
    end
  end

  defp public_path_namespace?(parts) do
    Enum.any?(@public_path_prefixes, fn prefix ->
      parts |> Enum.take(length(prefix)) |> Kernel.==(prefix)
    end)
  end
end
