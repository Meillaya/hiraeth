# PUBLIC COVER CACHE KNOWLEDGE BASE

## OVERVIEW

`priv/static/covers/cache/` is the canonical local public cover cache.
It is a private runtime asset and becomes authoritative after its first write.
Only `.gitkeep` is tracked. Runtime PNG and JPEG files remain untracked.
This child guide specializes cache immutability, the public path surface, and the safe-write contract.

## STRUCTURE

| Path | Role |
|---|---|
| `cache/` | Canonical runtime cache served through the public cover path |
| `cache/.gitkeep` | Sole tracked cache entry, preserving the directory |
| `../favicon.ico` | Site favicon |
| `../images/logo.svg` | Site logo |
| `../robots.txt` | Crawler directives |

`priv/static/favicon.ico`, `priv/static/images/logo.svg`, and `priv/static/robots.txt` are the only other static files.

## WHERE TO LOOK

| Concern | Location |
|---|---|
| Cleanup allow and deny list | `scripts/qa/cover_cache_sandbox.sh` |
| Sandboxed cache-write verification | `scripts/qa/cover_cache_sandbox.sh` |
| Cover caching operator task | `mix hiraeth.cache_covers` |
| Cache-root symlink rejection tests | `test/hiraeth/ingestion/cover_cache_root_test.exs` |
| Browser cover warmup gate | `scripts/browser_qa.sh` |

## CONVENTIONS

- Public HTML may render cover images only from paths under `/covers/cache/...`.
- Remote cover URLs aren't allowed as image assets.
- Treat every runtime PNG or JPEG as authoritative cache state after creation.
- Run cache-writing checks through `scripts/qa/cover_cache_sandbox.sh`.
- Cache writes must remain inside the sandbox and preserve the root cache unchanged.
- `test/hiraeth/ingestion/cover_cache_root_test.exs` locks the cache safety boundary by rejecting symlinks.
- `scripts/browser_qa.sh` runs the cover warmup gate before browser checks.
- The browser gate short-circuits with `cover_cache_warmup=fail` when `mix hiraeth.cache_covers` reports `cover_cache_failed != 0`.

## ANTI-PATTERNS

- Deleting, cleaning, modifying, truncating, moving, or regenerating `priv/static/covers/cache/*`.
- Treating ignored runtime covers as disposable build output.
- Replacing an existing cached file during cleanup, fixture setup, formatting, or QA.
- Running cache-writing commands against the root cache without the sandbox guard.
- Adding runtime PNG or JPEG files to version control.

The never-clean rule is enforced by `scripts/qa/cover_cache_sandbox.sh`, `mix hiraeth.cache_covers`, and the sandbox script's allow and deny list.
