#!/usr/bin/env bash
# =============================================================================
# measure_gates.sh - wall-time baseline harness for the Hiraeth verification
# gates. Recreated fresh for the devenv-end-to-end-restore plan (todo 1).
#
# Usage:
#   bash scripts/qa/perf/measure_gates.sh                 # full gate baseline
#   bash scripts/qa/perf/measure_gates.sh --only fast     # fast blocking set
#   bash scripts/qa/perf/measure_gates.sh --only lanes    # lane timings (test.fast + test.full + test.nightly)
#   bash scripts/qa/perf/measure_gates.sh --gate-now      # + warm/cold compile
#   bash scripts/qa/perf/measure_gates.sh --help
#
# Outputs (default under artifacts/qa/perf/):
#   baseline.json   {"gates": {"<gate_name>": <ms>, ..., "error": {...}|null},
#                    "mode": ..., "env": {...}, "test_files": {...}, "totals": {...}}
#   gate-now.json   (with --gate-now) {"gate": "compile", "gate_warm_ms": N,
#                    "gate_cold_ms": N, "error": {...}|null}
#   logs/<gate>.log per-gate stdout/stderr
#
# Gate sets:
#   fast: blocked-check, compile, format, credo, hex.audit, sidecar-pytest, test.fast
#   full: fast + test.full, coveralls, dialyzer, provenance
#   lanes: blocked-check, compile, test.fast, test.full, test.nightly
#
# Design notes:
#   * Every gate runs under `timeout` inside its own process group (`setsid`),
#     so a hung gate (the historical devenv-hang failure class) is killed
#     group-wide and can never hang the harness or poison later gates.
#   * A failing gate is recorded (per-gate entry plus gates.error), later
#     gates still run, and the harness exits NON-ZERO with a summary line on
#     stderr. A failure never produces a green-looking JSON.
#   * The `blocked-check` gate is a no-op unless /tmp/blocked-check exists, in
#     which case it fails - a deterministic failure-injection lever mirroring
#     the historical devenv-hang class.
#   * Per-file ExUnit timings come from the `--slowest 50` reports of the
#     test.fast and test.full gates (plus test.nightly when it ran) and are
#     merged per test file.
#   * When not already inside a devenv shell, the harness re-executes itself
#     inside `nix run nixpkgs#devenv -- shell --no-reload` with stdout/stderr
#     redirected to a FILE (never a pipe - a pipe inherited by devenv children
#     is a documented hang mode for this project). Set PERF_NO_DEVENV=1 to
#     disable the re-exec and run gate commands directly.
#   * `--gate-now` additionally measures a warm and a cold `mix compile` (the
#     cold run moves MIX_BUILD_ROOT `.devenv/mix-build` aside to
#     `.devenv/mix-build.hold` first and restores it afterwards, with a trap
#     guaranteeing the restore even on failure).
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
  bash scripts/qa/perf/measure_gates.sh --only fast     # fast blocking set
  bash scripts/qa/perf/measure_gates.sh --only lanes    # lane timings (test.fast + test.full + test.nightly)
  bash scripts/qa/perf/measure_gates.sh --gate-now      # also measure warm/cold compile
  bash scripts/qa/perf/measure_gates.sh --help

Options:
  --only fast|lanes|full   restrict the gate set (default: full)
  --gate-now         additionally write gate-now.json (warm + cold compile ms)
  -h, --help         show this help

Environment:
  PERF_OUT          JSON output path (default: artifacts/qa/perf/baseline.json)
  PERF_NO_DEVENV    skip the devenv shell re-exec (debug only)
EOF
}

MODE="full"
GATE_NOW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      if [[ $# -lt 2 ]]; then
        printf 'measure_gates: --only requires a mode (fast|lanes|full)\n' >&2
        exit 2
      fi
      case "$2" in
        fast|lanes|full) MODE="$2" ;;
        *)
          printf "measure_gates: unknown mode '%s' (expected fast|lanes|full)\n" "$2" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --gate-now) GATE_NOW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf "measure_gates: unknown argument '%s'\n" "$1" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Re-exec inside the canonical devenv shell when not already there. The
# re-exec's stdout/stderr go to a FILE, never a pipe: a pipe inherited by
# devenv-managed children is a documented hang mode for this project.
# PERF_INSIDE_DEVENV is a belt-and-suspenders loop guard on top of the
# DEVENV_PROFILE probe.
# ---------------------------------------------------------------------------
if [[ "${PERF_INSIDE_DEVENV:-}" != "1" && -z "${DEVENV_PROFILE:-}" && "${PERF_NO_DEVENV:-}" != "1" ]]; then
  if ! command -v nix >/dev/null 2>&1; then
    printf 'measure_gates: not inside a devenv shell and nix is unavailable - run from a devenv shell\n' >&2
    exit 2
  fi
  OUT_FILE="${PERF_OUT:-${ROOT}/artifacts/qa/perf/baseline.json}"
  REEXEC_LOG="$(dirname "${OUT_FILE}")/logs/devenv-reexec.log"
  mkdir -p "$(dirname "${OUT_FILE}")/logs"
  printf 'measure_gates: re-executing inside the devenv shell (log: %s)\n' "${REEXEC_LOG}" >&2
  export PERF_INSIDE_DEVENV=1
  # shellcheck disable=SC2016
  exec nix run nixpkgs#devenv -- shell --no-reload -- bash -lc 'exec bash "$0" "$@"' "${HARNESS}" "${ORIG_ARGS[@]}" >"${REEXEC_LOG}" 2>&1
fi

# ---------------------------------------------------------------------------
# Output layout and required tools.
# ---------------------------------------------------------------------------
OUT_FILE="${PERF_OUT:-${ROOT}/artifacts/qa/perf/baseline.json}"
LOG_DIR="$(dirname "${OUT_FILE}")/logs"
mkdir -p "${LOG_DIR}"

for tool in timeout setsid python3 date; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf "measure_gates: required tool '%s' not found on PATH\n" "${tool}" >&2
    exit 2
  }
done

START_NS="$(date +%s%N)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/measure-gates.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

OVERALL_FAILED=0
FAILED_GATES=()
GATES_TSV="${TMP_DIR}/gates.tsv"
ENV_TSV="${TMP_DIR}/env.tsv"
: > "${GATES_TSV}"

# gate_wrap runs a command in the foreground of the fresh process group that
# `setsid` created and group-kills the whole tree on TERM, so a `timeout` on
# the outer process kills everything the gate spawned (the historical
# devenv-hang failure class).
gate_wrap() {
  trap 'kill -- -$$ 2>/dev/null || true; exit 124' TERM
  "$@" &
  wait $!
}

# run_timed measures a command's wall-clock ms under timeout+setsid, writes
# the gate log, echoes the duration, and returns the gate's exit status.
run_timed() {
  local name="$1"
  local timeout_s="$2"
  shift 2
  local started finished exit_code wrap_code
  started="$(date +%s%N)"
  wrap_code="$(declare -f gate_wrap)"
  set +e
  timeout -k 30 "${timeout_s}" setsid bash -c "${wrap_code}
gate_wrap \"\$@\"" gate_wrap "$@" >"${LOG_DIR}/${name}.log" 2>&1
  exit_code=$?
  set -e
  finished="$(date +%s%N)"
  printf '%s\n' "$(( (finished - started) / 1000000 ))"
  return "${exit_code}"
}

# run_gate records a measured gate into the baseline (tsv) and tracks the
# overall failure state; later gates always still run.
run_gate() {
  local name="$1"
  local timeout_s="$2"
  shift 2
  local dur_ms exit_code
  printf 'gate[%s] start: %s\n' "${name}" "$*"
  set +e
  dur_ms="$(run_timed "${name}" "${timeout_s}" "$@")"
  exit_code=$?
  set -e
  if [[ "${exit_code}" -eq 0 ]]; then
    printf 'gate[%s] pass: %sms exit=0\n' "${name}" "${dur_ms}"
  else
    OVERALL_FAILED=1
    FAILED_GATES+=("${name}")
    printf 'gate[%s] FAIL: %sms exit=%s (log: %s)\n' "${name}" "${dur_ms}" "${exit_code}" "${LOG_DIR}/${name}.log" >&2
  fi
  printf '%s\t%s\t%s\n' "${name}" "${dur_ms}" "${exit_code}" >> "${GATES_TSV}"
}

# ---------------------------------------------------------------------------
# Gate definitions.
# ---------------------------------------------------------------------------
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

run_gate compile 600 env MIX_ENV=test mix compile --warnings-as-errors

if [[ "${MODE}" == "fast" || "${MODE}" == "full" ]]; then
  run_gate format 300 env MIX_ENV=test mix format --check-formatted
  run_gate credo 300 env MIX_ENV=test mix credo --strict
  run_gate hex.audit 300 env MIX_ENV=test mix hex.audit
  run_gate sidecar-pytest 600 bash -c 'cd sidecar && uv run --extra dev pytest -q'
fi

run_gate test.fast 600 env MIX_ENV=test mix test.fast --slowest 50

if [[ "${MODE}" == "full" || "${MODE}" == "lanes" ]]; then
  run_gate test.full 1800 env MIX_ENV=test mix test.full --slowest 50
fi

if [[ "${MODE}" == "full" ]]; then
  run_gate coveralls 1800 env MIX_ENV=test mix coveralls --include nightly --max-cases 8
  run_gate dialyzer 1800 env MIX_ENV=test mix dialyzer
  run_gate provenance 1800 make audit-provenance
elif [[ "${MODE}" == "lanes" ]]; then
  run_gate test.nightly 1800 env MIX_ENV=test mix test --only nightly --slowest 50
fi

# ---------------------------------------------------------------------------
# Per-file ExUnit timings: aggregate the --slowest report from every lane
# gate that ran (test.fast, test.full, and test.nightly when in mode lanes),
# merging per test file. Logs may be absent when their gate failed early.
# ---------------------------------------------------------------------------
TEST_FILES_JSON="${TMP_DIR}/test_files.json"
TEST_LOGS=()
for f in "${LOG_DIR}/test.fast.log" "${LOG_DIR}/test.full.log" "${LOG_DIR}/test.nightly.log"; do
  if [[ -f "${f}" ]]; then
    TEST_LOGS+=("${f}")
  fi
done
if [[ ${#TEST_LOGS[@]} -gt 0 ]]; then
  python3 - "${TEST_LOGS[@]}" > "${TEST_FILES_JSON}" <<'PY'
import json, re, sys
pat = re.compile(r"\(\s*([0-9]+(?:\.[0-9]+)?)\s*(ms|s)\)\s*\[([^\]]+\.exs):([0-9]+)\]\s*$")
agg = {}
for log_path in sys.argv[1:]:
    log = open(log_path, encoding="utf-8", errors="replace").read()
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
else
  printf '{}\n' > "${TEST_FILES_JSON}"
fi
printf 'test_files: %s files aggregated from %s lane --slowest 50 logs\n' \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${TEST_FILES_JSON}")" \
  "${#TEST_LOGS[@]}"

# ---------------------------------------------------------------------------
# Environment snapshot for the baseline.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Emit baseline.json (atomic write: tmp + rename).
# ---------------------------------------------------------------------------
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
    gates[name] = int(dur)
    if code != "0":
        failed.append(name)
        if error is None:
            error = {"gate": name, "exit": int(code)}
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
        "gates_run": len([k for k in gates if k != "error"]),
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

# ---------------------------------------------------------------------------
# --gate-now: warm + cold compile measurement (cold = build dir held aside).
# ---------------------------------------------------------------------------
if [[ "${GATE_NOW}" -eq 1 ]]; then
  GATE_NOW_FILE="$(dirname "${OUT_FILE}")/gate-now.json"
  MIX_BUILD_DIR="${ROOT}/.devenv/mix-build"
  MIX_BUILD_HOLD="${ROOT}/.devenv/mix-build.hold"
  gate_now_error=""
  warm_ms=""
  cold_ms=""

  restore_mix_build() {
    if [[ -d "${MIX_BUILD_HOLD}" ]]; then
      # The cold compile recreates MIX_BUILD_ROOT from scratch (only the test
      # env), so the held original must REPLACE it, not just move back into an
      # empty slot. The recreated dir is a disposable build cache; the held
      # dir is the pre-existing state we must restore.
      if [[ -e "${MIX_BUILD_DIR}" ]]; then
        rm -rf "${MIX_BUILD_DIR}"
      fi
      mv "${MIX_BUILD_HOLD}" "${MIX_BUILD_DIR}"
      printf 'gate-now: restored %s\n' "${MIX_BUILD_DIR}" >&2
    fi
  }

  printf 'gate-now: warm compile run\n'
  set +e
  warm_ms="$(run_timed gate-now-warm 600 env MIX_ENV=test mix compile --warnings-as-errors)"
  warm_rc=$?
  set -e
  if [[ "${warm_rc}" -ne 0 ]]; then
    gate_now_error="{\"phase\": \"warm\", \"gate\": \"compile\", \"exit\": ${warm_rc}}"
    printf 'gate-now: warm compile FAIL exit=%s (log: %s)\n' "${warm_rc}" "${LOG_DIR}/gate-now-warm.log" >&2
  else
    printf 'gate-now: warm compile pass: %sms\n' "${warm_ms}"
  fi

  if [[ -d "${MIX_BUILD_DIR}" ]]; then
    trap restore_mix_build EXIT
    mv "${MIX_BUILD_DIR}" "${MIX_BUILD_HOLD}"
  else
    printf 'gate-now: no %s present; cold run is identical to warm (nothing to hold aside)\n' "${MIX_BUILD_DIR}"
  fi

  printf 'gate-now: cold compile run (mix-build held aside)\n'
  set +e
  cold_ms="$(run_timed gate-now-cold 900 env MIX_ENV=test mix compile --warnings-as-errors)"
  cold_rc=$?
  set -e
  if [[ "${cold_rc}" -ne 0 ]]; then
    gate_now_error="${gate_now_error:+${gate_now_error}, }{\"phase\": \"cold\", \"gate\": \"compile\", \"exit\": ${cold_rc}}"
    printf 'gate-now: cold compile FAIL exit=%s (log: %s)\n' "${cold_rc}" "${LOG_DIR}/gate-now-cold.log" >&2
  else
    printf 'gate-now: cold compile pass: %sms\n' "${cold_ms}"
  fi

  restore_mix_build
  trap - EXIT

  python3 - "${GATE_NOW_FILE}" "${warm_ms:-0}" "${cold_ms:-0}" "${gate_now_error}" <<'PY'
import datetime, json, os, sys
out_file, warm_ms, cold_ms, err = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
doc = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "gate": "compile",
    "gate_warm_ms": warm_ms,
    "gate_cold_ms": cold_ms,
    "error": json.loads(err) if err else None,
}
tmp_out = out_file + ".tmp"
with open(tmp_out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp_out, out_file)
print(f"wrote {out_file} warm_ms={warm_ms} cold_ms={cold_ms}")
PY
  if [[ -n "${gate_now_error}" ]]; then
    OVERALL_FAILED=1
    FAILED_GATES+=("gate-now")
  fi
fi

# ---------------------------------------------------------------------------
# Summary + exit status. A failing gate is NEVER silently green.
# ---------------------------------------------------------------------------
gates_run="$(wc -l < "${GATES_TSV}")"
if [[ "${OVERALL_FAILED}" -eq 1 ]]; then
  printf 'measure_gates: FAILED gates: %s (mode=%s gates=%s elapsed_ms=%s out=%s logs=%s)\n' \
    "${FAILED_GATES[*]}" "${MODE}" "${gates_run}" "${elapsed_ms}" "${OUT_FILE}" "${LOG_DIR}" >&2
  exit 1
fi
printf 'measure_gates: all %s gates passed (mode=%s elapsed_ms=%s out=%s)\n' \
  "${gates_run}" "${MODE}" "${elapsed_ms}" "${OUT_FILE}"
