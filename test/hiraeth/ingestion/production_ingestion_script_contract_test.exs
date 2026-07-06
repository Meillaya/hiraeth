defmodule Hiraeth.Ingestion.ProductionIngestionScriptContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "ingestion drills start postgres and wait for readiness before test execution" do
    with_fake_commands(fn bin, log ->
      env = [{"PATH", "#{bin}:#{System.get_env("PATH")}"}, {"ARTIFACT_DIR", temp_dir()}]

      assert {_, 0} =
               System.cmd("bash", [script("production_ingestion_drill.sh")],
                 env: env,
                 stderr_to_stdout: true
               )

      assert {_, 0} =
               System.cmd("bash", [script("production_ingestion_adversarial.sh")],
                 env: env,
                 stderr_to_stdout: true
               )

      commands = read_commands(log)

      assert ordered?(
               commands,
               "docker compose up -d postgres",
               "mix test scripts/qa/ingestion/production_ingestion_drill_test.exs --only provider_replay --seed 0 --trace"
             )

      assert ordered?(
               commands,
               "docker compose exec -T postgres pg_isready -U postgres",
               "mix test scripts/qa/ingestion/production_ingestion_drill_test.exs --only provider_replay --seed 0 --trace"
             )

      assert ordered?(
               commands,
               "docker compose up -d postgres",
               "mix test scripts/qa/ingestion/production_ingestion_adversarial_test.exs --only destructive_diff --seed 0 --trace"
             )

      assert ordered?(
               commands,
               "docker compose exec -T postgres pg_isready -U postgres",
               "mix test scripts/qa/ingestion/production_ingestion_adversarial_test.exs --only destructive_diff --seed 0 --trace"
             )
    end)
  end

  test "browser QA tears down compose services on early exit" do
    with_fake_commands(fn bin, log ->
      env = [
        {"PATH", "#{bin}:#{System.get_env("PATH")}"},
        {"CHROME_BIN", "/bin/true"},
        {"QA_DIR", temp_dir()}
      ]

      assert {_, 1} =
               System.cmd("bash", [Path.join(@root, "scripts/browser_qa.sh")],
                 env: env,
                 stderr_to_stdout: true
               )

      assert "docker compose down" in read_commands(log)
    end)
  end

  defp with_fake_commands(fun) do
    root = temp_dir()
    bin = Path.join(root, "bin")
    log = Path.join(root, "commands.log")
    File.mkdir_p!(bin)
    File.touch!(log)
    write_fake_docker!(bin, log)
    write_fake_mix!(bin, log)
    write_fake_lsof!(bin, log)
    write_fake_uv!(bin, log)
    fun.(bin, log)
  end

  defp write_fake_docker!(bin, log) do
    write_executable!(Path.join(bin, "docker"), """
    #!/usr/bin/env bash
    echo "docker $*" >> #{sh(log)}
    if [[ "$*" == "compose exec -T postgres pg_isready -U postgres" ]]; then
      exit 0
    fi
    exit 0
    """)
  end

  defp write_fake_mix!(bin, log) do
    write_executable!(Path.join(bin, "mix"), """
    #!/usr/bin/env bash
    echo "mix $*" >> #{sh(log)}
    exit 0
    """)
  end

  defp write_fake_uv!(bin, log) do
    write_executable!(Path.join(bin, "uv"), """
    #!/usr/bin/env bash
    echo "uv $*" >> #{sh(log)}
    exit 0
    """)
  end

  defp write_fake_lsof!(bin, log) do
    write_executable!(Path.join(bin, "lsof"), """
    #!/usr/bin/env bash
    echo "lsof $*" >> #{sh(log)}
    echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
    exit 0
    """)
  end

  defp write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp script(name), do: Path.join(@root, "scripts/qa/ingestion/#{name}")

  defp temp_dir do
    Path.join(System.tmp_dir!(), "hiraeth-script-contract-#{System.unique_integer([:positive])}")
  end

  defp read_commands(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp ordered?(commands, earlier, later) do
    with earlier_index when is_integer(earlier_index) <-
           Enum.find_index(commands, &(&1 == earlier)),
         later_index when is_integer(later_index) <- Enum.find_index(commands, &(&1 == later)) do
      earlier_index < later_index
    else
      _missing -> false
    end
  end

  defp sh(path), do: "'#{String.replace(path, "'", "'\\''")}'"
end
