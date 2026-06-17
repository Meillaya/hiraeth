defmodule HiraethWeb.ContributorsLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.ContributorsLive.Components
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Contributors")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Contributor")
     |> assign_contributor(PublicCatalog.contributor(slug))}
  end

  def handle_params(params, _uri, socket) do
    role = Map.get(params, "role")

    {:noreply,
     socket
     |> assign(:page_title, contributor_index_title(role))
     |> assign(:role, normalize_role(role))
     |> stream(:contributors, PublicCatalog.contributors(role),
       reset: true,
       dom_id: &"contributor-#{&1.slug}"
     )}
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <Components.index role={@role} streams={@streams} />
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <Components.show contributor={@contributor} streams={@streams} />
    </Layouts.app>
    """
  end

  defp assign_contributor(socket, nil) do
    socket
    |> assign(:contributor, nil)
    |> stream(:contributor_books, [], reset: true)
  end

  defp assign_contributor(socket, contributor) do
    socket
    |> assign(:contributor, contributor)
    |> stream(:contributor_books, contributor.books, reset: true)
  end

  defp contributor_index_title("author"), do: "Authors"
  defp contributor_index_title("translator"), do: "Translators"
  defp contributor_index_title(_role), do: "Contributors"

  defp normalize_role(role) when role in ["author", "translator"], do: role
  defp normalize_role(_role), do: nil
end
