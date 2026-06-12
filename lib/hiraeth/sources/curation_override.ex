defmodule Hiraeth.Sources.CurationOverride do
  use Ash.Resource,
    domain: Hiraeth.Sources,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "curation_overrides"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :entity_type, :string do
      allow_nil? false
      public? true
    end

    attribute :entity_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :field_name, :string do
      allow_nil? false
      public? true
    end

    attribute :curated_value, :string do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :source_record, Hiraeth.Sources.SourceRecord, allow_nil?: false
    belongs_to :reviewer, Hiraeth.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_entity_field, [:entity_type, :entity_id, :field_name]
  end

  actions do
    defaults [:read, :destroy]

    read :by_entity_field do
      argument :entity_type, :string, allow_nil?: false
      argument :entity_id, :uuid, allow_nil?: false
      argument :field_name, :string, allow_nil?: false

      filter expr(
               entity_type == ^arg(:entity_type) and entity_id == ^arg(:entity_id) and
                 field_name == ^arg(:field_name)
             )
    end

    create :create do
      primary? true

      accept [
        :entity_type,
        :entity_id,
        :field_name,
        :curated_value,
        :reason,
        :source_record_id
      ]

      change relate_actor(:reviewer, allow_nil?: true)
    end

    update :update do
      accept [:curated_value, :reason, :source_record_id]
      change relate_actor(:reviewer, allow_nil?: true)
    end
  end

  policies do
    policy action_type(:read) do
      description "Curation overrides are readable so public catalog resolution can apply reviewed values."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only authenticated admin reviewers can create or change curated field overrides."
      authorize_if actor_attribute_equals(:admin?, true)
    end
  end
end
