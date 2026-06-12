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

    assert script_text =~ "chromium"
    assert script_text =~ "--screenshot"
    assert script_text =~ "network-errors.json"
    assert script_text =~ "keyboard-focus.json"
    assert script_text =~ "admin-authenticated.json"
    assert script_text =~ "seed_browser_qa.exs"
    assert script_text =~ "cover_attribution_takedown=pass"
    assert script_text =~ "external_resource_references"
    assert script_text =~ "keyboard_navigation=pass"
    assert File.exists?(focus_script)
    assert File.exists?(admin_script)

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
    assert makefile =~ "scripts/browser_qa.sh"
  end
end
