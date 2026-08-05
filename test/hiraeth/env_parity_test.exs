defmodule Hiraeth.EnvParityTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @tag :ci_devenv_contract
  test ".env.example declares every variable config/runtime.exs requires" do
    env_example = File.read!(Path.join(@repo_root, ".env.example"))
    runtime_exs = File.read!(Path.join(@repo_root, "config/runtime.exs"))

    env_vars =
      env_example
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.match?(&1, ~r/^[A-Z][A-Z0-9_]*=/))
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

    # config/runtime.exs raises "environment variable X is missing" for every
    # var it requires in prod; those are exactly the vars .env.example must list.
    required_vars =
      Regex.scan(~r/environment variable ([A-Z][A-Z0-9_]*) is missing/, runtime_exs)
      |> Enum.map(fn [_, var] -> var end)
      |> Enum.uniq()

    assert required_vars != [],
           "config/runtime.exs must declare at least one required env var"

    for var <- required_vars do
      assert var in env_vars,
             ".env.example must declare required runtime var #{var} (config/runtime.exs raises when it is missing)"
    end
  end
end
