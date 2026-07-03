defmodule Hiraeth.MixAliasContractTest do
  use ExUnit.Case, async: true

  @required_aliases [:precommit, :"precommit.fast", :"test.fast", :"test.full", :ci]
  @format_checked_gates [:"precommit.fast", :ci]

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
end
