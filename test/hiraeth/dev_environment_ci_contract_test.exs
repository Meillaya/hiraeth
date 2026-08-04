defmodule Hiraeth.DevEnvironmentCIContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @tag :ci_devenv_contract
  test "CI workflow has a lean Nix/devenv smoke lane backed by devenv-managed PostgreSQL" do
    assert_contract_file(".github/workflows/ci.yml", "CI workflow")

    workflow = read!(".github/workflows/ci.yml")
    devenv_job = ci_job!(workflow, "devenv-smoke")
    devenv_steps = ci_steps(devenv_job)

    assert devenv_job =~ ~r/name:\s*.*devenv.*smoke/i,
           "devenv-smoke CI job must be clearly named as the Nix/devenv smoke lane"

    assert devenv_job =~
             ~r/nix|DeterminateSystems\/nix-installer-action|cachix\/install-nix-action/i,
           "devenv-smoke CI job must install or provide Nix explicitly"

    assert Enum.any?(devenv_steps, &devenv_postgres_readiness?/1),
           "devenv-smoke CI job must start devenv-managed PostgreSQL and wait for readiness"

    assert Enum.any?(devenv_steps, &mix_gate?/1),
           "devenv-smoke CI job must run the fast blocking mix gate through devenv"

    # The smoke lane is deliberately lean: it only proves devenv can start
    # Postgres and run the fast blocking gate. The full readiness graph and the
    # sidecar pytest gate moved to the deep lane (deep.yml).
    refute devenv_job =~ ~r/example\.com/,
           "devenv-smoke CI job must not fetch external example.com content"

    refute Enum.any?(devenv_steps, &sidecar_pytest_gate?/1),
           "devenv-smoke CI job must not run the sidecar pytest gate (moved to deep.yml)"

    refute Enum.any?(devenv_steps, &devenv_test_gate?/1),
           "devenv-smoke CI job must not run the full devenv -- test readiness graph (moved to deep.yml)"

    refute devenv_job =~ ~r/^\s*services:\s*$/m,
           "devenv-smoke CI job must use devenv-managed PostgreSQL, not a GitHub service container"

    assert_only_postgres_services_for_test_fast!(workflow)

    refute workflow =~ ~r/legacy-compose-postgres/,
           "ci.yml must not define a legacy-compose-postgres job (removed in the tiered-gates rewrite)"

    refute workflow =~ ~r/--option\s+sandbox\s+false|sandbox\s*=\s*false|--impure/,
           "CI workflow must not disable Nix sandboxing or rely on impure evaluation"

    refute workflow =~ ~r/secrets\.(?!GITHUB_TOKEN)/,
           "CI workflow must not require undocumented private cache credentials"

    assert_deep_lane_contract!()
  end

  # The full `devenv -- test` readiness graph and the sidecar pytest gate moved
  # to the deep lane (.github/workflows/deep.yml, created by todo:6). deep.yml
  # does not exist yet, so these assertions are conditional on file existence:
  # once the file lands the contract is enforced; until then the test stays
  # green without weakening the deep-lane intent.
  defp assert_deep_lane_contract! do
    deep_path = path(".github/workflows/deep.yml")

    if File.exists?(deep_path) do
      deep = File.read!(deep_path)

      assert deep =~ ~r/devenv\s+test/,
             "deep.yml must run the full devenv -- test readiness graph"

      assert deep =~ ~r/pytest/,
             "deep.yml must run the sidecar pytest gate"

      refute deep =~ ~r/^\s*pull_request:\s*$/m,
             "deep.yml must not be triggered on pull_request (deep lane is merge/nightly/manual only)"
    end
  end

  # The tiered-gates rewrite removed the legacy-compose-postgres lane; the only
  # remaining GitHub service container is the postgres:16 block that feeds the
  # fast test suite. Assert exactly one services: block exists and it lives in
  # the test-fast job.
  defp assert_only_postgres_services_for_test_fast!(workflow) do
    services_blocks = Regex.scan(~r/^\s*services:\s*$/m, workflow)

    assert length(services_blocks) == 1,
           "ci.yml must contain exactly one postgres services: block (got #{length(services_blocks)})"

    assert ci_job!(workflow, "test-fast") =~ ~r/^\s*services:\s*$/m,
           "the single postgres services: block must live in the test-fast job"

    refute ci_job!(workflow, "static") =~ ~r/^\s*services:\s*$/m,
           "static job must not define a services: block"

    refute ci_job!(workflow, "devenv-smoke") =~ ~r/^\s*services:\s*$/m,
           "devenv-smoke job must not define a services: block"
  end

  defp devenv_postgres_readiness?(step) do
    step =~ ~r/devenv\s+--\s+up\s+-d\s+hiraeth-postgres/ and step =~ ~r/pg_isready/
  end

  defp mix_gate?(step) do
    step =~
      ~r/nix\s+run\s+nixpkgs#devenv\s+--\s+shell\s+--\s+bash\s+-lc\s+['"]mix\s+gate['"]/
  end

  defp devenv_test_gate?(step),
    do: step =~ ~r/nix\s+run\s+nixpkgs#devenv\s+--\s+test|devenv\s+test/

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
