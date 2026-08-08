defmodule Hiraeth.MixAliasContractTest do
  use ExUnit.Case, async: true

  @required_aliases [
    :"test.fast",
    :"test.full",
    :ci,
    :gate
  ]
  @format_checked_gates [:gate, :ci]
  # The fast blocking gate deliberately omits sobelow/hex.audit: they need
  # network and stay in the CI `static` job and deep `ci` lane.
  @gate_commands [
    "compile --warnings-as-errors",
    "deps.unlock --unused",
    "format --check-formatted",
    "cmd mix credo --strict",
    "test.fast"
  ]
  @gate_forbidden ~w(dialyzer coveralls sobelow hex.audit)
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

  test "fast test gate tags match priv/test_lanes.exs slow_tags" do
    # priv/test_lanes.exs is the single source of truth; mix.exs assembles its
    # contract here will only pass if the mix.exs alias generation follows.
    lanes = Code.eval_file(test_lanes_path()) |> elem(0)
    expected = lanes.slow_tags |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    fast_command = alias_commands!(:"test.fast") |> Enum.join(" ")
    actual = extract_excluded_tags(fast_command) |> Enum.sort()

    assert actual == expected,
           "mix.exs test.fast is out of sync with priv/test_lanes.exs.\n" <>
             "expected: #{inspect(expected)}\nactual:   #{inspect(actual)}"
  end

  defp test_lanes_path do
    Path.expand("../../priv/test_lanes.exs", __DIR__)
  end

  defp extract_excluded_tags(command) do
    command
    |> String.split(" ")
    |> Enum.drop_while(&(&1 != "--exclude" and &1 != "--include"))
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.flat_map(fn
      [flag, tag] when flag in ["--exclude", "--include"] -> [tag]
      _ -> []
    end)
  end

  test "gate and CI gates check formatting without mutating files" do
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

  test "gate alias runs the fast blocking checks" do
    gate_commands = alias_commands!(:gate)

    for command <- @gate_commands do
      assert command in gate_commands, "expected gate chain to include #{command}"
    end
  end

  test "gate alias stays free of network-dependent and slow gates" do
    gate_commands = alias_commands!(:gate)

    for forbidden <- @gate_forbidden do
      refute Enum.any?(gate_commands, &String.contains?(&1, forbidden)),
             "expected gate to stay free of #{forbidden}"
    end
  end
end
