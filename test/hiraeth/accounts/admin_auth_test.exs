defmodule Hiraeth.Accounts.AdminAuthTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Accounts
  alias Hiraeth.Accounts.{AdminSessionToken, AdminUser}
  alias Hiraeth.Ingestion.ProviderSource
  alias HiraethWeb.Router

  require Ash.Query

  describe "admin invites" do
    test "invite token creates an admin session exactly once before expiry" do
      {:ok, invite} =
        Accounts.invite_admin(%{
          email: "owner@example.test",
          role: "owner",
          expires_in: "15m",
          audit_metadata: %{"source" => "test"}
        })

      assert invite.admin_user.email == "owner@example.test"
      assert invite.admin_user.role == "owner"
      assert invite.raw_token =~ ~r/^[A-Za-z0-9_-]+$/
      assert invite.token.purpose == "invite"
      assert invite.token.token_hash == Accounts.sha256_token(invite.raw_token)
      refute invite.token.consumed_at

      assert {:ok, session} = Accounts.consume_invite(invite.raw_token)
      assert session.admin_user.email == "owner@example.test"
      assert session.raw_session_token =~ ~r/^[A-Za-z0-9_-]+$/
      assert session.session_token.purpose == "session"

      consumed = Ash.get!(AdminSessionToken, invite.token.id, authorize?: false)
      assert consumed.consumed_at

      assert {:error, :consumed} = Accounts.consume_invite(invite.raw_token)
    end

    test "expired invites are denied and cannot create sessions" do
      {:ok, invite} =
        Accounts.invite_admin(%{
          email: "expired@example.test",
          role: "owner",
          expires_in: "-1m"
        })

      assert {:error, :expired} = Accounts.consume_invite(invite.raw_token)
    end

    test "concurrent invite consumption creates exactly one admin session" do
      {:ok, invite} =
        Accounts.invite_admin(%{
          email: "race-owner@example.test",
          role: "owner",
          expires_in: "15m"
        })

      results =
        1..40
        |> Task.async_stream(fn _ -> Accounts.consume_invite(invite.raw_token) end,
          max_concurrency: 40,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      successes = Enum.filter(results, &match?({:ok, _session}, &1))
      consumed_errors = Enum.filter(results, &match?({:error, :consumed}, &1))

      assert length(successes) == 1
      assert length(consumed_errors) == 39

      session_tokens =
        AdminSessionToken
        |> Ash.Query.filter(admin_user_id == ^invite.admin_user.id and purpose == "session")
        |> Ash.read!(actor: Accounts.system_actor())

      assert length(session_tokens) == 1
    end

    test "disabled admins cannot authenticate with an otherwise valid session" do
      {:ok, invite} =
        Accounts.invite_admin(%{
          email: "disabled@example.test",
          role: "owner",
          expires_in: "15m"
        })

      {:ok, session} = Accounts.consume_invite(invite.raw_token)

      session.admin_user
      |> Ash.Changeset.for_update(:disable, %{})
      |> Ash.update!(actor: Accounts.system_actor())

      assert {:error, :disabled} = Accounts.admin_from_session_token(session.raw_session_token)
    end
  end

  describe "admin ingestion actor boundary" do
    test "owners and admins can mutate ingestion while viewer/non-admin actors cannot" do
      {:ok, owner_invite} =
        Accounts.invite_admin(%{
          email: "owner-boundary@example.test",
          role: "owner",
          expires_in: "15m"
        })

      {:ok, viewer_invite} =
        Accounts.invite_admin(%{
          email: "viewer-boundary@example.test",
          role: "viewer",
          expires_in: "15m"
        })

      {:ok, owner_session} = Accounts.consume_invite(owner_invite.raw_token)
      {:ok, viewer_session} = Accounts.consume_invite(viewer_invite.raw_token)

      owner_actor = Accounts.ingestion_actor(owner_session.admin_user)
      viewer_actor = Accounts.ingestion_actor(viewer_session.admin_user)

      assert owner_actor.catalog_write? == true
      assert viewer_actor.catalog_write? == false

      assert %ProviderSource{} = create_provider_source!(owner_actor, "owner-source")

      assert {:error, forbidden_error} =
               ProviderSource
               |> Ash.Changeset.for_create(:create, provider_source_attrs("viewer-source"))
               |> Ash.create(actor: viewer_actor)

      assert Exception.message(forbidden_error) =~ "forbidden"
    end
  end

  test "accounts domain and router expose no public registration profile or social account surface" do
    account_resources = Ash.Domain.Info.resources(Accounts)

    assert MapSet.new(account_resources) == MapSet.new([AdminUser, AdminSessionToken])

    account_resource_names = Enum.map(account_resources, &inspect/1)
    refute Enum.any?(account_resource_names, &String.contains?(&1, "Registration"))
    refute Enum.any?(account_resource_names, &String.contains?(&1, "Profile"))
    refute Enum.any?(account_resource_names, &String.contains?(&1, "Social"))
    refute Enum.any?(account_resource_names, &String.contains?(&1, "OAuth"))

    paths = Router.__routes__() |> Enum.map(& &1.path)

    refute Enum.any?(paths, &String.contains?(&1, "/register"))
    refute Enum.any?(paths, &String.contains?(&1, "/profile"))
    refute Enum.any?(paths, &String.contains?(&1, "/users"))
    refute Enum.any?(paths, &String.contains?(&1, "/oauth"))
    refute Enum.any?(paths, &String.contains?(&1, "/social"))
    refute Enum.any?(paths, &String.contains?(&1, "/account"))
  end

  defp create_provider_source!(actor, key) do
    ProviderSource
    |> Ash.Changeset.for_create(:create, provider_source_attrs(key))
    |> Ash.create!(actor: actor)
  end

  defp provider_source_attrs(key) do
    %{
      stable_source_key: "publisher:#{key}:manifest",
      provider_name: "#{key} Publisher",
      source_kind: "publisher",
      ingestion_mode: "manifest"
    }
  end
end
