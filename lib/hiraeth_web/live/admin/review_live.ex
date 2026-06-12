defmodule HiraethWeb.Admin.ReviewLive do
  use HiraethWeb, :live_view

  alias AshPhoenix.Form
  alias Hiraeth.Imports.ReviewItem
  alias Hiraeth.Sources.{CurationOverride, SourceRecord}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Admin Review")
     |> assign(:review_item, nil)
     |> assign(:source_options, source_options())
     |> assign_override_form(actor)
     |> stream(:review_items, pending_review_items(actor), dom_id: &"review-item-#{&1.id}")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, item} <- fetch_review_item(uuid, socket.assigns.current_user) do
      {:noreply,
       socket
       |> assign(:page_title, "Review item")
       |> assign(:review_item, item)
       |> assign_override_form(socket.assigns.current_user)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Review item not found")
         |> push_navigate(to: ~p"/admin/review")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Review queue")
     |> stream(:review_items, pending_review_items(socket.assigns.current_user),
       reset: true,
       dom_id: &"review-item-#{&1.id}"
     )}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    item = ReviewItem |> Ash.get!(id, actor: socket.assigns.current_user)

    item
    |> Ash.Changeset.for_update(:approve_review_item, %{})
    |> Ash.update!(actor: socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, "Review item approved")
     |> stream_delete(:review_items, item)}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    item = ReviewItem |> Ash.get!(id, actor: socket.assigns.current_user)

    item
    |> Ash.Changeset.for_update(:reject_review_item, %{})
    |> Ash.update!(actor: socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, "Review item rejected")
     |> stream_delete(:review_items, item)}
  end

  def handle_event("validate_override", %{"curation_override" => params}, socket) do
    {:noreply,
     assign(socket, :override_form, Form.validate(socket.assigns.override_form, params))}
  end

  def handle_event("save_override", %{"curation_override" => params}, socket) do
    case Form.submit(socket.assigns.override_form, params: params) do
      {:ok, _override} ->
        {:noreply,
         socket
         |> put_flash(:info, "Curation override applied")
         |> assign_override_form(socket.assigns.current_user)}

      {:error, form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Curation override could not be applied")
         |> assign(:override_form, form)}
    end
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-review-shell" class="space-y-8">
        <.admin_header title="Review queue" eyebrow="Metadata governance" />

        <div id="review-queue" phx-update="stream" class="space-y-3">
          <article
            :for={{dom_id, item} <- @streams.review_items}
            id={dom_id}
            class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-4 dark:border-[#2E2A27] dark:bg-[#1C1917]"
          >
            <div class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
              <div>
                <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500">
                  {item.entity_type} · {item.decision}
                </p>
                <h2 class="font-serif text-lg font-semibold text-stone-950 dark:text-stone-50">
                  {item.message || "Review required"}
                </h2>
              </div>
              <div class="flex flex-wrap gap-2">
                <.link
                  navigate={~p"/admin/review/#{item.id}"}
                  id={"open-review-#{item.id}"}
                  class="rounded-sm border border-[#8C2D19] px-3 py-2 text-xs font-bold uppercase tracking-wider text-[#8C2D19] hover:bg-[#8C2D19] hover:text-white"
                >
                  Detail
                </.link>
                <button
                  id={"approve-review-#{item.id}"}
                  phx-click="approve"
                  phx-value-id={item.id}
                  class="rounded-sm bg-green-700 px-3 py-2 text-xs font-bold uppercase tracking-wider text-white"
                >
                  Approve
                </button>
                <button
                  id={"reject-review-#{item.id}"}
                  phx-click="reject"
                  phx-value-id={item.id}
                  class="rounded-sm bg-red-700 px-3 py-2 text-xs font-bold uppercase tracking-wider text-white"
                >
                  Reject
                </button>
              </div>
            </div>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="review-detail-shell" class="space-y-8">
        <.admin_header title="Review detail" eyebrow="Conflict resolution" />

        <div
          :if={@review_item}
          class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]"
        >
          <p class="font-mono text-xs uppercase tracking-wider text-stone-500">
            {@review_item.entity_type} · {@review_item.decision}
          </p>
          <h2 class="mt-1 font-serif text-2xl font-semibold text-stone-950 dark:text-stone-50">
            {@review_item.message || "Review item"}
          </h2>
        </div>

        <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
          <h2 class="font-serif text-xl font-semibold">Curation override</h2>
          <p class="mt-1 text-sm text-stone-700 dark:text-stone-300">
            Apply a reviewed field override through an AshPhoenix form and the signed-in admin actor.
          </p>

          <.form
            for={@override_form}
            id="curation-override-form"
            phx-change="validate_override"
            phx-submit="save_override"
            class="mt-5 grid gap-4 md:grid-cols-2"
          >
            <.input field={@override_form[:entity_type]} label="Entity type" required />
            <.input field={@override_form[:entity_id]} label="Entity id" required />
            <.input field={@override_form[:field_name]} label="Field" required />
            <.input field={@override_form[:curated_value]} label="Curated value" required />
            <.input field={@override_form[:reason]} label="Reason" required />
            <.input
              field={@override_form[:source_record_id]}
              type="select"
              label="Source record"
              options={@source_options}
              required
            />
            <div class="md:col-span-2">
              <button class="rounded-sm bg-[#8C2D19] px-4 py-2 text-sm font-bold uppercase tracking-wider text-white">
                Apply override
              </button>
            </div>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :eyebrow, :string, required: true

  defp admin_header(assigns) do
    ~H"""
    <div class="border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
      <p class="font-mono text-xs uppercase tracking-wider text-stone-500">{@eyebrow}</p>
      <h1 class="mt-1 font-serif text-3xl font-medium text-stone-900 dark:text-stone-100">
        {@title}
      </h1>
      <.link
        navigate={~p"/admin"}
        class="mt-3 inline-block text-sm font-semibold text-[#8C2D19] hover:underline"
      >
        Back to dashboard
      </.link>
    </div>
    """
  end

  defp pending_review_items(actor) do
    ReviewItem
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor)
    |> Enum.filter(&(&1.decision == "pending"))
    |> Enum.sort_by(&{&1.entity_type, &1.id})
  end

  defp fetch_review_item(id, actor) do
    item =
      ReviewItem
      |> Ash.get!(id, actor: actor)
      |> Ash.load!([:import_run, :staged_import_row], actor: actor)

    {:ok, item}
  rescue
    Ash.Error.Invalid -> :error
    Ash.Error.Query.NotFound -> :error
  end

  defp assign_override_form(socket, actor) do
    form =
      CurationOverride
      |> Form.for_create(:create, actor: actor, as: "curation_override")
      |> to_form()

    assign(socket, :override_form, form)
  end

  defp source_options do
    SourceRecord
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.source_uri || &1.provider, &1.id})
  end
end
