defmodule Hiraeth.VerifyGateTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "make verify writes the required summary gates after all local checks" do
    makefile = read!("Makefile")
    script = Path.join(@root, "scripts/verify_summary.sh")

    assert makefile =~ "verify-summary"
    assert makefile =~ "$(QA_DIR)/verify/summary.json"
    assert File.exists?(script)

    # The verify chain is the non-redundant lane: provenance audit, browser
    # QA, summary gate, and QA pack. Per-suite Makefile wrappers (test-elixir,
    # test-ui, test-ingest, test-normalize, test-covers) and the bootstrap
    # file check were collapsed into `mix gate`/`mix ci` and removed.
    assert makefile =~ "verify: audit-provenance test-browser verify-summary qa-pack"

    script_text = File.read!(script)

    for gate <- [
          "no_react",
          "no_broad_json_api",
          "oban_allowed",
          "ash_domains",
          "liveview_routes",
          "provenance"
        ] do
      assert script_text =~ gate
    end
  end

  defp read!(relative), do: File.read!(Path.join(@root, relative))
end
