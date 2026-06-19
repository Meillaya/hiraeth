defmodule Hiraeth.BrowserQaContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @public_quiet_index_routes [
    "/",
    "/browse",
    "/browse?page=2",
    "/browse?q=Immigrant",
    "/browse?q=%E6%9C%88",
    "/search",
    "/search?q=9781646054541",
    "/publishers",
    "/publishers/deep-vellum",
    "/publishers/new-directions",
    "/browse?publisher=new-directions",
    "/contributors",
    "/contributors?role=translator",
    "/contributors/david-bowles",
    "/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest",
    "/browse?q=%25&format=ebook&page=999",
    "/series",
    "/series/browser-qa-series",
    "/books/deep-vellum-immigrant",
    "/editions/deep-vellum-immigrant-paperback-9781646054541",
    "/editions/not-a-real-edition"
  ]

  @public_shell_markers [
    "#home-shell",
    "#browse-shell",
    "#search-shell",
    "#publishers-shell",
    "#publisher-detail-shell",
    "#contributors-shell",
    "#contributor-detail-shell",
    "#series-shell",
    "#series-detail-shell",
    "#book-detail-shell",
    "#edition-detail-shell"
  ]

  @viewport_contracts [
    "desktop:1440,1000",
    "tablet:768,1024",
    "mobile:390,844"
  ]

  setup_all do
    {:ok,
     script: File.read!(Path.join(@root, "scripts/browser_qa.sh")),
     docs: File.read!(Path.join(@root, "docs/browser-qa.md")),
     makefile: File.read!(Path.join(@root, "Makefile"))}
  end

  test "browser QA is wired to the documented executable entrypoints", %{
    script: script,
    makefile: makefile
  } do
    script_path = Path.join(@root, "scripts/browser_qa.sh")

    assert File.exists?(script_path)
    assert executable?(script_path)
    assert makefile =~ "scripts/browser_qa.sh"
    assert script =~ "chromium"
    assert script =~ "seed_browser_qa.exs"
    assert script =~ "keyboard_focus_check.mjs"
    refute script =~ "admin_browser_check.mjs"
    assert script =~ "image_decode_check.mjs"
    assert script =~ "public_resource_dependency_check.mjs"
    assert script =~ "responsive_overflow_check.mjs"
  end

  test "public Quiet Index route matrix includes stable browser-visible shells", %{
    script: script,
    docs: docs
  } do
    assert docs =~ "The strict browser contract covers"
    assert docs =~ "route-specific mobile/tablet overflow for public Quiet Index shells"

    assert_route_literals(script, @public_quiet_index_routes)
    assert_contains_all(script, @public_shell_markers)
    assert_contains_all(script, @viewport_contracts)

    assert script =~ "running public route responsive overflow audits"
    assert script =~ "responsive_overflow=pass"
  end

  test "browser QA requires durable render evidence for each captured page", %{
    script: script,
    docs: docs
  } do
    assert docs =~ "captures desktop/tablet/mobile screenshots plus DOM snapshots"
    assert docs =~ "artifacts/qa/browser/"

    assert script =~ "captured="
    assert script =~ "dom="
    assert script =~ "render="
    assert script =~ ".png"
    assert script =~ ".html"
    assert script =~ "-render.json"
    assert script =~ "\"passed\": true"
    assert script =~ "screenshots_count="
  end

  test "strict timing and network/resource dependency checks remain part of the contract", %{
    script: script,
    docs: docs
  } do
    assert docs =~ "STRICT_TIMING=1 make test-browser"

    assert script =~ "STRICT_TIMING"
    assert script =~ "curl_timing_route="
    assert script =~ "curl_timing_ttfb_ms="
    assert script =~ "curl_timing_total_ms="
    assert script =~ "ttfb_budget_ms=300"
    assert script =~ "total_budget_ms=800"

    assert script =~ "network-errors.json"
    assert script =~ "network_errors=pass"
    assert script =~ "remote_cover_dependencies=pass"
    assert script =~ "remote_image_dependencies=pass"
    assert script =~ "public_resource_dependencies=pass"
    assert script =~ "no_remote_images_css_fonts_scripts_styles=pass"
    assert script =~ "external_resource_references"
    assert script =~ "broken_local_resources"
  end

  test "cover cache and local image decode audits are required observable QA outcomes", %{
    script: script,
    docs: docs
  } do
    assert docs =~ "cached cover paths, image decode"
    assert docs =~ "no remote image dependency"

    assert script =~ "mix hiraeth.cache_covers"
    assert script =~ "cover_cache_failed="
    assert script =~ "cover_cache_warmup=fail"

    assert script =~
             "cover_cache_warmup=pass task=mix_hiraeth.cache_covers status=${cover_cache_status} cover_cache_failed=0"

    assert script =~ "cached_cover_paths=pass"
    assert script =~ "cover_image_attrs=pass"
    assert script =~ "new_directions_cover_fallback=pass"
    refute script =~ "cover_attribution_takedown=pass"

    assert script =~ "image-decode.json"
    assert script =~ "thumbnail-image-decode.json"
    assert script =~ "image_decode=pass"
    assert script =~ "thumbnail_image_decode=pass"
    assert script =~ "natural_dimensions_minimum=64x64"
  end

  test "cover cache warmup fails fast when the cache command reports failed covers" do
    qa_dir = make_tmp_dir!("cover-cache-fail")
    stub_dir = make_tmp_dir!("browser-qa-stubs")

    write_executable!(Path.join(stub_dir, "chromium"), """
    #!/usr/bin/env bash
    exit 0
    """)

    write_executable!(Path.join(stub_dir, "docker"), """
    #!/usr/bin/env bash
    exit 0
    """)

    write_executable!(Path.join(stub_dir, "lsof"), """
    #!/usr/bin/env bash
    exit 1
    """)

    write_executable!(Path.join(stub_dir, "mix"), """
    #!/usr/bin/env bash
    if [[ "$*" == "hiraeth.cache_covers" ]]; then
      echo "cover_cache_cached=0"
      echo "cover_cache_skipped=0"
      echo "cover_cache_failed=1"
      exit 0
    fi

    if [[ "$*" == "phx.server" ]]; then
      echo "unexpected phx.server after failed cover cache"
      exit 86
    fi

    exit 0
    """)

    {output, status} =
      System.cmd("bash", ["scripts/browser_qa.sh"],
        cd: @root,
        env: [
          {"PATH", stub_dir <> ":" <> System.get_env("PATH", "")},
          {"QA_DIR", qa_dir},
          {"PORT", "49114"}
        ],
        stderr_to_stdout: true
      )

    transcript = File.read!(Path.join(qa_dir, "test-browser.txt"))

    assert status == 1
    assert output =~ "cover_cache_failed=1"
    assert transcript =~ "cover_cache_failed=1"

    assert transcript =~
             "cover_cache_warmup=fail task=mix_hiraeth.cache_covers status=0 cover_cache_failed=1"

    refute transcript =~ "cover_cache_warmup=pass"
    refute transcript =~ "starting Phoenix server"
    refute transcript =~ "test_browser=pass"
  end

  defp assert_contains_all(text, required_values) do
    missing = Enum.reject(required_values, &String.contains?(text, &1))
    assert missing == []
  end

  defp assert_route_literals(script, routes) do
    missing = Enum.reject(routes, &String.contains?(script, ~s|"#{&1}"|))
    assert missing == []
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      {:error, _reason} -> false
    end
  end

  defp make_tmp_dir!(label) do
    path =
      Path.join(System.tmp_dir!(), [
        "hiraeth-browser-qa-contract-",
        label,
        "-",
        System.unique_integer([:positive]) |> Integer.to_string()
      ])

    File.mkdir_p!(path)
    path
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
