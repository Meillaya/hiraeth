defmodule Hiraeth.DocsQaPackTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "README briefly describes the project and documents local run/build commands" do
    readme = read!("README.md")

    assert readme =~ "# Hiraeth"
    assert readme =~ "Phoenix LiveView and Ash catalog"
    assert readme =~ "provenance-aware imports"
    assert readme =~ "## Run locally"
    assert readme =~ "standalone PostgreSQL 16"
    assert readme =~ "dormant groundwork"
    assert readme =~ "devenv shell"
    assert readme =~ "devenv process runner"
    assert readme =~ "MIX_ENV=test mix ash.migrate"
    assert readme =~ "mix phx.server"
    assert readme =~ "Docker remains"
    assert readme =~ "production runtime"
    refute readme =~ ~r/^\s*docker\s+\S+\s+up\s+-d\s+postgres$/m
    assert readme =~ "## Verify/build"
    assert readme =~ "Fast local preflight"
    assert readme =~ "mix gate"
    assert readme =~ "mix test.fast"
    assert readme =~ "Full local, CI, and release assurance"
    assert readme =~ "mix ci"
    assert readme =~ "make verify"
    assert readme =~ "/contributors?role=translator"
    assert readme =~ "mix hiraeth.cache_covers"
    assert readme =~ "mix hiraeth.audit_provenance"
    assert readme =~ "New Directions"
  end

  test "sidecar README keeps the devenv-local boundary without claiming production-only Nix" do
    sidecar = read!("sidecar/README.md")

    assert sidecar =~ "Docker remains"
    assert sidecar =~ "production runtime"
    assert sidecar =~ "Run locally from a devenv shell"
    assert sidecar =~ "127.0.0.1:8000"
    refute sidecar =~ ~r/cleanly migrated\s+(?:in|for|across)?\s*(?:all|every)?\s*capacity/i
    refute_docker_free_production_claim!(sidecar)
  end

  test "qa-pack target creates a tarball and manifest" do
    makefile = read!("Makefile")

    assert makefile =~ "qa-pack.tar.gz"
    assert makefile =~ "qa-pack-manifest.txt"
    assert makefile =~ "tar -czf"
  end

  defp read!(relative), do: File.read!(Path.join(@root, relative))

  defp refute_docker_free_production_claim!(document) do
    refute document =~ ~r/production\s+is\s+Docker-free/i
    refute document =~ ~r/Hiraeth\s+production\s+is\s+Docker-free/i
    refute document =~ ~r/Docker-free\s+production/i

    refute document =~
             ~r/(?:is|are|was|were|becomes|became|now)\s+(?:cleanly\s+)?migrated\s+(?:in|for|across)?\s*(?:all|every)\s+(?:capacity|runtime|environment)/i

    refute document =~
             ~r/(?:all|every)\s+(?:capacity|runtime|environment)\s+(?:is|are|was|were|becomes|became)\s+(?:cleanly\s+)?migrated/i
  end
end
