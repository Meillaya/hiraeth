defmodule Hiraeth.Ingestion.CoverCacheRootTest do
  use ExUnit.Case, async: true

  alias Hiraeth.Ingestion.CoverCacheRoot

  test "rejects a symlinked canonical candidate cache root before writes" do
    temp_parent =
      Path.join(System.tmp_dir!(), "hiraeth-cover-root-#{System.unique_integer([:positive])}")

    real_root = Path.join(temp_parent, "real-cache")
    symlink_root = Path.join(temp_parent, "cache-link")

    File.mkdir_p!(real_root)
    File.ln_s!(real_root, symlink_root)
    on_exit(fn -> File.rm_rf!(temp_parent) end)

    assert {:error, reason} = CoverCacheRoot.normalize_candidate_root(symlink_root, symlink_root)
    assert reason =~ "symlink"
  end
end
