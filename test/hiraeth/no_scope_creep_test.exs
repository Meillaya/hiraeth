defmodule Hiraeth.NoScopeCreepTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "dependencies and assets do not introduce React, Vite, or a SPA app" do
    project_text = read!("mix.exs") <> "\n" <> read!("mix.lock")

    refute project_text =~ ~r/{:(react|vite|vitest|react_router)\b/i
    refute project_text =~ ~r/"(react|vite|vitest|@testing-library\/react)"/i

    refute File.exists?(Path.join(@root, "package.json"))
    refute File.exists?(Path.join(@root, "vite.config.js"))
    refute File.exists?(Path.join(@root, "vite.config.ts"))
    refute File.dir?(Path.join(@root, "assets/app"))
  end

  test "router exposes LiveView browser routes but no broad JSON API surface" do
    paths = HiraethWeb.Router.__routes__() |> Enum.map(& &1.path)

    assert "/browse" in paths
    assert "/search" in paths
    assert "/publishers" in paths
    assert "/series" in paths

    refute Enum.any?(paths, &String.starts_with?(&1, "/admin"))

    refute Enum.any?(paths, &String.starts_with?(&1, "/api"))
    refute Enum.any?(paths, &String.contains?(&1, "/reviews"))
    refute Enum.any?(paths, &String.contains?(&1, "/checkout"))
    refute Enum.any?(paths, &String.contains?(&1, "/shelves"))
  end

  test "bootstrap scope has no implementation modules for scraping/social/ecommerce features" do
    lib_paths = Path.wildcard(Path.join(@root, "lib/**/*.ex"))
    lowered_paths = Enum.map(lib_paths, &String.downcase(Path.relative_to(&1, @root)))

    refute Enum.any?(lowered_paths, &String.contains?(&1, "scraper"))
    refute Enum.any?(lowered_paths, &String.contains?(&1, "reviews"))
    refute Enum.any?(lowered_paths, &String.contains?(&1, "ratings"))
    refute Enum.any?(lowered_paths, &String.contains?(&1, "shelves"))
    refute Enum.any?(lowered_paths, &String.contains?(&1, "checkout"))
  end

  test "host psql is not required by local verification wrappers" do
    makefile = read!("Makefile")

    refute makefile =~ ~r/\bpsql\b(?!.*docker compose exec)/i
  end

  defp read!(relative), do: File.read!(Path.join(@root, relative))
end
