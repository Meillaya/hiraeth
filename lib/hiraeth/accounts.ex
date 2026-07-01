defmodule Hiraeth.Accounts do
  @moduledoc """
  Minimal admin-only authentication boundary for ingestion operations.

  Admins are bootstrapped with one-time invite tokens. Tokens are stored only as
  SHA-256 hashes; the raw token is returned exactly once to the caller that
  created or consumed it.
  """

  use Ash.Domain

  alias Hiraeth.Accounts.{AdminSessionToken, AdminUser}
  alias Hiraeth.Repo

  require Ash.Query

  @admin_roles MapSet.new(["owner", "admin"])
  @valid_roles MapSet.new(["owner", "admin", "viewer"])
  @system_actor %{id: "admin-auth-system", admin_auth_system?: true, catalog_write?: true}

  resources do
    resource AdminUser
    resource AdminSessionToken
  end

  def system_actor, do: @system_actor

  def invite_admin(attrs) when is_map(attrs) do
    with {:ok, email} <- normalize_email(Map.get(attrs, :email) || Map.get(attrs, "email")),
         {:ok, role} <-
           normalize_role(Map.get(attrs, :role) || Map.get(attrs, "role") || "owner"),
         {:ok, expires_at} <-
           expires_at(Map.get(attrs, :expires_in) || Map.get(attrs, "expires_in") || "15m") do
      admin_user = upsert_admin_user!(email, role)
      raw_token = generate_token()

      token =
        AdminSessionToken
        |> Ash.Changeset.for_create(:create_invite, %{
          admin_user_id: admin_user.id,
          token_hash: sha256_token(raw_token),
          expires_at: expires_at,
          created_by_email:
            Map.get(attrs, :created_by_email) || Map.get(attrs, "created_by_email"),
          audit_metadata:
            Map.get(attrs, :audit_metadata) || Map.get(attrs, "audit_metadata") || %{}
        })
        |> Ash.create!(actor: system_actor())

      {:ok, %{admin_user: admin_user, token: token, raw_token: raw_token}}
    end
  end

  def consume_invite(raw_token) when is_binary(raw_token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with {:ok, consumed} <- claim_invite_token(raw_token, now) do
        create_session_from_invite(consumed, now)
      end
    end)
    |> case do
      {:ok, {{:ok, _session} = result, notifications}} when is_list(notifications) ->
        Ash.Notifier.notify(notifications)
        result

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  def admin_from_session_token(raw_token) when is_binary(raw_token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, token} <- find_token(raw_token, "session"),
         :ok <- token_not_expired(token, now) do
      admin_user = Ash.get!(AdminUser, token.admin_user_id, actor: system_actor())

      if admin_user.disabled? do
        {:error, :disabled}
      else
        {:ok, admin_user}
      end
    end
  end

  def admin_from_session_token(_), do: {:error, :missing}

  def ingestion_actor(%AdminUser{} = admin_user) do
    admin_role? = MapSet.member?(@admin_roles, admin_user.role) and not admin_user.disabled?

    %{
      id: admin_user.id,
      email: admin_user.email,
      role: admin_user.role,
      admin?: admin_role?,
      owner?: admin_user.role == "owner" and not admin_user.disabled?,
      catalog_write?: admin_role?
    }
  end

  def admin_role?(%AdminUser{} = admin_user), do: ingestion_actor(admin_user).admin?
  def owner?(%AdminUser{} = admin_user), do: ingestion_actor(admin_user).owner?

  def sha256_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token)
    |> Base.encode16(case: :lower)
  end

  def parse_expires_in(value), do: expires_at(value)

  defp claim_invite_token(raw_token, now) do
    token_hash = sha256_token(raw_token)

    case Repo.query!(
           """
           UPDATE admin_session_tokens
           SET consumed_at = $1, updated_at = $1
           WHERE token_hash = $2
             AND purpose = 'invite'
             AND consumed_at IS NULL
             AND expires_at > $1
           RETURNING id
           """,
           [now, token_hash]
         ) do
      %{num_rows: 1, rows: [[id]]} ->
        {:ok, Ash.get!(AdminSessionToken, id, actor: system_actor())}

      %{num_rows: 0} ->
        invite_claim_error(raw_token, now)
    end
  end

  defp invite_claim_error(raw_token, now) do
    with {:ok, token} <- find_token(raw_token, "invite"),
         :ok <- token_not_expired(token, now),
         :ok <- token_not_consumed(token) do
      {:error, :consumed}
    end
  end

  defp create_session_from_invite(consumed, now) do
    admin_user = Ash.get!(AdminUser, consumed.admin_user_id, actor: system_actor())

    if admin_user.disabled? do
      {:error, :disabled}
    else
      raw_session_token = generate_token()

      {session_token, session_notifications} =
        AdminSessionToken
        |> Ash.Changeset.for_create(:create_session, %{
          admin_user_id: admin_user.id,
          token_hash: sha256_token(raw_session_token),
          expires_at: DateTime.add(now, 8, :hour),
          audit_metadata: %{"invite_token_id" => consumed.id}
        })
        |> Ash.create!(actor: system_actor(), return_notifications?: true)

      {admin_user, login_notifications} =
        admin_user
        |> touch_login!(now, return_notifications?: true)

      {{:ok,
        %{
          admin_user: admin_user,
          invite_token: consumed,
          session_token: session_token,
          raw_session_token: raw_session_token
        }}, session_notifications ++ login_notifications}
    end
  end

  defp upsert_admin_user!(email, role) do
    case find_admin_by_email(email) do
      {:ok, %AdminUser{} = admin_user} ->
        admin_user
        |> Ash.Changeset.for_update(:set_role, %{role: role})
        |> Ash.update!(actor: system_actor())

      {:error, :not_found} ->
        AdminUser
        |> Ash.Changeset.for_create(:create, %{email: email, role: role})
        |> Ash.create!(actor: system_actor())
    end
  end

  defp find_admin_by_email(email) do
    result =
      AdminUser
      |> Ash.Query.filter(email == ^email)
      |> Ash.read!(actor: system_actor())

    case result do
      [admin_user] -> {:ok, admin_user}
      [] -> {:error, :not_found}
    end
  end

  defp find_token(raw_token, purpose) do
    token_hash = sha256_token(raw_token)

    result =
      AdminSessionToken
      |> Ash.Query.filter(token_hash == ^token_hash and purpose == ^purpose)
      |> Ash.read!(actor: system_actor())

    case result do
      [token] -> {:ok, token}
      [] -> {:error, :not_found}
    end
  end

  defp token_not_expired(%{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp token_not_consumed(%{consumed_at: nil}), do: :ok
  defp token_not_consumed(_token), do: {:error, :consumed}

  defp touch_login!(admin_user, now, opts) do
    ash_opts = Keyword.merge([actor: system_actor()], opts)

    admin_user
    |> Ash.Changeset.for_update(:record_login, %{last_login_at: now})
    |> Ash.update!(ash_opts)
  end

  defp normalize_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    cond do
      email == "" -> {:error, :invalid_email}
      not String.contains?(email, "@") -> {:error, :invalid_email}
      true -> {:ok, email}
    end
  end

  defp normalize_email(_), do: {:error, :invalid_email}

  defp normalize_role(role) when is_binary(role) do
    role = role |> String.trim() |> String.downcase()

    if MapSet.member?(@valid_roles, role) do
      {:ok, role}
    else
      {:error, :invalid_role}
    end
  end

  defp normalize_role(_), do: {:error, :invalid_role}

  defp expires_at(value) when is_binary(value) do
    with [amount_text, unit] <-
           Regex.run(~r/^(-?\d+)([smhd])$/, String.trim(value), capture: :all_but_first),
         {amount, ""} <- Integer.parse(amount_text) do
      multiplier = %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}
      seconds = amount * Map.fetch!(multiplier, unit)
      {:ok, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(seconds, :second)}
    else
      _ -> {:error, :invalid_expires_in}
    end
  end

  defp expires_at(_), do: {:error, :invalid_expires_in}

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
