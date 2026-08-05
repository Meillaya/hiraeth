SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

QA_DIR := artifacts/qa
BOOTSTRAP_ARTIFACT := $(QA_DIR)/bootstrap/bootstrap-check.txt
VERIFY_SUMMARY := $(QA_DIR)/verify/summary.json
POSTGRES_READY := scripts/dev/ensure_postgres.sh start

.PHONY: bootstrap-check verify precommit-fast test-fast test-full ci test-elixir test-ui test-ingest test-normalize test-covers audit-provenance test-browser verify-summary qa-pack cleanup-policy gate recheck plt gates\:measure

bootstrap-check:
	@mkdir -p $(dir $(BOOTSTRAP_ARTIFACT))
	@{ \
		echo "hiraeth bootstrap check"; \
		echo "timestamp=$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
		echo "checking required bootstrap files"; \
		for path in README.md LICENSE .gitignore mix.exs mix.lock config/config.exs compose.yaml AGENTS.md; do \
			if [[ ! -e "$$path" ]]; then \
				echo "missing=$$path"; \
				exit 1; \
			fi; \
			echo "present=$$path"; \
		done; \
		echo "bootstrap_check=pass"; \
	} | tee $(BOOTSTRAP_ARTIFACT)

verify: bootstrap-check test-elixir test-ui test-ingest test-normalize test-covers audit-provenance test-browser verify-summary qa-pack

# Fast blocking gate (Layer 0): wraps the `mix gate` alias.
# `make gates:measure` measures the full gate baseline; pass
# PERF_ARGS="--only fast" to measure just the fast blocking path.
gate:
	mix gate

recheck:
	mix gate

plt:
	mix dialyzer --plt

gates\:measure:
	@mkdir -p $(QA_DIR)/perf
	@bash scripts/qa/perf/measure_gates.sh $(PERF_ARGS)

precommit-fast:
	mix precommit.fast

cleanup-policy:
	@echo "Cleanup policy: never delete, clean, modify, or regenerate priv/static/covers/cache/*"
	@test -f docs/cleanup-policy.md
	@bash -n scripts/qa/cover_cache_sandbox.sh

test-fast:
	mix test.fast

test-full:
	mix test.full

ci:
	mix ci

test-elixir:
	@mkdir -p $(QA_DIR)/elixir
	@{ \
		$(POSTGRES_READY); \
		echo "mix ci"; \
		mix ci; \
		echo "test_elixir=pass"; \
	} | tee $(QA_DIR)/elixir/test-elixir.txt

test-ui:
	@mkdir -p $(QA_DIR)/ui
	@{ \
		echo "Phoenix LiveView and HEEx UI checks"; \
		$(POSTGRES_READY); \
		MIX_ENV=test mix ash.setup; \
		MIX_ENV=test mix test test/hiraeth_web; \
		echo "test_ui=pass"; \
	} | tee $(QA_DIR)/ui/test-ui.txt

test-ingest:
	@mkdir -p $(QA_DIR)/ingest
	@{ \
		echo "CSV/manual import checks"; \
		$(POSTGRES_READY); \
		mix ash.migrate; \
		MIX_ENV=test mix test test/hiraeth/imports_resource_test.exs --trace; \
		echo "test_ingest=pass"; \
	} | tee $(QA_DIR)/ingest/test-ingest.txt

test-normalize:
	@mkdir -p $(QA_DIR)/normalize
	@{ \
		echo "metadata normalization and search checks"; \
		$(POSTGRES_READY); \
		mix ash.migrate; \
		MIX_ENV=test mix test test/hiraeth/search_resource_test.exs --trace; \
		echo "test_normalize=pass"; \
	} | tee $(QA_DIR)/normalize/test-normalize.txt

test-covers:
	@mkdir -p $(QA_DIR)/covers
	@{ \
		echo "cover asset provenance checks"; \
		$(POSTGRES_READY); \
		mix ash.migrate; \
		MIX_ENV=test mix test test/hiraeth/covers_resource_test.exs --trace; \
		test -f $(QA_DIR)/covers/provenance-audit.json; \
		grep -q '"invalid_public_covers": \[\]' $(QA_DIR)/covers/provenance-audit.json; \
		echo "test_covers=pass"; \
	} | tee $(QA_DIR)/covers/test-covers.txt

audit-provenance:
	@mkdir -p $(QA_DIR)/provenance
	@{ \
		echo "metadata provenance audit"; \
		$(POSTGRES_READY); \
		mix ecto.drop --force || true; \
		mix ecto.create; \
		mix ash.migrate; \
		mix hiraeth.audit_provenance --seed --output-dir $(QA_DIR)/provenance; \
		test -f $(QA_DIR)/provenance/source-ledger.csv; \
		test -f $(QA_DIR)/provenance/takedown-audit.csv; \
		grep -q 'entity,field,value_hash,source_record_id,source_uri,provider,source_type,license_or_rights_basis,import_run_id' $(QA_DIR)/provenance/source-ledger.csv; \
		grep -q '"missing_provenance": \[\]' $(QA_DIR)/provenance/audit-provenance.json; \
		grep -q '"source_ledger_missing": \[\]' $(QA_DIR)/provenance/audit-provenance.json; \
		grep -q '"invalid_public_covers": \[\]' $(QA_DIR)/provenance/audit-provenance.json; \
		grep -q '"long_copied_text": \[\]' $(QA_DIR)/provenance/audit-provenance.json; \
		echo "audit_provenance=pass"; \
	} | tee $(QA_DIR)/provenance/audit-provenance.txt

test-browser:
	@mkdir -p $(QA_DIR)/browser
	@scripts/browser_qa.sh

verify-summary:
	@mkdir -p $(QA_DIR)/verify
	@scripts/verify_summary.sh
	@test -f $(VERIFY_SUMMARY)
	@cat $(VERIFY_SUMMARY) | tee $(QA_DIR)/verify/verify-summary.txt

qa-pack:
	@mkdir -p $(QA_DIR)
	@{ \
		echo "qa pack summary"; \
		find $(QA_DIR) -type f ! -name 'qa-pack.tar.gz' | sort > $(QA_DIR)/qa-pack-manifest.txt; \
		tar -czf $(QA_DIR)/qa-pack.tar.gz -T $(QA_DIR)/qa-pack-manifest.txt README.md docs/architecture.md docs/browser-qa.md docs/cleanup-policy.md docs/contracts.md docs/history/worklog-2026-06.md docs/production-operations.md docs/production-readiness.md docs/provenance-cover-policy.md; \
		test -f $(QA_DIR)/qa-pack.tar.gz; \
		test -s $(QA_DIR)/qa-pack.tar.gz; \
		cat $(QA_DIR)/qa-pack-manifest.txt; \
		echo "qa_pack_tarball=$(QA_DIR)/qa-pack.tar.gz"; \
		echo "qa_pack=pass"; \
	} | tee $(QA_DIR)/qa-pack.txt
