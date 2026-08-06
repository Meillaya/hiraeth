SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

QA_DIR := artifacts/qa
VERIFY_SUMMARY := $(QA_DIR)/verify/summary.json
POSTGRES_READY := scripts/dev/ensure_postgres.sh start

.PHONY: verify test-fast test-full ci audit-provenance test-browser verify-summary qa-pack cleanup-policy gate plt gates\:measure db-backup db-restore-drill

verify: audit-provenance test-browser verify-summary qa-pack

# Fast blocking gate (Layer 0): wraps the `mix gate` alias.
# `make gates:measure` measures the full gate baseline; pass
# PERF_ARGS="--only fast" to measure just the fast blocking path.
gate:
	mix gate

plt:
	mix dialyzer --plt

gates\:measure:
	@mkdir -p $(QA_DIR)/perf
	@bash scripts/qa/perf/measure_gates.sh $(PERF_ARGS)

cleanup-policy:
	@echo "Cleanup policy: never delete, clean, modify, or regenerate priv/static/covers/cache/*"
	@test -f docs/cleanup-policy.md
	@bash -n scripts/qa/cover_cache_sandbox.sh

# Logical backup of the devenv/local database (custom format, non-empty check).
db-backup:
	@bash scripts/ops/db_backup.sh

# Restore drill into a NEW hiraeth_restore database (never the live DB).
db-restore-drill:
	@bash scripts/ops/db_restore_drill.sh

test-fast:
	mix test.fast

test-full:
	mix test.full

ci:
	mix ci

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
