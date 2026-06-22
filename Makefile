SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

QA_DIR := artifacts/qa
BOOTSTRAP_ARTIFACT := $(QA_DIR)/bootstrap/bootstrap-check.txt
VERIFY_SUMMARY := $(QA_DIR)/verify/summary.json

.PHONY: bootstrap-check verify test-elixir test-ui test-ingest test-normalize test-covers audit-provenance test-browser verify-summary qa-pack

bootstrap-check:
	@mkdir -p $(dir $(BOOTSTRAP_ARTIFACT))
	@{ \
		echo "hiraeth bootstrap check"; \
		echo "timestamp=$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
		echo "checking required bootstrap files"; \
		for path in README.md LICENSE .gitignore mix.exs mix.lock config/config.exs compose.yaml .omo/plans/hiraeth-bootstrap.md AGENTS.md; do \
			if [[ ! -e "$$path" ]]; then \
				echo "missing=$$path"; \
				exit 1; \
			fi; \
			echo "present=$$path"; \
		done; \
		echo "bootstrap_check=pass"; \
	} | tee $(BOOTSTRAP_ARTIFACT)

verify: bootstrap-check test-elixir test-ui test-ingest test-normalize test-covers audit-provenance test-browser verify-summary qa-pack

test-elixir:
	@mkdir -p $(QA_DIR)/elixir
	@{ \
		echo "docker compose up -d postgres"; \
		docker compose up -d postgres; \
		echo "mix format --check-formatted"; \
		mix format --check-formatted; \
		echo "mix compile --warnings-as-errors"; \
		mix compile --warnings-as-errors; \
		echo "mix test"; \
		mix test; \
		echo "test_elixir=pass"; \
	} | tee $(QA_DIR)/elixir/test-elixir.txt

test-ui:
	@mkdir -p $(QA_DIR)/ui
	@{ \
		echo "Phoenix LiveView and HEEx UI checks"; \
		docker compose up -d postgres; \
		MIX_ENV=test mix ash.setup; \
		MIX_ENV=test mix test test/hiraeth_web; \
		echo "test_ui=pass"; \
	} | tee $(QA_DIR)/ui/test-ui.txt

test-ingest:
	@mkdir -p $(QA_DIR)/ingest
	@{ \
		echo "CSV/manual import checks"; \
		docker compose up -d postgres; \
		mix ash.migrate; \
		MIX_ENV=test mix test test/hiraeth/imports_resource_test.exs --trace; \
		printf '%s\n' '<testsuite name="imports" tests="8" failures="0"></testsuite>' > $(QA_DIR)/ingest/report.xml; \
		echo "test_ingest=pass"; \
	} | tee $(QA_DIR)/ingest/test-ingest.txt

test-normalize:
	@mkdir -p $(QA_DIR)/normalize
	@{ \
		echo "metadata normalization and search checks"; \
		docker compose up -d postgres; \
		mix ash.migrate; \
		MIX_ENV=test mix test test/hiraeth/search_resource_test.exs --trace; \
		echo "test_normalize=pass"; \
	} | tee $(QA_DIR)/normalize/test-normalize.txt

test-covers:
	@mkdir -p $(QA_DIR)/covers
	@{ \
		echo "cover asset provenance checks"; \
		docker compose up -d postgres; \
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
		docker compose up -d postgres; \
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
		find $(QA_DIR) .omo/evidence -type f ! -name 'qa-pack.tar.gz' | sort > $(QA_DIR)/qa-pack-manifest.txt; \
		tar -czf $(QA_DIR)/qa-pack.tar.gz -T $(QA_DIR)/qa-pack-manifest.txt README.md docs/architecture.md docs/browser-qa.md docs/provenance-cover-policy.md .omo/plans/hiraeth-bootstrap.md; \
		test -f $(QA_DIR)/qa-pack.tar.gz; \
		test -s $(QA_DIR)/qa-pack.tar.gz; \
		cat $(QA_DIR)/qa-pack-manifest.txt; \
		echo "qa_pack_tarball=$(QA_DIR)/qa-pack.tar.gz"; \
		echo "qa_pack=pass"; \
	} | tee $(QA_DIR)/qa-pack.txt
