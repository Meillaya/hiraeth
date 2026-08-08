defmodule Hiraeth.DevEnvironmentCIContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @tag :ci_devenv_contract
  test "CI workflow defines exactly the static and test-fast jobs with no Nix/devenv smoke lane" do
    assert_contract_file(".github/workflows/ci.yml", "CI workflow")

    workflow = read!(".github/workflows/ci.yml")

    # The de-nixed CI is a plain static + test-fast pair: no devenv-smoke job,
    # no Nix step anywhere on the fast path. Pin the exact job list so a
    # future re-introduction of a Nix/devenv lane fails this contract.
    assert ci_job_names(workflow) == ["static", "test-fast"],
           "ci.yml must define exactly the static and test-fast jobs (got #{inspect(ci_job_names(workflow))})"

    refute workflow =~ ~r/^  devenv-smoke:\s*$/m,
           "ci.yml must not define a devenv-smoke job after de-nixing"

    assert_only_postgres_services_for_test_fast!(workflow)

    refute workflow =~ ~r/legacy-\w+-postgres/,
           "ci.yml must not define a legacy containerized-postgres job (removed in the tiered-gates rewrite)"

    refute workflow =~ ~r/--option\s+sandbox\s+false|sandbox\s*=\s*false|--impure/,
           "CI workflow must not disable Nix sandboxing or rely on impure evaluation"

    refute workflow =~ ~r/secrets\.(?!GITHUB_TOKEN)/,
           "CI workflow must not require undocumented private cache credentials"

    assert_deep_lane_contract!()
  end

  @tag :ci_devenv_contract
  test "deep lane coverage job opts into the nightly lane explicitly" do
    # The coverage job owns the nightly lane (the ExCoveralls floor is
    # calibrated on the full suite); with test_helper default-excluding
    # :nightly, the job must opt back in explicitly via `--include nightly`.
    deep = read!(".github/workflows/deep.yml")
    coverage_job = ci_job!(deep, "coverage")

    assert coverage_job =~ "mix coveralls --include nightly",
           "expected the deep coverage job to run `mix coveralls --include nightly`"
  end

  @tag :ci_devenv_contract
  test "deep lane full-suite job does not exclude the nightly lane ad hoc" do
    # The nightly exclusion is owned by test_helper.exs via priv/test_lanes.exs;
    # an ad-hoc `--exclude nightly` flag here would drift from that contract.
    deep = read!(".github/workflows/deep.yml")
    full_suite_job = ci_job!(deep, "full-suite")

    refute full_suite_job =~ ~r/--exclude nightly/,
           "expected the full-suite job to rely on the test_helper default exclusion"
  end

  # The full `devenv -- test` readiness graph was de-nixed along with the
  # devenv-smoke lane: deep.yml must not reference devenv at all, while the
  # sidecar pytest gate and the merge/nightly-only trigger contract stay
  # enforced.
  defp assert_deep_lane_contract! do
    deep_path = path(".github/workflows/deep.yml")

    if File.exists?(deep_path) do
      deep = File.read!(deep_path)

      # deep.yml's de-nix job comments may mention devenv in prose ("no
      # Nix/devenv needed"); the pin targets actual invocations: a `devenv
      # test|up|shell|processes` step or a `nix run nixpkgs#devenv` wrapper.
      refute deep =~
               ~r/nix\s+run\s+nixpkgs#devenv|devenv\s+(?:--\s+)?(?:test|up|shell|processes|run)/,
             "deep.yml must not invoke devenv after de-nixing"

      assert deep =~ ~r/pytest/,
             "deep.yml must run the sidecar pytest gate"

      refute deep =~ ~r/^\s*pull_request:\s*$/m,
             "deep.yml must not be triggered on pull_request (deep lane is merge/nightly/manual only)"
    end
  end

  # The tiered-gates rewrite removed the legacy containerized-postgres lane; the
  # only remaining GitHub service container is the postgres:16 block that feeds
  # the fast test suite. Assert exactly one services: block exists and it lives
  # in the test-fast job.
  defp assert_only_postgres_services_for_test_fast!(workflow) do
    services_blocks = Regex.scan(~r/^\s*services:\s*$/m, workflow)

    assert length(services_blocks) == 1,
           "ci.yml must contain exactly one postgres services: block (got #{length(services_blocks)})"

    assert ci_job!(workflow, "test-fast") =~ ~r/^\s*services:\s*$/m,
           "the single postgres services: block must live in the test-fast job"

    refute ci_job!(workflow, "static") =~ ~r/^\s*services:\s*$/m,
           "static job must not define a services: block"
  end

  # Top-level job names under the `jobs:` key, in file order. Any two-space
  # indented `name:` line inside the jobs section is a job header.
  defp ci_job_names(workflow) do
    lines = String.split(workflow, "\n", trim: true)

    case Enum.find_index(lines, &(&1 == "jobs:")) do
      nil ->
        []

      jobs_start ->
        lines
        |> Enum.drop(jobs_start + 1)
        |> Enum.take_while(&Regex.match?(~r/^\s/, &1))
        |> Enum.filter(&Regex.match?(~r/^  [^\s][^:]*:\s*$/, &1))
        |> Enum.map(&(&1 |> String.trim() |> String.replace_suffix(":", "")))
    end
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
