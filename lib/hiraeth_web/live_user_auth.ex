defmodule HiraethWeb.LiveUserAuth do
  @moduledoc """
  LiveView authentication hooks backed by AshAuthentication session assigns.
  """

  import Phoenix.Component
  use HiraethWeb, :verified_routes

  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_admin_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{admin?: true} ->
        {:cont, socket}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end
end
