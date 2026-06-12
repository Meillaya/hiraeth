defmodule Mix.Tasks.Hiraeth.CacheCovers do
  @moduledoc "Caches eligible public cover assets under priv/static/covers/cache."
  use Mix.Task

  @shortdoc "Caches eligible public cover assets"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [force: :boolean, cache_root: :string],
        aliases: [f: :force]
      )

    summary =
      Hiraeth.Covers.cache_public_covers!(
        force?: Keyword.get(opts, :force, false),
        cache_root: Keyword.get(opts, :cache_root, "priv/static/covers/cache")
      )

    Mix.shell().info("cover_cache_cached=#{summary.cached}")
    Mix.shell().info("cover_cache_skipped=#{summary.skipped}")
  end
end
