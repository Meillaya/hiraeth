defmodule Hiraeth.DocsQaPackTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "README briefly describes the project and documents local run/build commands" do
    readme = read!("README.md")

    assert readme =~ "# Hiraeth"
    assert readme =~ "Phoenix LiveView and Ash catalog"
    assert readme =~ "provenance-aware imports"
    assert readme =~ "## Run locally"
    assert readme =~ "docker compose up -d postgres"
    assert readme =~ "mix ash.migrate"
    assert readme =~ "mix phx.server"
    assert readme =~ "## Verify/build"
    assert readme =~ "mix compile --warnings-as-errors"
    assert readme =~ "make verify"
  end

  test "architecture docs explain Oban deferral and cover legal review boundary" do
    architecture = read!("docs/architecture.md")
    policy = read!("docs/provenance-cover-policy.md")

    assert architecture =~ "when imports exceed synchronous limits"
    assert architecture =~ "Oban"
    assert policy =~ "legal review required before production"
    assert policy =~ "link-only"
    assert policy =~ "takedown"
  end

  test "qa-pack target creates a tarball and manifest" do
    makefile = read!("Makefile")

    assert makefile =~ "qa-pack.tar.gz"
    assert makefile =~ "qa-pack-manifest.txt"
    assert makefile =~ "tar -czf"
  end

  defp read!(relative), do: File.read!(Path.join(@root, relative))
end
