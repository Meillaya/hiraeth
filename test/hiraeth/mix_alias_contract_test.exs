defmodule Hiraeth.MixAliasContractTest do
  use ExUnit.Case, async: true

  @required_aliases [:precommit, :"precommit.fast", :"test.fast", :"test.full", :ci, :quality]
  @format_checked_gates [:"precommit.fast", :ci]
  # Static gates must run in fresh Mix VMs (`cmd mix ...`): `mix credo`
  # starts the credo application in-chain, which makes the later `mix test`
  # app startup fail with "application credo ... already started"; Mix also
  # purges archive tasks (hex.audit) once `compile` runs in the same VM.
  @ci_audit_gate "cmd mix hex.audit"
  @ci_static_gates [
    "cmd mix credo --strict",
    "cmd mix sobelow --config .sobelow-conf --exit Low",
    @ci_audit_gate
  ]

  defp aliases do
    Mix.Project.config()
    |> Keyword.fetch!(:aliases)
  end

  defp alias_commands!(name) do
    aliases()
    |> Keyword.fetch!(name)
  end

  defp preferred_envs do
    Hiraeth.MixProject.cli()
    |> Keyword.fetch!(:preferred_envs)
  end

  test "fast, full, and CI gate aliases exist" do
    for alias <- @required_aliases do
      assert Keyword.has_key?(aliases(), alias), "expected mix alias #{alias} to exist"
    end
  end

  test "precommit delegates directly to the fast precommit gate" do
    assert alias_commands!(:precommit) == ["precommit.fast"]
  end

  test "fast and full test gates are separate aliases" do
    fast_commands = alias_commands!(:"test.fast")
    full_commands = alias_commands!(:"test.full")

    assert fast_commands != full_commands
    assert Enum.any?(full_commands, &String.starts_with?(&1, "test"))
    refute Enum.any?(full_commands, &String.contains?(&1, "--exclude"))
  end

  test "fast test gate excludes explicit cost tags" do
    fast_commands = alias_commands!(:"test.fast")
    fast_command = Enum.join(fast_commands, " && ")

    for tag <- ~w(slow full_catalog integration performance browser public_catalog_full) do
      assert fast_command =~ "--exclude #{tag}",
             "expected test.fast to exclude #{tag}"
    end
  end

  test "precommit and CI gates check formatting without mutating files" do
    for gate <- @format_checked_gates do
      gate_commands = alias_commands!(gate)

      assert "format --check-formatted" in gate_commands,
             "expected #{gate} to run non-mutating format check"

      refute "format" in gate_commands,
             "expected #{gate} not to run mutating bare format"
    end
  end

  test "new gate aliases default to the test environment" do
    for alias <- @required_aliases do
      assert Keyword.get(preferred_envs(), alias) == :test,
             "expected preferred_envs[#{alias}] to be :test"
    end
  end

  test "CI gate runs the static analysis gates before assets and tests" do
    ci_commands = alias_commands!(:ci)

    for gate <- @ci_static_gates do
      assert gate in ci_commands, "expected ci chain to include #{gate}"
    end

    assets_index = Enum.find_index(ci_commands, &(&1 == "assets.setup"))
    test_index = Enum.find_index(ci_commands, &(&1 == "test.full"))

    assert assets_index, "expected ci chain to include assets.setup"
    assert test_index, "expected ci chain to include test.full"

    for gate <- @ci_static_gates do
      gate_index = Enum.find_index(ci_commands, &(&1 == gate))
      assert gate_index < assets_index, "expected #{gate} to run before assets.setup"
      assert gate_index < test_index, "expected #{gate} to run before test.full"
    end
  end

  test "quality alias exists and runs the slow gates" do
    assert Keyword.has_key?(aliases(), :quality), "expected mix alias quality to exist"

    quality_commands = alias_commands!(:quality)
    assert "dialyzer" in quality_commands
    assert "coveralls" in quality_commands
  end

  test "fast precommit lane never gains slow gates" do
    fast_commands = alias_commands!(:"precommit.fast")

    refute "dialyzer" in fast_commands,
           "expected precommit.fast to stay free of dialyzer"

    refute "coveralls" in fast_commands,
           "expected precommit.fast to stay free of coveralls"
  end
end
