defmodule Mix.Tasks.Hiraeth.Admin.Invite do
  @moduledoc """
  Create a one-time admin invite token for local bootstrap.

  Usage:

      mix hiraeth.admin.invite --email EMAIL --role owner --expires-in 15m [--json]
  """

  use Mix.Task

  alias Hiraeth.Accounts

  @shortdoc "Create a one-time admin invite token"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [email: :string, role: :string, expires_in: :string, json: :boolean]
      )

    email = Keyword.get(opts, :email)
    role = Keyword.get(opts, :role, "owner")
    expires_in = Keyword.get(opts, :expires_in, "15m")

    if is_nil(email) or String.trim(email) == "" do
      Mix.shell().error(
        "Usage: mix hiraeth.admin.invite --email EMAIL [--role owner|admin|viewer] [--expires-in 15m] [--json]"
      )

      exit({:shutdown, 1})
    end

    case Accounts.invite_admin(%{
           email: email,
           role: role,
           expires_in: expires_in,
           created_by_email: "mix"
         }) do
      {:ok, invite} ->
        payload = payload(invite, expires_in)

        if Keyword.get(opts, :json, false) do
          Mix.shell().info(Jason.encode!(payload))
        else
          Mix.shell().info(
            "admin_invite email=#{payload.email} role=#{payload.role} expires_at=#{payload.expires_at}"
          )

          Mix.shell().info("admin_invite_url=#{payload.url}")
          Mix.shell().info("admin_invite_token=#{payload.token}")
        end

      {:error, reason} ->
        Mix.shell().error("admin invite failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp payload(invite, expires_in) do
    %{
      email: to_string(invite.admin_user.email),
      role: invite.admin_user.role,
      expires_in: expires_in,
      expires_at: DateTime.to_iso8601(invite.token.expires_at),
      token: invite.raw_token,
      url: "/admin/session/#{invite.raw_token}"
    }
  end
end
