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

    documented_narrow_api_paths = []

    broad_api_paths =
      paths
      |> Enum.filter(&String.starts_with?(&1, "/api"))
      |> Kernel.--(documented_narrow_api_paths)

    assert broad_api_paths == []
    refute Enum.any?(paths, &String.contains?(&1, "/register"))
    refute Enum.any?(paths, &String.contains?(&1, "/profile"))
    refute Enum.any?(paths, &String.contains?(&1, "/users"))
    refute Enum.any?(paths, &String.contains?(&1, "/oauth"))
    refute Enum.any?(paths, &String.contains?(&1, "/social"))
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

  test "sidecar crawler scope remains Scrapling-only at top-level dependencies and app imports" do
    dependencies =
      "sidecar/pyproject.toml"
      |> read!()
      |> sidecar_project_dependencies()

    assert "scrapling" in dependencies

    forbidden_dependency_names =
      ~w(beautifulsoup4 bs4 mechanicalsoup parsel playwright pyppeteer requests-html scrapy selenium)

    for package <- forbidden_dependency_names do
      refute package in dependencies
    end

    import_roots = sidecar_app_import_roots()

    forbidden_import_roots =
      ~w(bs4 mechanicalsoup parsel playwright pyppeteer requests_html scrapy selenium)

    for import_root <- forbidden_import_roots do
      refute import_root in import_roots
    end
  end

  test "default compose keeps Scrapling sidecar private to the service network" do
    compose_text = read!("compose.yaml")
    sidecar_block = compose_service_block(compose_text, "scrapling-sidecar")

    refute sidecar_block =~ ~r/^\s{4}ports:\s*$/m
    refute sidecar_block =~ ~r/^\s{6}-\s*"?(?:127\.0\.0\.1:)?8000:8000"?\s*$/m
    assert sidecar_block =~ ~r/^\s{4}expose:\s*\n\s{6}-\s*"?8000"?\s*$/m
    assert compose_text =~ "SCRAPLING_SIDECAR_URL: http://scrapling-sidecar:8000"
  end

  test "local sidecar guidance is truthful about current devenv loopback transport" do
    devenv_process_manages_sidecar? =
      "devenv.nix"
      |> read!()
      |> devenv_sidecar_process?()

    docs = %{
      "docs/contracts.md" => read!("docs/contracts.md"),
      "sidecar/README.md" => read!("sidecar/README.md")
    }

    for {path, text} <- docs do
      assert text =~ ~r/127\.0\.0\.1:8000/,
             "#{path} must document loopback-only local sidecar transport"

      assert text =~ ~r/devenv shell/i,
             "#{path} must keep direct-debugging sidecar commands inside a devenv shell"

      if devenv_process_manages_sidecar? do
        assert text =~ ~r/devenv-managed|managed `scrapling-sidecar`|devenv process runner/i,
               "#{path} must acknowledge the declared local devenv sidecar process"
      else
        assert text =~
                 ~r/(manual|manually).*(sidecar|uvicorn)|(?:sidecar|uvicorn).*(manual|manually)/is,
               "#{path} must be explicit that local sidecar startup is manual when no sidecar process is declared"

        refute text =~ ~r/devenv up|devenv-managed|devenv process runner/i,
               "#{path} must not claim process-managed sidecar startup before it is declared"
      end

      assert text =~ ~r/SCRAPLING_SIDECAR_URL=http:\/\/scrapling-sidecar:8000/,
             "#{path} must preserve the internal Compose sidecar URL as a separate runtime concern"

      assert text =~ ~r/(Docker|Compose).*(fallback|production|runtime|service network)/is,
             "#{path} must label Docker/Compose sidecar usage as fallback or runtime-only guidance"

      assert text =~
               ~r/separate from production|production\/internal Compose|Compose runtime|service network/is,
             "#{path} must explicitly separate local loopback transport from production/internal Compose runtime"

      refute text =~ ~r/(all|every)\s+(environment|capacity|runtime)/is,
             "#{path} must not imply loopback sidecar transport applies to all deployment modes or production"

      refute text =~ ~r/production\s+Nix\/devenv-only|production\s+is\s+Nix-only/is,
             "#{path} must not claim Phoenix/sidecar production is Nix/devenv-only"
    end
  end

  test "operator sidecar-down messages prefer current devenv loopback and Docker only as fallback" do
    devenv_process_manages_sidecar? =
      "devenv.nix"
      |> read!()
      |> devenv_sidecar_process?()

    operator_paths = [
      "lib/hiraeth/ingestion/operator_cli.ex",
      "lib/hiraeth/ingestion/operator_dry_run.ex",
      "lib/mix/tasks/hiraeth.scrape.ex"
    ]

    for path <- operator_paths do
      text = read!(path)

      assert text =~ ~r/devenv shell/i,
             "#{path} must keep direct-debugging sidecar commands inside a devenv shell"

      assert text =~ ~r/127\.0\.0\.1:8000/,
             "#{path} must keep local sidecar transport loopback-only"

      if devenv_process_manages_sidecar? do
        assert text =~ ~r/devenv-managed scrapling-sidecar process|devenv\.nix/i,
               "#{path} must guide local operators to the declared devenv sidecar process"
      else
        assert text =~
                 ~r/(manual|manually).*(sidecar|uvicorn)|(?:sidecar|uvicorn).*(manual|manually)/is,
               "#{path} must not imply process-managed sidecar startup exists before it is declared"

        refute text =~ ~r/devenv up|devenv-managed/i,
               "#{path} must not claim `devenv up` starts the sidecar before the sidecar process is declared"
      end

      assert text =~
               ~r/(docker compose up -d scrapling-sidecar|Docker Compose).*(fallback|runtime|Compose-only)/is,
             "#{path} may mention Docker only as fallback or Compose runtime guidance"

      refute text =~ ~r/(all|every)\s+(environment|capacity|runtime)/is,
             "#{path} must not imply loopback sidecar transport applies to all deployment modes or production"

      refute text =~ ~r/production\s+Nix\/devenv-only|production\s+is\s+Nix-only/is,
             "#{path} must not claim Phoenix/sidecar production is Nix/devenv-only"

      refute text =~ "Start it with: docker compose up -d scrapling-sidecar",
             "#{path} must not keep stale Docker-only local sidecar startup guidance"
    end
  end

  defp read!(relative), do: File.read!(Path.join(@root, relative))

  defp devenv_sidecar_process?(devenv_nix) do
    devenv_nix =~ ~r/processes\.[\w.-]*(?:sidecar|scrapling)[\w.-]*\s*=/ or
      devenv_nix =~ ~r/processes\."[^"]*(?:sidecar|scrapling)[^"]*"\s*=/ or
      devenv_nix =~ ~r/(?:sidecar|scrapling)[\w.-]*\s*=\s*\{\s*exec\s*=/s
  end

  defp compose_service_block(compose_text, service_name) do
    marker = "  #{service_name}:"
    lines = String.split(compose_text, "\n", trim: false)

    case Enum.find_index(lines, &(&1 == marker)) do
      nil ->
        flunk("compose.yaml is missing #{service_name} service")

      start_index ->
        lines
        |> Enum.drop(start_index)
        |> Enum.take_while(&(&1 == marker or &1 == "" or String.starts_with?(&1, "    ")))
        |> Enum.join("\n")
    end
  end

  defp sidecar_project_dependencies(pyproject_text) do
    case Regex.run(~r/dependencies = \[\n(.*?)\n\]/s, pyproject_text, capture: :all_but_first) do
      [dependencies_block] ->
        dependencies_block
        |> dependency_specs()
        |> Enum.map(&package_name/1)

      nil ->
        flunk("sidecar/pyproject.toml is missing a top-level dependencies block")
    end
  end

  defp dependency_specs(dependencies_block) do
    ~r/"([^"]+)"/
    |> Regex.scan(dependencies_block, capture: :all_but_first)
    |> List.flatten()
  end

  defp package_name(spec) do
    spec
    |> String.split(~r/[<>=~!;\[]/, parts: 2)
    |> List.first()
    |> String.downcase()
  end

  defp sidecar_app_import_roots do
    @root
    |> Path.join("sidecar/app/**/*.py")
    |> Path.wildcard()
    |> Enum.flat_map(&python_import_roots/1)
    |> Enum.uniq()
  end

  defp python_import_roots(path) do
    path
    |> File.stream!()
    |> Stream.map(
      &Regex.run(~r/^\s*(?:from|import)\s+([A-Za-z_][\w.]*)/, &1, capture: :all_but_first)
    )
    |> Stream.reject(&is_nil/1)
    |> Enum.map(fn [module] ->
      module
      |> String.split(".", parts: 2)
      |> List.first()
      |> String.downcase()
    end)
  end
end
