defmodule Mix.Tasks.Hiraeth.CacheCovers do
  @moduledoc "Caches eligible public cover assets under priv/static/covers/cache."
  use Mix.Task

  @shortdoc "Caches eligible public cover assets"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          cache_root: :string,
          strict: :boolean,
          timeout: :integer,
          concurrency: :integer
        ],
        aliases: [f: :force]
      )

    summary =
      Hiraeth.Covers.cache_public_covers!(
        force?: Keyword.get(opts, :force, false),
        cache_root: Keyword.get(opts, :cache_root, "priv/static/covers/cache"),
        strict?: Keyword.get(opts, :strict, false),
        timeout: Keyword.get(opts, :timeout, 15_000),
        max_concurrency: Keyword.get(opts, :concurrency, 4)
      )

    Mix.shell().info("cover_cache_cached=#{summary.cached}")
    Mix.shell().info("cover_cache_skipped=#{summary.skipped}")
    Mix.shell().info("cover_cache_failed=#{summary.failed}")
  end
end
