defmodule HiraethWeb.ContributorsLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
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
      <div id="contributors-shell" class="archive-wash space-y-10">
        <div class="border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
          <span class="font-mono text-xs uppercase tracking-wider text-stone-500">
            Role-aware directory
          </span>
          <h1 class="mt-1 font-serif text-3xl font-medium tracking-tight text-stone-900 dark:text-stone-100">
            {contributor_index_title(@role)}
          </h1>
          <p class="mt-2 max-w-2xl text-sm text-stone-600 dark:text-stone-400">
            Authors, translators, and other sourced contributors represented in the public catalog.
          </p>
          <nav class="mt-4 flex flex-wrap gap-2 text-xs font-mono uppercase tracking-wider">
            <.link navigate={~p"/contributors"} class={role_link_class(@role, nil)}>All</.link>
            <.link navigate={~p"/contributors?role=author"} class={role_link_class(@role, "author")}>
              Authors
            </.link>
            <.link
              navigate={~p"/contributors?role=translator"}
              class={role_link_class(@role, "translator")}
            >
              Translators
            </.link>
          </nav>
        </div>

        <div id="contributors-grid" phx-update="stream" class="grid grid-cols-1 gap-5 md:grid-cols-2">
          <article
            :for={{dom_id, contributor} <- @streams.contributors}
            id={dom_id}
            class="hiraeth-surface rounded-sm border border-[#E7E2D8] bg-[#F5F2EB]/70 p-6 dark:border-[#2E2A27] dark:bg-[#1C1917]/70"
          >
            <div class="space-y-3">
              <div class="flex flex-wrap gap-2" aria-label="Contributor roles">
                <span
                  :for={role <- contributor.roles}
                  class="rounded-full border border-[#D8CFC0] px-2 py-1 font-mono text-[10px] uppercase tracking-wider text-stone-600 dark:border-[#2E2A27] dark:text-stone-300"
                >
                  {role}
                </span>
              </div>
              <h2 class="font-serif text-2xl font-medium text-[#8C2D19] dark:text-[#E05A47]">
                <.link navigate={~p"/contributors/#{contributor.slug}"} class="hover:underline">
                  {contributor.name}
                </.link>
              </h2>
              <p class="font-mono text-xs text-stone-500">
                {contributor.books_count} sourced books
              </p>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="contributor-detail-shell" class="archive-wash space-y-10">
        <%= if @contributor do %>
          <div class="space-y-3 border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
            <.link
              navigate={~p"/contributors"}
              class="font-mono text-xs uppercase tracking-wider text-stone-500 hover:underline"
            >← Contributors</.link>
            <div id="contributor-roles" class="flex flex-wrap gap-2">
              <span
                :for={role <- @contributor.roles}
                class="rounded-full border border-[#D8CFC0] px-2 py-1 font-mono text-[10px] uppercase tracking-wider text-stone-600 dark:border-[#2E2A27] dark:text-stone-300"
              >
                {role}
              </span>
            </div>
            <h1
              id="contributor-title"
              class="font-serif text-4xl font-medium tracking-tight text-stone-900 dark:text-stone-100"
            >
              {@contributor.name}
            </h1>
          </div>

          <section id="contributor-books" class="space-y-6">
            <h2 class="font-serif text-2xl font-medium">Related sourced books</h2>
            <div
              id="contributor-books-stream"
              phx-update="stream"
              class="grid grid-cols-2 gap-6 sm:grid-cols-3 md:grid-cols-4"
            >
              <CatalogComponents.edition_card
                :for={{dom_id, book} <- @streams.contributor_books}
                dom_id={dom_id}
                edition={book}
                id_prefix="contributor-book"
              />
            </div>
          </section>
        <% else %>
          <CatalogComponents.empty_state
            id="contributor-not-found"
            title="No contributor matches"
            message="No sourced contributor matches that slug. Choose another name from the contributor directory."
            action_label="Back to contributors"
            action_path="/contributors"
          />
        <% end %>
      </div>
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

  defp role_link_class(current, role) do
    base = "rounded-full border px-3 py-1 transition-colors"

    if current == role do
      base <> " border-[#8C2D19] bg-[#8C2D19] text-white dark:border-[#E05A47] dark:bg-[#E05A47]"
    else
      base <>
        " border-[#D8CFC0] text-stone-600 hover:border-[#8C2D19] hover:text-[#8C2D19] dark:border-[#2E2A27] dark:text-stone-300"
    end
  end
end
