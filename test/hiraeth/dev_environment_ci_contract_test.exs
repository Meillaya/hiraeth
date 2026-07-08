defmodule Hiraeth.DevEnvironmentCIContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @tag :ci_devenv_contract
  test "CI workflow has a Nix/devenv lane backed by devenv-managed PostgreSQL" do
    assert_contract_file(".github/workflows/ci.yml", "CI workflow")

    workflow = read!(".github/workflows/ci.yml")
    devenv_job = ci_job!(workflow, "devenv")
    devenv_steps = ci_steps(devenv_job)

    assert devenv_job =~ ~r/name:\s*.*devenv/i,
           "devenv CI job must be clearly named as the Nix/devenv lane"

    assert devenv_job =~
             ~r/nix|DeterminateSystems\/nix-installer-action|cachix\/install-nix-action/i,
           "devenv CI job must install or provide Nix explicitly"

    assert Enum.any?(devenv_steps, &phoenix_ci_gate?/1),
           "devenv CI job must run the migrated Phoenix CI gate through devenv"

    assert Enum.any?(devenv_steps, &sidecar_pytest_gate?/1),
           "devenv CI job must run the migrated sidecar pytest gate through devenv"

    assert Enum.any?(devenv_steps, &devenv_test_gate?/1),
           "devenv CI job must exercise devenv-managed process/readiness tests"

    assert_mix_bootstrap_before_migrated_gates!(devenv_steps)

    refute devenv_job =~ ~r/^\s*services:\s*$/m,
           "devenv CI job must use devenv-managed PostgreSQL, not a GitHub service container"

    if workflow =~ ~r/^\s*services:\s*$/m do
      assert workflow =~ ~r/legacy-compose-postgres/,
             "any remaining GitHub service container job must be clearly named legacy-compose-postgres"

      assert workflow =~ ~r/Temporary fallback\/comparison lane/,
             "legacy service-container lane must be documented as temporary comparison/fallback"
    end

    refute workflow =~ ~r/--option\s+sandbox\s+false|sandbox\s*=\s*false|--impure/,
           "CI workflow must not disable Nix sandboxing or rely on impure evaluation"

    refute workflow =~ ~r/secrets\.(?!GITHUB_TOKEN)/,
           "CI workflow must not require undocumented private cache credentials"
  end

  defp assert_mix_bootstrap_before_migrated_gates!(steps) do
    bootstrap_index = Enum.find_index(steps, &mix_deps_bootstrap?/1)
    gate_indexes = migrated_gate_indexes(steps)

    assert bootstrap_index,
           "devenv CI job must bootstrap Hex/Rebar and Mix deps inside the devenv shell before migrated gates"

    assert gate_indexes != [], "devenv CI job must define at least one migrated gate"

    assert Enum.all?(gate_indexes, &(bootstrap_index < &1)),
           "devenv CI job must run Mix dependency bootstrap before devenv test, mix ci, and sidecar pytest gates"
  end

  defp migrated_gate_indexes(steps) do
    steps
    |> Enum.with_index()
    |> Enum.filter(fn {step, _index} ->
      devenv_test_gate?(step) or phoenix_ci_gate?(step) or sidecar_pytest_gate?(step)
    end)
    |> Enum.map(fn {_step, index} -> index end)
  end

  defp mix_deps_bootstrap?(step) do
    step =~ ~r/nix\s+run\s+nixpkgs#devenv\s+--\s+shell\s+--|devenv\s+shell\s+--/ and
      step =~ ~r/mix\s+local\.hex\s+--force/ and
      step =~ ~r/mix\s+local\.rebar\s+--force/ and
      step =~ ~r/mix\s+deps\.get/
  end

  defp devenv_test_gate?(step),
    do: step =~ ~r/nix\s+run\s+nixpkgs#devenv\s+--\s+test|devenv\s+test/

  defp phoenix_ci_gate?(step) do
    step =~
      ~r/nix\s+run\s+nixpkgs#devenv\s+--\s+(?:shell\s+--\s+)?mix\s+ci|devenv\s+(?:shell\s+--\s+)?mix\s+ci/
  end

  defp sidecar_pytest_gate?(step) do
    step =~
      ~r/nix\s+run\s+nixpkgs#devenv\s+--\s+(?:shell\s+--\s+)?bash\s+-lc\s+['"]cd sidecar && uv run --extra dev pytest -q['"]|devenv\s+(?:shell\s+--\s+)?bash\s+-lc\s+['"]cd sidecar && uv run --extra dev pytest -q['"]/
  end

  defp ci_steps(job) do
    job
    |> String.split(~r/^      - name:/m, trim: true)
    |> Enum.drop(1)
    |> Enum.map(&("      - name:" <> &1))
  end

  defp ci_job!(workflow, job_name) do
    job_header = ~r/^  #{Regex.escape(job_name)}:\s*$/
    next_job_header = ~r/^  [^\s][^:]*:\s*$/
    lines = String.split(workflow, "\n", trim: false)

    case Enum.find_index(lines, &Regex.match?(job_header, &1)) do
      nil ->
        flunk("Expected CI workflow to define a #{job_name} job")

      start_index ->
        job_lines =
          lines
          |> Enum.with_index()
          |> Enum.drop(start_index)
          |> Enum.take_while(fn {line, index} ->
            index == start_index or not Regex.match?(next_job_header, line)
          end)
          |> Enum.map(fn {line, _index} -> line end)

        Enum.join(job_lines, "\n")
    end
  end

  defp assert_contract_file(relative_path, label) do
    file_path = path(relative_path)

    assert File.exists?(file_path),
           "#{label} is missing at #{relative_path}; CI/devenv contract is incomplete"

    assert File.regular?(file_path), "#{relative_path} must be a regular file"
    assert File.read!(file_path) =~ ~r/\S/, "#{relative_path} must not be empty"
    assert_git_visible!(relative_path, label)
  end

  defp assert_git_visible!(relative_path, label) do
    assert git_visible?(relative_path),
           "#{label} at #{relative_path} must be Git-visible (tracked or staged), not ignored/untracked"
  end

  defp git_visible?(relative_path) do
    {_output, status} =
      System.cmd("git", ["ls-files", "--error-unmatch", "--", relative_path],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp read!(relative_path), do: File.read!(path(relative_path))
  defp path(relative_path), do: Path.join(@repo_root, relative_path)
end
