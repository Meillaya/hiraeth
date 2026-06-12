defmodule Hiraeth.AccountsAuthTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.Publisher

  test "seeded admin can sign in with AshAuthentication password strategy" do
    admin = seed_admin!("admin-auth@example.test", "correct horse battery staple")

    signed_in =
      User
      |> Ash.Query.for_read(:sign_in_with_password, %{
        email: admin.email,
        password: "correct horse battery staple"
      })
      |> Ash.read_one!()

    assert signed_in.email == admin.email
    assert signed_in.admin? == true
    assert is_binary(signed_in.__metadata__.token)
  end

  test "production runtime requires token signing secret instead of using a fallback" do
    config_text = File.read!(Path.expand("../../config/config.exs", __DIR__))
    runtime_text = File.read!(Path.expand("../../config/runtime.exs", __DIR__))
    dev_text = File.read!(Path.expand("../../config/dev.exs", __DIR__))
    test_text = File.read!(Path.expand("../../config/test.exs", __DIR__))

    refute config_text =~ "dev-test-token-signing-secret-change-before-production"
    assert runtime_text =~ "TOKEN_SIGNING_SECRET"
    assert runtime_text =~ "environment variable TOKEN_SIGNING_SECRET is missing"
    assert runtime_text =~ "config :hiraeth, :token_signing_secret, token_signing_secret"
    assert dev_text =~ "dev-test-token-signing-secret-change-before-production"
    assert test_text =~ "dev-test-token-signing-secret-change-before-production"
  end

  test "direct Ash catalog writes without an admin actor are forbidden" do
    changeset =
      Ash.Changeset.for_create(Publisher, :create, %{
        name: "Unauthorized Press",
        slug: "unauthorized-press"
      })

    assert {:error, error} = Ash.create(changeset)
    assert Exception.message(error) =~ "forbidden"
  end

  defp seed_admin!(email, password) do
    User
    |> Ash.Changeset.for_create(:seed_admin, %{
      email: email,
      password: password,
      display_name: "Seeded Admin"
    })
    |> Ash.create!(authorize?: false)
  end
end
