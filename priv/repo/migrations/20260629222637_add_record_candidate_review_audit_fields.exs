defmodule Hiraeth.Repo.Migrations.AddRecordCandidateReviewAuditFields do
  use Ecto.Migration

  def change do
    alter table(:record_candidates) do
      add :review_actor_id, :text
      add :review_actor_email, :text
      add :reviewed_at, :utc_datetime
    end

    create index(:record_candidates, [:review_actor_email],
             name: "record_candidates_review_actor_email_index"
           )
  end
end
