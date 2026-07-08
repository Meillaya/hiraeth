defmodule Hiraeth.DocsQaPackTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "README briefly describes the project and documents local run/build commands" do
    readme = read!("README.md")

    assert readme =~ "# Hiraeth"
    assert readme =~ "Phoenix LiveView and Ash catalog"
    assert readme =~ "provenance-aware imports"
    assert readme =~ "## Run locally"
    assert readme =~ "devenv is the preferred local/dev/test path"
    assert readme =~ "devenv shell"
    assert readme =~ "devenv process runner"
    assert readme =~ "MIX_ENV=test mix ash.migrate"
    assert readme =~ "mix phx.server"
    assert readme =~ "Docker remains"
    assert readme =~ "production runtime"
    refute readme =~ ~r/^\s*docker compose up -d postgres$/m
    assert readme =~ "## Verify/build"
    assert readme =~ "Fast local preflight"
    assert readme =~ "mix precommit"
    assert readme =~ "mix test.fast"
    assert readme =~ "Full local, CI, and release assurance"
    assert readme =~ "mix ci"
    assert readme =~ "make verify"
    assert readme =~ "/contributors?role=translator"
    assert readme =~ "mix hiraeth.cache_covers"
    assert readme =~ "mix hiraeth.audit_provenance"
    assert readme =~ "New Directions"
  end

  test "docs describe devenv-local boundary without claiming production-only Nix" do
    contracts = read!("docs/contracts.md")
    operations = read!("docs/production-operations.md")
    readiness = read!("docs/production-readiness.md")
    sidecar = read!("sidecar/README.md")

    for document <- [contracts, operations, readiness, sidecar] do
      assert document =~ "Docker remains"
      assert document =~ "production runtime"
      refute document =~ ~r/cleanly migrated\s+(?:in|for|across)?\s*(?:all|every)?\s*capacity/i
      refute_docker_free_production_claim!(document)
    end

    assert contracts =~ "Local devenv uses loopback-only sidecar transport"
    assert sidecar =~ "Run locally from a devenv shell"
    assert operations =~ "devenv is the preferred local/dev/test path"
    assert readiness =~ "bounded partial migration"
  end

  test "production runtime boundary is explicit and rejects Docker-free overclaims" do
    operations = read!("docs/production-operations.md")
    readiness = read!("docs/production-readiness.md")
    assert operations =~ "## Production Runtime Boundary"
    assert operations =~ "local/dev/CI-build"

    assert operations =~
             "production orchestration remains Docker/Compose or future-runtime scoped"

    assert readiness =~ "Production runtime decisions remain unresolved"

    for decision <- [
          "orchestration target",
          "sidecar private network",
          "backup/restore tooling",
          "memory limits",
          "logs/observability",
          "rollout/rollback"
        ] do
      assert operations =~ decision
      assert readiness =~ decision
    end

    refute_docker_free_production_claim!(operations)
    refute_docker_free_production_claim!(readiness)
  end

  test "architecture docs explain Oban deferral and cover legal review boundary" do
    architecture = read!("docs/architecture.md")
    policy = read!("docs/provenance-cover-policy.md")

    assert architecture =~ "when imports exceed synchronous limits"
    assert architecture =~ "Oban"
    assert policy =~ "legal review required before production"
    assert policy =~ "link-only"
    assert policy =~ "takedown"
    assert policy =~ "field-level provenance"
    assert policy =~ "New Directions"
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
