defmodule Hiraeth.Repo.Migrations.AddRecordCandidateDiffQuarantineFields do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE record_candidates
      ADD COLUMN IF NOT EXISTS fingerprint text NOT NULL DEFAULT 'sha256:legacy-uncomputed',
      ADD COLUMN IF NOT EXISTS previous_fingerprint text,
      ADD COLUMN IF NOT EXISTS diff_classification text NOT NULL DEFAULT 'new',
      ADD COLUMN IF NOT EXISTS quarantine_status text NOT NULL DEFAULT 'clear',
      ADD COLUMN IF NOT EXISTS review_decision text NOT NULL DEFAULT 'pending_review',
      ADD COLUMN IF NOT EXISTS validation_findings jsonb[] NOT NULL DEFAULT ARRAY[]::jsonb[]
    """

    execute """
    CREATE INDEX IF NOT EXISTS record_candidates_diff_classification_index
    ON record_candidates (diff_classification)
    """

    execute """
    CREATE INDEX IF NOT EXISTS record_candidates_quarantine_status_index
    ON record_candidates (quarantine_status)
    """

    execute """
    CREATE INDEX IF NOT EXISTS record_candidates_review_decision_index
    ON record_candidates (review_decision)
    """

    add_constraint_if_missing(
      "record_candidates_diff_classification_check",
      "diff_classification IN ('new', 'changed', 'unchanged', 'removed', 'invalid', 'destructive')"
    )

    add_constraint_if_missing(
      "record_candidates_quarantine_status_check",
      "quarantine_status IN ('clear', 'quarantined')"
    )

    add_constraint_if_missing(
      "record_candidates_review_decision_check",
      "review_decision IN ('pending_review', 'approved', 'rejected', 'ignored')"
    )
  end

  def down do
    execute "ALTER TABLE record_candidates DROP CONSTRAINT IF EXISTS record_candidates_review_decision_check"

    execute "ALTER TABLE record_candidates DROP CONSTRAINT IF EXISTS record_candidates_quarantine_status_check"

    execute "ALTER TABLE record_candidates DROP CONSTRAINT IF EXISTS record_candidates_diff_classification_check"

    execute "DROP INDEX IF EXISTS record_candidates_review_decision_index"
    execute "DROP INDEX IF EXISTS record_candidates_quarantine_status_index"
    execute "DROP INDEX IF EXISTS record_candidates_diff_classification_index"

    alter table(:record_candidates) do
      remove :validation_findings
      remove :review_decision
      remove :quarantine_status
      remove :diff_classification
      remove :previous_fingerprint
      remove :fingerprint
    end
  end

  defp add_constraint_if_missing(name, check_sql) do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = '#{name}'
          AND conrelid = 'record_candidates'::regclass
      ) THEN
        ALTER TABLE record_candidates
        ADD CONSTRAINT #{name} CHECK (#{check_sql});
      END IF;
    END
    $$;
    """
  end
end
