#!/usr/bin/env bash
set -euo pipefail

readonly CACHE_DIR="priv/static/covers/cache"
readonly TODO1_HASH_RECEIPT=".omo/evidence/repo-cleanup-consolidation/task-1-cover-cache-hashes.txt"

readonly NEVER_COVER_CACHE_RULE="Never delete, clean, modify, truncate, move, or regenerate root priv/static/covers/cache/*; preserve .gitkeep and generated cover files."
readonly DELETION_ALLOWLIST=("artifacts/" "_build/" "deps/" ".mypy_cache/" ".pytest_cache/" ".ruff_cache/" "sidecar/.venv/" "sidecar/.pytest_cache/" "scripts/__pycache__/" "scripts/catalog/__pycache__/" "scripts/qa/ingestion/__pycache__/" "erl_crash.dump")
readonly DELETION_DENYLIST=("priv/static/covers/cache/" "lib/" "test/" "config/" "assets/" "priv/catalog_sources/" ".omo/" ".omx/" ".git/")

tmp_parent=""
before_hash=""
after_hash=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/qa/cover_cache_sandbox.sh <command> [args...]

Runs a command inside a temporary repository copy that excludes the root
priv/static/covers/cache/ directory. The root cover cache is read only for
recursive SHA-256 hash comparison before and after the sandboxed command.

Set COVER_CACHE_SANDBOX_TIMEOUT to a coreutils timeout duration (for example
5s or 2m) to bound the sandboxed command. When unset, the child command is
allowed to run normally and its exit status is propagated.
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

  [[ -d "${CACHE_DIR}" ]] || die "missing ${CACHE_DIR}"
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

if [[ "$#" -eq 0 ]]; then
  usage
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
if [[ "${PWD}" != "${repo_root}" ]]; then
  die "run from git root: ${repo_root}"
fi

[[ -s "${TODO1_HASH_RECEIPT}" ]] || die "missing non-empty Todo 1 hash receipt: ${TODO1_HASH_RECEIPT}"

before_hash="$(mktemp "${TMPDIR:-/tmp}/hiraeth-cover-cache-before.XXXXXX")"
after_hash="$(mktemp "${TMPDIR:-/tmp}/hiraeth-cover-cache-after.XXXXXX")"
tmp_parent="$(mktemp -d "${TMPDIR:-/tmp}/hiraeth-cover-cache-sandbox.XXXXXX")"
trap cleanup EXIT

snapshot_cover_cache "${before_hash}"
cmp -s "${before_hash}" "${TODO1_HASH_RECEIPT}" || die "current root cover cache hash differs from Todo 1 receipt"
printf 'root_cover_cache_hashes_match_todo1_before=pass receipt=%s\n' "${TODO1_HASH_RECEIPT}"
printf 'never_cover_cache_rule=%s\n' "${NEVER_COVER_CACHE_RULE}"
printf 'deletion_allowlist=%s\n' "${DELETION_ALLOWLIST[*]}"
printf 'deletion_denylist=%s\n' "${DELETION_DENYLIST[*]}"

sandbox_root="${tmp_parent}/repo"
copy_worktree "${repo_root}" "${sandbox_root}"
printf 'sandbox_repo=%s\n' "${sandbox_root}"
printf 'sandbox_excluded_root_cache=%s\n' "${CACHE_DIR}"

set +e
if [[ -n "${COVER_CACHE_SANDBOX_TIMEOUT:-}" ]]; then
  if [[ ! "${COVER_CACHE_SANDBOX_TIMEOUT}" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]]; then
    die "invalid COVER_CACHE_SANDBOX_TIMEOUT duration: ${COVER_CACHE_SANDBOX_TIMEOUT}"
  fi

  if ! command -v timeout >/dev/null 2>&1; then
    die "COVER_CACHE_SANDBOX_TIMEOUT requires the timeout command"
  fi

  printf 'sandbox_timeout=%s\n' "${COVER_CACHE_SANDBOX_TIMEOUT}"
  (
    cd "${sandbox_root}"
    timeout -- "${COVER_CACHE_SANDBOX_TIMEOUT}" "$@"
  )
else
  printf 'sandbox_timeout=unset caller_responsible_for_long_running_child=pass\n'
  (
    cd "${sandbox_root}"
    "$@"
  )
fi
command_status=$?
set -e

snapshot_cover_cache "${after_hash}"
cmp -s "${before_hash}" "${after_hash}" || die "root cover cache changed during sandbox command"
cmp -s "${after_hash}" "${TODO1_HASH_RECEIPT}" || die "root cover cache no longer matches Todo 1 receipt"
printf 'root_cover_cache_hashes_unchanged_after=pass\n'
printf 'sandbox_command_exit=%s\n' "${command_status}"

exit "${command_status}"
