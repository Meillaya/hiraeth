defmodule Hiraeth.Ingestion.RecordCandidate do
  @diff_classifications ~w(new changed unchanged removed invalid destructive)
  @quarantine_statuses ~w(clear quarantined)
  @review_decisions ~w(pending_review approved rejected ignored)
  @quarantined_diff_classifications ~w(removed invalid destructive)

  use Ash.Resource,
    domain: Hiraeth.Ingestion,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "record_candidates"
    repo Hiraeth.Repo

    custom_indexes do
      index :provider_run_id, name: "record_candidates_provider_run_id_index"
      index :source_snapshot_id, name: "record_candidates_source_snapshot_id_index"
      index :review_status, name: "record_candidates_review_status_index"
      index :record_type, name: "record_candidates_record_type_index"
      index :diff_classification, name: "record_candidates_diff_classification_index"
      index :quarantine_status, name: "record_candidates_quarantine_status_index"
      index :review_decision, name: "record_candidates_review_decision_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :candidate_identity, :string, allow_nil?: false, public?: true
    attribute :record_type, :string, allow_nil?: false, public?: true
    attribute :review_status, :string, allow_nil?: false, default: "needs_review", public?: true
    attribute :source_uri, :string, allow_nil?: false, public?: true
    attribute :fingerprint, :string, allow_nil?: false, public?: true
    attribute :previous_fingerprint, :string, public?: true
    attribute :diff_classification, :string, allow_nil?: false, default: "new", public?: true
    attribute :quarantine_status, :string, allow_nil?: false, default: "clear", public?: true

    attribute :review_decision, :string,
      allow_nil?: false,
      default: "pending_review",
      public?: true

    attribute :raw_metadata, :map do
      allow_nil? false
      public? false
    end

    attribute :normalized_metadata, :map do
      allow_nil? false
      public? true
    end

    attribute :validation_errors, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :validation_findings, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :reviewer_note, :string, public?: true
    attribute :review_actor_id, :string, public?: true
    attribute :review_actor_email, :string, public?: true
    attribute :reviewed_at, :utc_datetime, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :provider_run, Hiraeth.Ingestion.ProviderRun do
      allow_nil? false
      public? true
    end

    belongs_to :source_snapshot, Hiraeth.Ingestion.SourceSnapshot do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_record_candidate, [:provider_run_id, :candidate_identity]
  end

  validations do
    validate one_of(:record_type, ["work", "edition", "contributor", "cover", "series"])
    validate one_of(:review_status, ["needs_review", "accepted", "rejected", "quarantined"])
    validate one_of(:diff_classification, @diff_classifications)
    validate one_of(:quarantine_status, @quarantine_statuses)
    validate one_of(:review_decision, @review_decisions)
  end

  actions do
    defaults [:read, :destroy]

    read :approved_for_apply do
      filter expr(review_decision == "approved" and quarantine_status == "clear")
    end

    create :create do
      primary? true

      accept [
        :provider_run_id,
        :source_snapshot_id,
        :candidate_identity,
        :record_type,
        :review_status,
        :source_uri,
        :previous_fingerprint,
        :diff_classification,
        :quarantine_status,
        :review_decision,
        :raw_metadata,
        :normalized_metadata,
        :validation_errors,
        :validation_findings,
        :reviewer_note,
        :review_actor_id,
        :review_actor_email,
        :reviewed_at
      ]

      validate fn changeset, _context ->
        validate_candidate_payloads(changeset)
      end

      change fn changeset, _context ->
        changeset
        |> set_fingerprint()
        |> default_quarantine_decision()
      end
    end

    update :update do
      require_atomic? false

      accept [
        :review_status,
        :normalized_metadata,
        :validation_errors,
        :validation_findings,
        :quarantine_status,
        :review_decision,
        :reviewer_note,
        :review_actor_id,
        :review_actor_email,
        :reviewed_at
      ]

      validate fn changeset, _context ->
        validate_candidate_payloads(changeset)
      end

      change fn changeset, _context ->
        set_fingerprint(changeset)
      end
    end

    update :accept do
      accept [:reviewer_note, :review_actor_id, :review_actor_email, :reviewed_at]
      change set_attribute(:review_status, "accepted")
      change set_attribute(:review_decision, "approved")
      change set_attribute(:quarantine_status, "clear")
    end

    update :reject do
      accept [:reviewer_note, :review_actor_id, :review_actor_email, :reviewed_at]
      change set_attribute(:review_status, "rejected")
      change set_attribute(:review_decision, "rejected")
    end

    update :quarantine do
      accept [
        :reviewer_note,
        :validation_errors,
        :review_actor_id,
        :review_actor_email,
        :reviewed_at
      ]

      change set_attribute(:review_status, "quarantined")
      change set_attribute(:review_decision, "pending_review")
      change set_attribute(:quarantine_status, "quarantined")
    end

    update :approve_for_apply do
      accept [:reviewer_note, :review_actor_id, :review_actor_email, :reviewed_at]
      change set_attribute(:review_status, "accepted")
      change set_attribute(:review_decision, "approved")
      change set_attribute(:quarantine_status, "clear")
    end

    update :ignore do
      accept [:reviewer_note, :review_actor_id, :review_actor_email, :reviewed_at]
      change set_attribute(:review_status, "rejected")
      change set_attribute(:review_decision, "ignored")
    end
  end

  policies do
    policy action_type(:read) do
      description "Record candidates are readable for ingestion review."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only trusted catalog write actors can manage record candidates."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end

  def fingerprint_for!(candidate_payload) when is_map(candidate_payload) do
    candidate_payload
    |> canonical_payload()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&"sha256:#{&1}")
  end

  def fingerprint_for!(_candidate_payload) do
    raise ArgumentError, "candidate payload must be a map"
  end

  def destructive_diff?(diff_classification) do
    diff_classification in @quarantined_diff_classifications
  end

  defp set_fingerprint(changeset) do
    case Ash.Changeset.get_attribute(changeset, :normalized_metadata) do
      payload when is_map(payload) ->
        Ash.Changeset.force_change_attribute(changeset, :fingerprint, fingerprint_for!(payload))

      _ ->
        changeset
    end
  end

  defp default_quarantine_decision(changeset) do
    diff_classification = Ash.Changeset.get_attribute(changeset, :diff_classification)

    if destructive_diff?(diff_classification) do
      changeset
      |> Ash.Changeset.force_change_attribute(:quarantine_status, "quarantined")
      |> Ash.Changeset.force_change_attribute(:review_decision, "pending_review")
      |> Ash.Changeset.force_change_attribute(:review_status, "quarantined")
    else
      changeset
    end
  end

  defp validate_candidate_payloads(changeset) do
    with :ok <- validate_map_attribute(changeset, :raw_metadata),
         :ok <- validate_map_attribute(changeset, :normalized_metadata) do
      :ok
    end
  end

  defp validate_map_attribute(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      value when is_map(value) ->
        :ok

      _ ->
        {:error, field: attribute, message: "must be a map candidate payload"}
    end
  end

  defp canonical_payload(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> [to_string(key), canonical_payload(value)] end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp canonical_payload(list) when is_list(list), do: Enum.map(list, &canonical_payload/1)
  defp canonical_payload(value), do: value
end
