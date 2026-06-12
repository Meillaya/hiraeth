defmodule HiraethWeb.Admin.CoversLive do
  use HiraethWeb, :live_view

  alias AshPhoenix.Form
  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Cover Governance")
     |> assign(:edition_options, edition_options(actor))
     |> assign_cover_form(actor)
     |> stream(:cover_assignments, cover_assignments(actor))}
  end

  @impl true
  def handle_event("validate_cover", %{"cover_assignment" => params}, socket) do
    {:noreply,
     assign(socket, :cover_form, Form.validate(socket.assigns.cover_form, cover_params(params)))}
  end

  def handle_event("assign_cover", %{"cover_assignment" => params}, socket) do
    actor = socket.assigns.current_user

    case Form.submit(socket.assigns.cover_form, params: cover_params(params)) do
      {:ok, cover_asset} ->
        assignment =
          CoverAssignment
          |> Ash.Changeset.for_create(:create, %{
            edition_id: params["edition_id"],
            cover_asset_id: cover_asset.id,
            position: 1,
            visible?: true
          })
          |> Ash.create!(actor: actor)
          |> Ash.load!([:cover_asset, :edition], actor: actor)

        {:noreply,
         socket
         |> put_flash(:info, "Cover assigned")
         |> assign_cover_form(actor)
         |> stream_insert(:cover_assignments, assignment)}

      {:error, form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Cover could not be assigned")
         |> assign(:cover_form, form)}
    end
  end

  def handle_event("hide_cover", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    assignment =
      CoverAssignment
      |> Ash.get!(id, actor: actor)
      |> Ash.load!(:cover_asset, actor: actor)

    assignment
    |> Ash.Changeset.for_update(:update, %{visible?: false})
    |> Ash.update!(actor: actor)

    assignment.cover_asset
    |> Ash.Changeset.for_update(:update, %{takedown_state: "hidden"})
    |> Ash.update!(actor: actor)

    updated =
      assignment |> Ash.reload!(actor: actor) |> Ash.load!([:cover_asset, :edition], actor: actor)

    {:noreply,
     socket
     |> put_flash(:info, "Cover hidden for takedown")
     |> stream_insert(:cover_assignments, updated)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-cover-governance" class="space-y-8">
        <div class="border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
          <p class="font-mono text-xs uppercase tracking-wider text-stone-500">Cover governance</p>
          <h1 class="mt-1 font-serif text-3xl font-medium text-stone-900 dark:text-stone-100">
            Cover governance
          </h1>
          <p class="mt-2 text-sm text-stone-700 dark:text-stone-300">
            Protected AshPhoenix create/update workspace for cover governance. Assign link-only cover assets and hide covers for takedown through Ash-backed admin actions.
          </p>
        </div>

        <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
          <h2 class="font-serif text-xl font-semibold">Assign public cover</h2>
          <.form
            for={@cover_form}
            id="cover-assignment-form"
            data-admin-resource-form="admin-resource-form"
            phx-change="validate_cover"
            phx-submit="assign_cover"
            class="mt-5 grid gap-4 md:grid-cols-2"
          >
            <.input
              field={@cover_form[:edition_id]}
              type="select"
              label="Edition"
              options={@edition_options}
              required
            />
            <.input field={@cover_form[:source_url]} label="Source URL" required />
            <.input field={@cover_form[:provider]} label="Provider" required />
            <.input field={@cover_form[:rights_basis]} label="Rights basis" required />
            <.input field={@cover_form[:attribution_text]} label="Attribution" />
            <div class="md:col-span-2">
              <button class="rounded-sm bg-[#8C2D19] px-4 py-2 text-sm font-bold uppercase tracking-wider text-white">
                Assign cover
              </button>
            </div>
          </.form>
        </div>

        <div
          id="admin-cover-public-preview"
          class="rounded-sm border border-[#E7E2D8] bg-[#F5F2EB] p-5 dark:border-[#2E2A27] dark:bg-[#12110F]"
        >
          <h2 class="font-serif text-xl font-semibold">Public preview</h2>
          <p class="mt-1 text-sm text-stone-700 dark:text-stone-300">
            Use each assignment's preview link after a takedown to confirm the public edition renders the fallback cover instead of a hidden asset.
          </p>
        </div>

        <div id="admin-resource-form" class="sr-only">Cover governance AshPhoenix form workspace</div>
        <div id="cover-assignment-list" phx-update="stream" class="space-y-3">
          <div id="admin-resource-list" class="sr-only">Cover assignment list</div>
          <article
            :for={{dom_id, assignment} <- @streams.cover_assignments}
            id={dom_id}
            class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-4 dark:border-[#2E2A27] dark:bg-[#1C1917]"
          >
            <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
              <div>
                <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500">
                  {if assignment.visible?, do: "visible", else: "hidden"} · {assignment.cover_asset.takedown_state}
                </p>
                <h3 class="break-all font-serif text-lg font-semibold text-stone-950 dark:text-stone-50">
                  {assignment.cover_asset.source_url}
                </h3>
                <p class="text-sm text-stone-700 dark:text-stone-300">
                  {assignment.cover_asset.attribution_text || assignment.cover_asset.provider}
                </p>
                <.link
                  id={"preview-cover-#{assignment.id}"}
                  href={~p"/editions/#{assignment.edition.slug}"}
                  class="mt-2 inline-block text-xs font-bold uppercase tracking-wider text-[#8C2D19] hover:underline"
                >
                  Public preview: {assignment.edition.title}
                </.link>
              </div>
              <button
                id={"hide-cover-#{assignment.id}"}
                phx-click="hide_cover"
                phx-value-id={assignment.id}
                class="rounded-sm bg-red-700 px-3 py-2 text-xs font-bold uppercase tracking-wider text-white"
              >
                Hide for takedown
              </button>
            </div>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp assign_cover_form(socket, actor) do
    form =
      CoverAsset
      |> Form.for_create(:create, actor: actor, as: "cover_assignment")
      |> to_form()

    assign(socket, :cover_form, form)
  end

  defp cover_params(params) do
    params
    |> Map.take(["source_url", "provider", "rights_basis", "attribution_text", "attribution_url"])
    |> Map.put_new("cache_policy", "link_only")
  end

  defp edition_options(actor) do
    Edition
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&String.downcase(&1.title))
    |> Enum.map(&{&1.title, &1.id})
  end

  defp cover_assignments(actor) do
    CoverAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([:cover_asset, :edition])
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&{&1.position || 0, &1.id})
  end
end
