defmodule Hiraeth.Ingestion.SourceSnapshot do
  @moduledoc """
  Retained source artifact metadata for replayable ingestion.

  Snapshot rows keep metadata and a private artifact pointer. Raw fetched bytes
  are retained on disk under the configured private retention root, never under
  public/static paths.
  """

  use Ash.Resource,
    domain: Hiraeth.Ingestion,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Hiraeth.Ingestion.SourceSnapshot.ArtifactStore

  @source_modes ["api", "scrape", "manifest", "manual"]

  postgres do
    table "source_snapshots"
    repo Hiraeth.Repo

    custom_indexes do
      index :provider, name: "source_snapshots_provider_index"
      index :provider_source_id, name: "source_snapshots_provider_source_id_index"
      index :provider_run_id, name: "source_snapshots_provider_run_id_index"
      index :source_url, name: "source_snapshots_source_url_index"
      index :source_uri, name: "source_snapshots_source_uri_index"
      index :checksum, name: "source_snapshots_checksum_index"
      index :content_checksum, name: "source_snapshots_content_checksum_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string, public?: true
    attribute :source_url, :string, public?: true
    attribute :checksum, :string, public?: true
    attribute :source_uri, :string, allow_nil?: false, public?: true
    attribute :content_checksum, :string, allow_nil?: false, public?: true
    attribute :fetched_at, :utc_datetime, allow_nil?: false, public?: true

    attribute :http_metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :http_status, :integer do
      constraints min: 100, max: 599
      public? true
    end

    attribute :content_type, :string, public?: true

    attribute :byte_size, :integer do
      constraints min: 0
      public? true
    end

    attribute :raw_payload, :map do
      allow_nil? false
      default %{}
      public? false
    end

    attribute :adapter_version, :string, public?: true
    attribute :source_mode, :string, public?: true
    attribute :artifact_path, :string, public?: true
    attribute :storage_ref, :string, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :provider_source, Hiraeth.Ingestion.ProviderSource do
      allow_nil? false
      public? true
    end

    belongs_to :provider_run, Hiraeth.Ingestion.ProviderRun do
      allow_nil? false
      public? true
    end

    has_many :record_candidates, Hiraeth.Ingestion.RecordCandidate
    has_many :ingestion_events, Hiraeth.Ingestion.IngestionEvent
  end

  identities do
    identity :unique_source_snapshot, [:provider_source_id, :source_uri, :content_checksum]
  end

  validations do
    validate one_of(:source_mode, @source_modes)
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :provider_source_id,
        :provider_run_id,
        :provider,
        :source_url,
        :checksum,
        :source_uri,
        :content_checksum,
        :fetched_at,
        :http_metadata,
        :http_status,
        :content_type,
        :byte_size,
        :raw_payload,
        :adapter_version,
        :source_mode,
        :artifact_path,
        :storage_ref
      ]

      change fn changeset, _context ->
        changeset
        |> validate_alias_conflicts()
        |> sync_alias(:source_url, :source_uri)
        |> sync_alias(:checksum, :content_checksum)
        |> sync_alias(:artifact_path, :storage_ref)
        |> ensure_raw_payload()
        |> sync_http_metadata()
        |> validate_artifact_paths()
      end
    end
  end

  policies do
    policy action_type(:read) do
      description "Source snapshots are readable for provenance review."
      authorize_if always()
    end

    policy action_type(:create) do
      description "Only trusted catalog write actors can append source snapshots."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end

    policy action_type([:update, :destroy]) do
      description "Source snapshots are immutable after capture."
      forbid_if always()
    end
  end

  def retain_artifact!(provider, source_url, payload, opts \\ [])
      when is_binary(provider) and is_binary(source_url) and is_binary(payload) do
    ArtifactStore.retain!(provider, source_url, payload, opts)
  end

  def checksum(payload) when is_binary(payload) do
    ArtifactStore.checksum(payload)
  end

  def load_payload!(snapshot_or_path, opts \\ []) do
    ArtifactStore.load!(snapshot_or_path, opts)
  end

  def private_artifact_path!(artifact_path, root \\ retention_root())
      when is_binary(artifact_path) do
    ArtifactStore.private_path!(artifact_path, root)
  end

  def validate_relative_artifact_path(artifact_path, root \\ retention_root())
      when is_binary(artifact_path) and is_binary(root) do
    ArtifactStore.validate_relative_path(artifact_path, root)
  end

  defp retention_root(opts \\ []) do
    ArtifactStore.retention_root(opts)
  end

  defp validate_alias_conflicts(changeset) do
    changeset
    |> validate_alias_pair(:source_url, :source_uri)
    |> validate_alias_pair(:checksum, :content_checksum)
    |> validate_alias_pair(:artifact_path, :storage_ref)
  end

  defp validate_alias_pair(changeset, canonical, legacy) do
    canonical_value = Ash.Changeset.get_attribute(changeset, canonical)
    legacy_value = Ash.Changeset.get_attribute(changeset, legacy)

    if present?(canonical_value) and present?(legacy_value) and canonical_value != legacy_value do
      Ash.Changeset.add_error(changeset,
        field: canonical,
        message: "#{canonical} and #{legacy} must match when both are provided"
      )
    else
      changeset
    end
  end

  defp sync_alias(changeset, canonical, legacy) do
    canonical_value = Ash.Changeset.get_attribute(changeset, canonical)
    legacy_value = Ash.Changeset.get_attribute(changeset, legacy)

    cond do
      present?(canonical_value) and not present?(legacy_value) ->
        Ash.Changeset.change_attribute(changeset, legacy, canonical_value)

      present?(legacy_value) and not present?(canonical_value) ->
        Ash.Changeset.change_attribute(changeset, canonical, legacy_value)

      true ->
        changeset
    end
  end

  defp ensure_raw_payload(changeset) do
    if present?(Ash.Changeset.get_attribute(changeset, :raw_payload)) do
      changeset
    else
      Ash.Changeset.change_attribute(changeset, :raw_payload, %{})
    end
  end

  defp sync_http_metadata(changeset) do
    metadata = Ash.Changeset.get_attribute(changeset, :http_metadata) || %{}

    changeset
    |> put_from_metadata(:http_status, metadata["status"] || metadata[:status])
    |> put_from_metadata(:content_type, content_type_from_metadata(metadata))
  end

  defp put_from_metadata(changeset, attribute, value) do
    if present?(value) and not present?(Ash.Changeset.get_attribute(changeset, attribute)) do
      Ash.Changeset.change_attribute(changeset, attribute, value)
    else
      changeset
    end
  end

  defp content_type_from_metadata(metadata) do
    headers = metadata["headers"] || metadata[:headers] || %{}
    content_type = headers["content-type"] || headers[:content_type] || headers["content_type"]

    case content_type do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp validate_artifact_paths(changeset) do
    changeset
    |> validate_artifact_path(:artifact_path)
    |> validate_artifact_path(:storage_ref)
  end

  defp validate_artifact_path(changeset, field) do
    artifact_path = Ash.Changeset.get_attribute(changeset, field)

    if present?(artifact_path) do
      case validate_relative_artifact_path(artifact_path) do
        {:ok, _full_path} ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: field,
            message: artifact_path_error(field, reason)
          )
      end
    else
      changeset
    end
  end

  defp artifact_path_error(:artifact_path, reason), do: reason

  defp artifact_path_error(:storage_ref, reason) do
    String.replace(reason, "artifact_path", "storage_ref")
  end

  defp present?(value), do: value not in [nil, ""]
end
