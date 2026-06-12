defmodule HiraethWeb.Admin.ActorProbeLive do
  @moduledoc false

  use HiraethWeb, :live_view

  alias Hiraeth.Catalog.Publisher

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    slug = "actor-probe-#{System.unique_integer([:positive])}"

    actor_probe_result =
      Publisher
      |> Ash.Changeset.for_create(:create, %{name: "Actor Probe", slug: slug})
      |> Ash.create(actor: current_user)
      |> case do
        {:ok, publisher} -> "actor propagated for #{publisher.slug}"
        {:error, error} -> "actor propagation failed: #{Exception.message(error)}"
      end

    {:ok, assign(socket, :actor_probe_result, actor_probe_result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <p id="actor-probe-result">{@actor_probe_result}</p>
    </Layouts.app>
    """
  end
end
