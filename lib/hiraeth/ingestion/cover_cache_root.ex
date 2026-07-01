defmodule Hiraeth.Ingestion.CoverCacheRoot do
  @moduledoc false

  @canonical_root "priv/static/covers/cache"

  def canonical_root, do: Path.expand(@canonical_root)

  def normalize_candidate_root(cache_root, canonical_root \\ canonical_root()) do
    canonical_root = Path.expand(canonical_root)
    requested_root = Path.expand(cache_root)

    cond do
      not under_path?(requested_root, canonical_root) ->
        {:error, "cover candidate cache_root must stay under canonical cover cache root"}

      symlink?(canonical_root) or symlink_component?(requested_root, canonical_root) ->
        {:error, "cover candidate cache_root must not traverse symlink components"}

      true ->
        {:ok, requested_root}
    end
  end

  defp under_path?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp symlink_component?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
    |> Enum.reduce_while(root, fn segment, current ->
      current = Path.join(current, segment)

      cond do
        symlink?(current) -> {:halt, true}
        exists?(current) -> {:cont, current}
        true -> {:halt, false}
      end
    end)
    |> case do
      true -> true
      _path -> false
    end
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      {:error, reason} when reason != :enoent -> true
      _result -> false
    end
  end

  defp exists?(path) do
    case File.lstat(path) do
      {:ok, _stat} -> true
      {:error, _reason} -> false
    end
  end
end
