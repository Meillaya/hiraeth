#!/usr/bin/env bash
set -euo pipefail

# cover_cache_sandbox.sh -- prove the root priv/static/covers/cache tree is
# untouched while a risky cleanup command runs inside a throwaway sandbox copy
# of the worktree. The root cover cache is only ever READ (hashed); it is never
# written to by this script.
#
#   scripts/qa/cover_cache_sandbox.sh [--record <receipt-path>] [--] <command> [args...]
#
# Behaviours:
#   * A recursive SHA-256 of every file in priv/static/covers/cache/ is taken
#     before and after the sandboxed command; any difference aborts (exit 2).
#   * When a hash receipt exists the current hash must equal it. A missing or
#     empty receipt only warns, so a fresh checkout / CI (where the receipt is
#     gitignored and absent) can still run with just the before/after guard.
#   * --record <path> writes the current, verified cache hash as the receipt
#     (default: .omo/evidence/repo-cleanup-consolidation/task-1-cover-cache-hashes.txt).
#   * COVER_CACHE_SANDBOX_TIMEOUT bounds the sandboxed command (coreutils
#     timeout duration; default 300 seconds).

readonly CACHE_DIR="priv/static/covers/cache"
readonly DEFAULT_RECEIPT=".omo/evidence/repo-cleanup-consolidation/task-1-cover-cache-hashes.txt"
readonly DEFAULT_TIMEOUT="300"

readonly NEVER_COVER_CACHE_RULE="Never delete, clean, modify, truncate, move, or regenerate root priv/static/covers/cache/*; preserve .gitkeep and generated cover files."
readonly DELETION_ALLOWLIST=("artifacts/" "_build/" "deps/" ".mypy_cache/" ".pytest_cache/" ".ruff_cache/" "sidecar/.venv/" "sidecar/.pytest_cache/" "scripts/__pycache__/" "scripts/catalog/__pycache__/" "scripts/qa/ingestion/__pycache__/" "erl_crash.dump")
readonly DELETION_DENYLIST=("priv/static/covers/cache/" "lib/" "test/" "config/" "assets/" "priv/catalog_sources/" ".omo/" ".omx/" ".git/")

tmp_parent=""
before_hash=""
after_hash=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/qa/cover_cache_sandbox.sh [--record <receipt-path>] [--] <command> [args...]

Runs <command> inside a temporary repository copy that excludes the root
priv/static/covers/cache/ directory. The root cover cache is read only: a
recursive SHA-256 hash is taken before and after the sandboxed command and the
two must be identical.

  --record <receipt-path>   after a clean run, write the current cache hash as
                            the receipt (default:
                            .omo/evidence/repo-cleanup-consolidation/
                            task-1-cover-cache-hashes.txt). When a receipt file
                            exists its hash must match the current hash; a
                            missing receipt only warns so a fresh checkout can
                            still run with the before/after guard alone.

  --                        explicit end of options; everything after is the
                            sandboxed command. Optional when the command has no
                            leading dashes.

COVER_CACHE_SANDBOX_TIMEOUT bounds the sandboxed command (coreutils timeout
duration, for example 5s or 2m; default 300 seconds).
USAGE
}

cleanup() {
  local removed="not_created"

  if [[ -n "${tmp_parent}" && -d "${tmp_parent}" ]]; then
    rm -rf "${tmp_parent}"
    removed="pass"
  fi

  [[ -n "${before_hash}" && -e "${before_hash}" ]] && rm -f "${before_hash}"
  [[ -n "${after_hash}" && -e "${after_hash}" ]] && rm -f "${after_hash}"

  printf 'cleanup_temp_dir_removed=%s path=%s\n' "${removed}" "${tmp_parent:-none}"
}

die() {
  printf 'cover_cache_sandbox_error=%s\n' "$*" >&2
  exit 2
}

snapshot_cover_cache() {
  local output_path="$1"

  [[ -d "${CACHE_DIR}" ]] || die "missing ${CACHE_DIR} (run from the repository or scratch root)"
  find "${CACHE_DIR}" -type f -print0 | sort -z | xargs -0 -r sha256sum > "${output_path}"
}

copy_worktree() {
  local source_root="$1"
  local sandbox_root="$2"

  mkdir -p "${sandbox_root}"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude "/${CACHE_DIR}/" "${source_root}/" "${sandbox_root}/"
  elif command -v tar >/dev/null 2>&1; then
    (
      cd "${source_root}"
      tar --exclude="./${CACHE_DIR}" -cf - .
    ) | (
      cd "${sandbox_root}"
      tar -xf -
    )
  else
    die "rsync or tar is required to copy the sandbox worktree"
  fi

  mkdir -p "${sandbox_root}/${CACHE_DIR}"
  if [[ ! -e "${sandbox_root}/${CACHE_DIR}/.gitkeep" ]]; then
    printf '\n' > "${sandbox_root}/${CACHE_DIR}/.gitkeep"
  fi
}

record_mode=0
receipt_path="${DEFAULT_RECEIPT}"
command_args=()

if [[ "$#" -eq 0 ]]; then
  usage
  exit 2
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --record)
      if [[ "$#" -lt 2 ]]; then
        die "--record requires a receipt path argument"
      fi
      if [[ "$2" == "--" ]]; then
        die "--record requires a receipt path argument"
      fi
      record_mode=1
      receipt_path="$2"
      shift 2
      ;;
    --)
      shift
      command_args=("$@")
      break
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      command_args=("$@")
      break
      ;;
  esac
done

if [[ "${#command_args[@]}" -eq 0 ]]; then
  usage
  die "no sandboxed command given"
fi

if command -v git >/dev/null 2>&1 && repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  if [[ "${PWD}" != "${repo_root}" ]]; then
    die "run from git root: ${repo_root}"
  fi
else
  # Not inside a git repository: operate on a scratch root (QA scratch copies).
  # The cache dir must exist relative to PWD in that case.
  repo_root="${PWD}"
  printf 'repo_scope=scratch_not_git root=%s\n' "${repo_root}"
fi

[[ -d "${repo_root}/${CACHE_DIR}" ]] || die "missing ${repo_root}/${CACHE_DIR}"

before_hash="$(mktemp "${TMPDIR:-/tmp}/hiraeth-cover-cache-before.XXXXXX")"
after_hash="$(mktemp "${TMPDIR:-/tmp}/hiraeth-cover-cache-after.XXXXXX")"
tmp_parent="$(mktemp -d "${TMPDIR:-/tmp}/hiraeth-cover-cache-sandbox.XXXXXX")"
trap cleanup EXIT

snapshot_cover_cache "${before_hash}"

if [[ -s "${receipt_path}" ]]; then
  cmp -s "${before_hash}" "${receipt_path}" || die "current root cover cache hash differs from receipt: ${receipt_path}"
  printf 'root_cover_cache_hash_matches_receipt=pass receipt=%s\n' "${receipt_path}"
else
  printf 'root_cover_cache_receipt=missing_warn proceeding_with_before_after_comparison_only receipt=%s\n' "${receipt_path}"
fi

printf 'never_cover_cache_rule=%s\n' "${NEVER_COVER_CACHE_RULE}"
printf 'deletion_allowlist=%s\n' "${DELETION_ALLOWLIST[*]}"
printf 'deletion_denylist=%s\n' "${DELETION_DENYLIST[*]}"

sandbox_root="${tmp_parent}/repo"
copy_worktree "${repo_root}" "${sandbox_root}"
printf 'sandbox_repo=%s\n' "${sandbox_root}"
printf 'sandbox_excluded_root_cache=%s\n' "${CACHE_DIR}"

sandbox_timeout="${COVER_CACHE_SANDBOX_TIMEOUT:-${DEFAULT_TIMEOUT}}"
if [[ ! "${sandbox_timeout}" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]]; then
  die "invalid COVER_CACHE_SANDBOX_TIMEOUT duration: ${sandbox_timeout}"
fi
if ! command -v timeout >/dev/null 2>&1; then
  die "COVER_CACHE_SANDBOX_TIMEOUT requires the timeout command"
fi
printf 'sandbox_timeout=%s\n' "${sandbox_timeout}"

set +e
(
  cd "${sandbox_root}"
  timeout -- "${sandbox_timeout}" "${command_args[@]}"
)
command_status=$?
set -e

snapshot_cover_cache "${after_hash}"
cmp -s "${before_hash}" "${after_hash}" || die "root cover cache changed during sandbox command"
printf 'root_cover_cache_hashes_unchanged_after=pass\n'

if [[ "${record_mode}" -eq 1 ]]; then
  mkdir -p "$(dirname "${receipt_path}")"
  cp "${after_hash}" "${receipt_path}"
  printf 'receipt_written=%s\n' "${receipt_path}"
fi

printf 'sandbox_command_exit=%s\n' "${command_status}"
exit "${command_status}"
