defmodule Hiraeth.DocsQaPackTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "README is an extremely brief project description" do
    readme = read!("README.md")

    assert readme =~ "# Hiraeth"
    assert readme =~ "Phoenix LiveView and Ash catalog"
    assert readme =~ "provenance-aware imports"
    assert readme =~ "cover attribution"
    assert readme =~ "admin review tools"
    refute readme =~ "## Setup"
    assert String.split(readme, "\n", trim: true) |> length() <= 3
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
