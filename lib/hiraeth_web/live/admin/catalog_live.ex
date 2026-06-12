defmodule HiraethWeb.Admin.CatalogLive do
  use HiraethWeb, :live_view

  alias AshPhoenix.Form
  alias Hiraeth.Catalog.{Contributor, Edition, Identifier, Imprint, Publisher, Series, Work}
  alias Hiraeth.Covers.CoverAsset
  alias Hiraeth.Sources.{CurationOverride, SourceRecord}

  @sections [
    publishers: {"Publishers", Publisher, [:name, :slug, :description]},
    imprints: {"Imprints", Imprint, [:name, :slug, :publisher_id]},
    works: {"Works", Work, [:title, :subtitle, :slug, :publication_state]},
    contributors: {"Contributors", Contributor, [:display_name, :sort_name, :slug]},
    series: {"Series", Series, [:title, :slug, :publisher_id]},
    identifiers: {"Identifiers", Identifier, [:identifier_type, :value, :edition_id]},
    covers:
      {"Covers", CoverAsset,
       [:source_url, :provider, :rights_basis, :attribution_text, :cache_policy]},
    curation_overrides:
      {"Curation Overrides", CurationOverride,
       [:entity_type, :entity_id, :field_name, :curated_value, :reason, :source_record_id]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_section(socket, socket.assigns.live_action, :create, nil)}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, :form, Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case Form.submit(socket.assigns.form, params: params) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{socket.assigns.section_title} saved")
         |> load_section(socket.assigns.live_action, :create, nil)}

      {:error, form} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{socket.assigns.section_title} could not be saved")
         |> assign(:form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {_title, resource, _fields} = config!(socket.assigns.live_action)
    record = Ash.get!(resource, id, actor: socket.assigns.current_user)
    {:noreply, load_section(socket, socket.assigns.live_action, :edit, record)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, load_section(socket, socket.assigns.live_action, :create, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-catalog-section" class="space-y-6">
        <div class="border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
          <p class="font-mono text-xs uppercase tracking-wider text-stone-500">Admin catalog</p>
          <h1 class="mt-1 font-serif text-3xl font-medium text-stone-900 dark:text-stone-100">
            Manage {@section_title}
          </h1>
          <p class="mt-2 max-w-2xl text-sm text-stone-600 dark:text-stone-400">
            Protected AshPhoenix create/update workspace for {@section_title}. Every submit carries the signed-in admin actor into Ash policies.
          </p>
        </div>

        <.admin_catalog_nav current={@live_action} />

        <div class="grid gap-6 xl:grid-cols-[minmax(0,0.85fr)_minmax(360px,1fr)]">
          <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
            <h2
              id="admin-resource-form-title"
              class="font-serif text-xl text-stone-900 dark:text-stone-100"
            >
              {if @mode == :edit, do: "Update", else: "Create"} {@section_title}
            </h2>
            <.form
              for={@form}
              id="admin-resource-form"
              phx-change="validate"
              phx-submit="save"
              class="mt-5 space-y-4"
            >
              <.resource_field
                :for={field <- @fields}
                field={@form[field]}
                field_name={field}
                options={@select_options}
              />
              <div class="flex gap-3">
                <button
                  type="submit"
                  class="inline-flex items-center justify-center rounded-sm border border-[#8C2D19] bg-[#8C2D19] px-3 py-2 text-sm font-semibold text-white hover:bg-[#6F2415]"
                >
                  Save {@section_title}
                </button>
                <button
                  :if={@mode == :edit}
                  type="button"
                  phx-click="cancel_edit"
                  class="inline-flex items-center justify-center rounded-sm border border-[#E7E2D8] px-3 py-2 text-sm font-semibold text-stone-700"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>

          <div class="rounded-sm border border-[#E7E2D8] bg-white p-5 dark:border-[#2E2A27] dark:bg-[#12110F]">
            <h2 class="font-serif text-xl text-stone-900 dark:text-stone-100">
              Existing {@section_title}
            </h2>
            <div id="admin-resource-list" class="mt-4 space-y-3">
              <article
                :for={record <- @records}
                id={"admin-record-#{record.id}"}
                class="rounded-sm border border-[#E7E2D8] p-3 text-sm dark:border-[#2E2A27]"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h3 class="font-semibold text-stone-900 dark:text-stone-100">
                      {record_title(record)}
                    </h3>
                    <p class="font-mono text-xs text-stone-500">{record.id}</p>
                  </div>
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-id={record.id}
                    class="text-xs font-semibold uppercase tracking-wider text-[#8C2D19] hover:underline"
                  >
                    Edit
                  </button>
                </div>
              </article>
              <p :if={@records == []} class="text-sm text-stone-500">No records yet.</p>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :field_name, :atom, required: true
  attr :options, :map, required: true

  defp resource_field(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        assigns.field_name |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
      )

    if Map.has_key?(assigns.options, assigns.field_name) do
      ~H"""
      <.input
        field={@field}
        type="select"
        label={@label}
        prompt="Choose"
        options={Map.fetch!(@options, @field_name)}
      />
      """
    else
      ~H"""
      <.input field={@field} label={@label} />
      """
    end
  end

  defp load_section(socket, action, mode, record) do
    {title, resource, fields} = config!(action)
    actor = socket.assigns.current_user

    form =
      case mode do
        :edit -> record |> Form.for_update(:update, actor: actor, as: "form") |> to_form()
        :create -> resource |> Form.for_create(:create, actor: actor, as: "form") |> to_form()
      end

    socket
    |> assign(:page_title, "Manage #{title}")
    |> assign(:section_title, title)
    |> assign(:resource, resource)
    |> assign(:fields, fields)
    |> assign(:mode, mode)
    |> assign(:form, form)
    |> assign(:select_options, select_options(actor))
    |> assign(:records, records(resource, actor))
  end

  defp records(resource, actor) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&record_title/1)
    |> Enum.take(25)
  end

  defp select_options(actor) do
    %{
      publisher_id: Publisher |> Ash.read!(actor: actor) |> Enum.map(&{&1.name, &1.id}),
      work_id: Work |> Ash.read!(actor: actor) |> Enum.map(&{&1.title, &1.id}),
      edition_id: Edition |> Ash.read!(actor: actor) |> Enum.map(&{&1.title, &1.id}),
      source_record_id:
        SourceRecord
        |> Ash.read!(actor: actor)
        |> Enum.map(&{&1.source_uri || &1.provider, &1.id})
    }
  end

  defp config!(action), do: Keyword.fetch!(@sections, action)

  defp record_title(record) do
    cond do
      Map.get(record, :name) -> record.name
      Map.get(record, :title) -> record.title
      Map.get(record, :display_name) -> record.display_name
      Map.get(record, :value) -> record.value
      Map.get(record, :source_url) -> record.source_url
      Map.get(record, :field_name) -> "#{record.entity_type}.#{record.field_name}"
      true -> record.id
    end
  end

  attr :current, :atom, required: true

  defp admin_catalog_nav(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <nav class="flex flex-wrap gap-2" aria-label="Admin catalog sections">
      <.link
        :for={{key, {label, _resource, _fields}} <- @sections}
        navigate={admin_path(key)}
        class={[
          "rounded-full border px-3 py-1.5 text-xs font-semibold uppercase tracking-wider",
          @current == key && "border-[#8C2D19] bg-[#8C2D19] text-white",
          @current != key &&
            "border-[#E7E2D8] text-stone-600 hover:border-[#8C2D19] hover:text-[#8C2D19] dark:border-[#2E2A27] dark:text-stone-300"
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  defp admin_path(:publishers), do: ~p"/admin/publishers"
  defp admin_path(:imprints), do: ~p"/admin/imprints"
  defp admin_path(:works), do: ~p"/admin/works"
  defp admin_path(:contributors), do: ~p"/admin/contributors"
  defp admin_path(:series), do: ~p"/admin/series"
  defp admin_path(:identifiers), do: ~p"/admin/identifiers"
  defp admin_path(:covers), do: ~p"/admin/covers"
  defp admin_path(:curation_overrides), do: ~p"/admin/curation-overrides"
end
