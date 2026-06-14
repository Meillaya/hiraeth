defmodule Hiraeth.BrowserQaContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "browser QA has a real Chromium script and Makefile target" do
    script = Path.join(@root, "scripts/browser_qa.sh")
    makefile = File.read!(Path.join(@root, "Makefile"))

    assert File.exists?(script)
    script_text = File.read!(script)
    focus_script = Path.join(@root, "scripts/keyboard_focus_check.mjs")
    admin_script = Path.join(@root, "scripts/admin_browser_check.mjs")
    image_decode_script = Path.join(@root, "scripts/image_decode_check.mjs")

    assert script_text =~ "chromium"
    assert script_text =~ "--screenshot"
    assert script_text =~ "network-errors.json"
    assert script_text =~ "keyboard-focus.json"
    assert script_text =~ "admin-authenticated.json"
    assert script_text =~ "seed_browser_qa.exs"
    assert script_text =~ "cover_attribution_takedown=pass"
    assert script_text =~ "external_resource_references"
    assert script_text =~ "keyboard_navigation=pass"
    assert script_text =~ "hiraeth.cache_covers"
    assert script_text =~ "duplicate_book_cards=pass"
    assert script_text =~ "cached_cover_paths=pass"
    assert script_text =~ "remote_cover_dependencies=pass"
    assert script_text =~ "prose_cta_presence=pass"
    assert script_text =~ "image_decode=pass"
    assert script_text =~ "natural_width_gt_zero=pass"
    assert script_text =~ "image_decode_check.mjs"
    assert script_text =~ "book-description"
    assert script_text =~ "book-storefront-cta"
    assert script_text =~ "Source provenance"
    assert script_text =~ "curl_timing_ttfb_ms"
    assert script_text =~ "curl_timing_total_ms"
    assert script_text =~ "ttfb_budget_ms=300"
    assert script_text =~ "total_budget_ms=800"
    assert script_text =~ "STRICT_TIMING"
    assert script_text =~ "timing_routes=("
    assert script_text =~ ~s|"/"|
    assert script_text =~ ~s|"/browse?page=2"|
    assert script_text =~ ~s|"/search"|
    assert script_text =~ ~s|"/search?q=9781646054541"|
    assert script_text =~ ~s|"/publishers"|
    assert script_text =~ ~s|"/publishers/deep-vellum"|
    assert script_text =~ ~s|"/series"|
    assert script_text =~ "cover_image_attrs=pass"
    assert script_text =~ "new_directions_cover_fallback=pass"
    assert script_text =~ "filter_sort_url=pass"
    assert script_text =~ "enriched_metadata_presence=pass"
    assert script_text =~ "provenance_thread=pass"
    assert script_text =~ "malformed_query=pass"
    assert script_text =~ "contributors_role_filter=pass"
    assert script_text =~ ~s|"/contributors"|
    assert script_text =~ ~s|"/contributors?role=translator"|
    assert script_text =~ ~s|"/browse?publisher=new-directions"|

    assert script_text =~
             ~s|"/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest"|

    assert script_text =~ ~s|"/browse?q=%25&format=ebook&page=999"|
    assert File.exists?(focus_script)
    assert File.exists?(admin_script)
    assert File.exists?(image_decode_script)

    focus_text = File.read!(focus_script)
    assert focus_text =~ "Input.dispatchKeyEvent"
    assert focus_text =~ "document.activeElement"
    assert focus_text =~ "focusOrder"
    admin_text = File.read!(admin_script)
    assert admin_text =~ "requestSubmit"
    assert admin_text =~ "Catalog Administration"
    assert admin_text =~ "desktop-admin-import-new"
    assert admin_text =~ "desktop-admin-review-detail"
    assert admin_text =~ "desktop-cover-fallback-after-takedown"
    image_decode_text = File.read!(image_decode_script)
    assert image_decode_text =~ "naturalWidth"
    assert image_decode_text =~ "Runtime.evaluate"
    assert makefile =~ "scripts/browser_qa.sh"
  end
end
