#!/usr/bin/env bash
# =============================================================================
# measure_gates.sh - wall-time measurement harness for the Hiraeth
# verification gates.
#
# Usage:
#   bash scripts/qa/perf/measure_gates.sh                 # full gate baseline
#   bash scripts/qa/perf/measure_gates.sh --only fast     # fast blocking path
#   bash scripts/qa/perf/measure_gates.sh --help
#
# Writes a JSON baseline (default: artifacts/qa/perf/baseline.json):
#   {
#     "generated_at": "<ISO8601 UTC>",
#     "mode": "full" | "fast",
#     "env": { "host": ..., "kernel": ..., "cpus": ..., "elixir": ...,
#              "python": ..., "git_commit": ..., "devenv_root": ...,
#              "mix_gates_env": "test" },
#     "gates": { "<name>_ms": N, "<name>_exit": N, ..., "error": {...}|null },
#     "test_files": { "<test path>": {"sum_ms": N, "count": N, "max_ms": N} },
#     "totals": { "elapsed_ms": N, "gates_run": N, "gates_failed": N,
#                 "failed_gates": [...] }
#   }
#
# Design notes:
#   * Every gate runs under `timeout` inside its own setsid process group, so
#     a hung gate (the historical devenv-hang failure class) is killed
#     group-wide and can never hang the harness or poison later gates.
#   * A failing gate is recorded (per-gate *_exit plus gates.error), later
#     gates still run, and the harness exits NON-ZERO with a summary line on
#     stderr. A failure never produces a green-looking JSON.
#   * The `blocked-check` gate is a no-op unless /tmp/blocked-check exists, in
#     which case it fails - a deterministic failure-injection lever mirroring
#     the historical devenv-hang class.
#   * Per-file ExUnit timings come from a single `mix test.fast --slowest 50`
#     run (the test.fast gate itself) and are aggregated per test file: one
#     run, not one run per file.
#   * Mix gates run with MIX_ENV=test (the env `mix ci` / `precommit.fast`
#     use); browser and provenance gates run via `make` without an env
#     override, exactly as `make test-browser` / `make audit-provenance` run
#     today.
#   * When not already inside a devenv shell, the harness re-executes itself
#     inside `nix run nixpkgs#devenv -- shell` so every measured command runs
#     in the canonical environment. Set PERF_NO_DEVENV=1 to disable.
#   * The harness only writes under the output directory and /tmp; it never
#     touches priv/static/covers/cache/*, never modifies source files, and
#     never starts devenv processes.
# =============================================================================
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS_DIR}/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "${HARNESS_DIR}/../../.." && pwd)"
cd "${ROOT}"

ORIG_ARGS=("$@")

usage() {
  cat <<'EOF'
measure_gates.sh - wall-time baseline for the Hiraeth verification gates

Usage:
  bash scripts/qa/perf/measure_gates.sh                 # full gate baseline
  bash scripts/qa/perf/measure_gates.sh --only fast     # fast blocking path only
  bash scripts/qa/perf/measure_gates.sh --help

Environment:
  PERF_OUT        JSON output path (default: artifacts/qa/perf/baseline.json)
  PERF_NO_DEVENV  skip the devenv re-exec (debug only)
EOF
}

MODE="full"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      if [[ $# -lt 2 ]]; then
        printf 'measure_gates: --only requires a mode (fast|full)\n' >&2
        exit 2
      fi
      case "$2" in
        fast|full) MODE="$2" ;;
        *)
          printf "measure_gates: unknown mode '%s' (expected fast|full)\n" "$2" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf "measure_gates: unknown argument '%s'\n" "$1" >&2
      exit 2
      ;;
  esac
done

# Re-exec inside the canonical devenv shell when not already there.
if [[ -z "${DEVENV_PROFILE:-}" && "${PERF_NO_DEVENV:-}" != "1" ]]; then
  if ! command -v nix >/dev/null 2>&1; then
    printf 'measure_gates: not inside a devenv shell and nix is unavailable - run from a devenv shell\n' >&2
    exit 2
  fi
  # shellcheck disable=SC2016
  exec nix run nixpkgs#devenv -- shell -- bash -lc 'exec bash "$0" "$@"' "${HARNESS}" "${ORIG_ARGS[@]}"
fi

OUT_FILE="${PERF_OUT:-${ROOT}/artifacts/qa/perf/baseline.json}"
mkdir -p "$(dirname "${OUT_FILE}")"
LOG_DIR="$(dirname "${OUT_FILE}")/logs"
mkdir -p "${LOG_DIR}"

command -v timeout >/dev/null 2>&1 || { printf 'measure_gates: timeout (coreutils) not found\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'measure_gates: python3 not found\n' >&2; exit 2; }
command -v setsid >/dev/null 2>&1 || { printf 'measure_gates: setsid (util-linux) not found\n' >&2; exit 2; }

START_NS="$(date +%s%N)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/measure-gates.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

OVERALL_FAILED=0
FAILED_GATES=()
GATES_TSV="${TMP_DIR}/gates.tsv"
ENV_TSV="${TMP_DIR}/env.tsv"
TEST_FILES_JSON="${TMP_DIR}/test_files.json"
: > "${GATES_TSV}"

# gate_wrap runs a gate in its own process group (setsid) so a timeout can
# kill the whole tree; on TERM it group-kills and reports the conventional
# 124 timeout status.
gate_wrap() {
  trap 'kill -- -$$ 2>/dev/null || true; exit 124' TERM
  "$@" &
  wait $!
}

run_gate() {
  local name="$1"
  local timeout_s="$2"
  shift 2
  local wrap_code
  local log_file="${LOG_DIR}/${name}.log"
  local started finished dur_ms exit_code
  printf 'gate[%s] start: %s\n' "${name}" "$*"
  started="$(date +%s%N)"
  wrap_code="$(declare -f gate_wrap)"
  set +e
  timeout -k 30 "${timeout_s}" setsid bash -c "${wrap_code}
gate_wrap \"\$@\"" gate_wrap "$@" >"${log_file}" 2>&1
  exit_code=$?
  set -e
  finished="$(date +%s%N)"
  dur_ms=$(( (finished - started) / 1000000 ))
  if [[ "${exit_code}" -eq 0 ]]; then
    printf 'gate[%s] pass: %sms exit=0\n' "${name}" "${dur_ms}"
  else
    OVERALL_FAILED=1
    FAILED_GATES+=("${name}")
    printf 'gate[%s] FAIL: %sms exit=%s (log: %s)\n' "${name}" "${dur_ms}" "${exit_code}" "${log_file}" >&2
  fi
  printf '%s\t%s\t%s\n' "${name}" "${dur_ms}" "${exit_code}" >> "${GATES_TSV}"
}

# blocked-check: deterministic failure-injection lever. A no-op unless
# /tmp/blocked-check exists, in which case it fails (mirrors the historical
# devenv-hang failure class). Present in both modes.
run_gate blocked-check 10 bash -c '
  if [[ -e /tmp/blocked-check ]]; then
    echo "blocked-check: /tmp/blocked-check sentinel present - simulated gate failure"
    exit 1
  fi
  echo "blocked-check: no sentinel present - ok"
'

if [[ "${MODE}" == "fast" ]]; then
  printf 'measure_gates: mode=fast gates=compile,format,credo,test.fast,blocked-check\n'
  run_gate compile 300 env MIX_ENV=test mix compile --warnings-as-errors
  run_gate format 300 env MIX_ENV=test mix format --check-formatted
  run_gate credo 300 env MIX_ENV=test mix credo --strict
  run_gate test.fast 900 env MIX_ENV=test mix test.fast --slowest 50
else
  printf 'measure_gates: mode=full gates=compile,format,credo,sobelow,hex.audit,test.fast,test.full,dialyzer,coveralls,browser,provenance,sidecar-pytest,blocked-check\n'
  run_gate compile 300 env MIX_ENV=test mix compile --warnings-as-errors
  run_gate format 300 env MIX_ENV=test mix format --check-formatted
  run_gate credo 300 env MIX_ENV=test mix credo --strict
  run_gate sobelow 300 env MIX_ENV=test mix sobelow --config .sobelow-conf --exit Low
  run_gate hex.audit 300 env MIX_ENV=test mix hex.audit
  run_gate sidecar-pytest 600 bash -c 'cd sidecar && uv run --extra dev pytest -q'
  run_gate test.fast 900 env MIX_ENV=test mix test.fast --slowest 50
  run_gate test.full 1800 env MIX_ENV=test mix test.full
  run_gate coveralls 1800 env MIX_ENV=test mix coveralls --max-cases 8
  run_gate dialyzer 1800 env MIX_ENV=test mix dialyzer
  run_gate provenance 1800 make audit-provenance
  run_gate browser 1800 env STRICT_TIMING=1 make test-browser
fi

# Per-file ExUnit timings: aggregate the --slowest report from the test.fast
# gate run (one run feeds both the gate timing and the per-file map).
python3 - "${LOG_DIR}/test.fast.log" > "${TEST_FILES_JSON}" <<'PY'
import json, re, sys
log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
pat = re.compile(r"\(\s*([0-9]+(?:\.[0-9]+)?)\s*(ms|s)\)\s*\[([^\]]+\.exs):([0-9]+)\]\s*$")
agg = {}
for line in log.splitlines():
    m = pat.search(line.rstrip())
    if not m:
        continue
    value, unit, path, _line = m.groups()
    ms = float(value) * (1000.0 if unit == "s" else 1.0)
    entry = agg.setdefault(path, {"sum_ms": 0.0, "count": 0, "max_ms": 0.0})
    entry["sum_ms"] += ms
    entry["count"] += 1
    if ms > entry["max_ms"]:
        entry["max_ms"] = ms
out = {
    path: {"sum_ms": round(v["sum_ms"]), "count": v["count"], "max_ms": round(v["max_ms"])}
    for path, v in sorted(agg.items())
}
json.dump(out, sys.stdout)
PY
test_file_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${TEST_FILES_JSON}")"
printf 'test_files: %s files aggregated from test.fast --slowest 50\n' "${test_file_count}"

# Environment snapshot for the baseline.
{
  printf 'generated_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host\t%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
  printf 'kernel\t%s\n' "$(uname -srmo 2>/dev/null || printf 'unknown')"
  printf 'cpus\t%s\n' "$(nproc 2>/dev/null || printf 'unknown')"
  # || true: early grep exit raises SIGPIPE (141) under pipefail - keep the guard
  printf 'elixir\t%s\n' "$(elixir --version 2>/dev/null | grep -m1 '^Elixir ' || true)"
  printf 'python\t%s\n' "$(python3 --version 2>/dev/null || printf 'unknown')"
  printf 'git_commit\t%s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  printf 'devenv_root\t%s\n' "${DEVENV_ROOT:-none}"
  printf 'mix_gates_env\ttest\n'
} > "${ENV_TSV}"

END_NS="$(date +%s%N)"
elapsed_ms=$(( (END_NS - START_NS) / 1000000 ))

python3 - "${MODE}" "${TMP_DIR}" "${OUT_FILE}" "${elapsed_ms}" <<'PY'
import json, os, sys
mode, tmp, out_file, elapsed_ms = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
env = {}
for line in open(os.path.join(tmp, "env.tsv"), encoding="utf-8"):
    key, _sep, value = line.rstrip().partition("\t")
    env[key] = value
gates = {}
error = None
failed = []
for line in open(os.path.join(tmp, "gates.tsv"), encoding="utf-8"):
    name, dur, code = line.rstrip().split("\t")
    code_i = int(code)
    gates[f"{name}_ms"] = int(dur)
    gates[f"{name}_exit"] = code_i
    if code_i != 0:
        failed.append(name)
        if error is None:
            error = {"gate": name, "exit": code_i}
gates["error"] = error
with open(os.path.join(tmp, "test_files.json"), encoding="utf-8") as fh:
    test_files = json.load(fh)
doc = {
    "generated_at": env.get("generated_at", ""),
    "mode": mode,
    "env": env,
    "gates": gates,
    "test_files": test_files,
    "totals": {
        "elapsed_ms": elapsed_ms,
        "gates_run": len([k for k in gates if k.endswith("_ms")]),
        "gates_failed": len(failed),
        "failed_gates": failed,
    },
}
tmp_out = out_file + ".tmp"
with open(tmp_out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp_out, out_file)
print(f"wrote {out_file} mode={mode} test_files={len(test_files)}")
PY

gates_run="$(wc -l < "${GATES_TSV}")"
if [[ "${OVERALL_FAILED}" -eq 1 ]]; then
  printf 'measure_gates: FAILED gates: %s (mode=%s gates=%s elapsed_ms=%s out=%s logs=%s)\n' \
    "${FAILED_GATES[*]}" "${MODE}" "${gates_run}" "${elapsed_ms}" "${OUT_FILE}" "${LOG_DIR}" >&2
  exit 1
fi
printf 'measure_gates: all %s gates passed (mode=%s elapsed_ms=%s out=%s)\n' \
  "${gates_run}" "${MODE}" "${elapsed_ms}" "${OUT_FILE}"
