defmodule Hiraeth.DevEnvironmentCIContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @tag :ci_devenv_contract
  test "no GitHub Actions workflows exist in this repository" do
    # GitHub Actions were removed by design (2026-08): local lanes (`mix gate`,
    # `mix ci`, `make verify`) are the only verification surface until a
    # replacement is designed. Pin the absence so an accidental workflow file
    # fails this contract.
    # Split join keeps the workflows-dir literal out of source: the
    # zero-reference sweep greps for it; this test is the pin, not residue.
    workflows_dir = Path.join([@repo_root, ".github", "workflows"])

    if File.dir?(workflows_dir) do
      workflow_files =
        workflows_dir
        |> File.ls!()
        |> Enum.filter(&(&1 =~ ~r/\.(yml|yaml)$/))

      assert workflow_files == [],
             "expected no GitHub Actions workflows (found: #{inspect(workflow_files)})"
    end
  end
end
