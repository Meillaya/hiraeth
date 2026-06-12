defmodule HiraethWeb.Admin.EditionsLive do
  use HiraethWeb, :live_view

  alias AshPhoenix.Form

  alias Hiraeth.Catalog.{
    Contributor,
    Edition,
    Identifier,
    Imprint,
    Publisher,
    Work
  }

  alias Hiraeth.Covers.CoverAsset

  @edition_fields ~w(title subtitle slug format published_on work_id publisher_id imprint_id)

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, "Admin Editions")
      |> assign(:mode, :create)
      |> assign(:editing_edition, nil)
      |> assign(:nested_errors, [])
      |> assign(:last_created_slug, nil)
      |> assign(:last_created_summary, nil)
      |> assign_forms(actor)
      |> load_reference_data()
      |> load_editions()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"edition" => params}, socket) do
    form = Form.validate(socket.assigns.form, edition_params(params))
    nested_forms = validate_nested_forms(socket, params)

    {:noreply,
     socket
     |> assign(nested_forms)
     |> assign(form: form, nested_errors: nested_errors(params))}
  end

  def handle_event("save", %{"edition" => params}, %{assigns: %{mode: :edit}} = socket) do
    actor = socket.assigns.current_user
    errors = required_errors(params)
    form = Form.validate(socket.assigns.form, edition_params(params))

    if errors != [] do
      {:noreply,
       socket
       |> put_flash(:error, "Edition could not be saved")
       |> assign(form: form, nested_errors: errors)}
    else
      case Form.submit(form, params: edition_params(params)) do
        {:ok, edition} ->
          socket =
            socket
            |> put_flash(:info, "Edition updated")
            |> assign(:mode, :create)
            |> assign(:editing_edition, nil)
            |> assign_forms(actor)
            |> assign(:nested_errors, [])
            |> assign(:last_created_slug, edition.slug)
            |> assign(:last_created_summary, %{
              title: edition.title,
              contributor: nil,
              identifier: nil
            })
            |> load_reference_data()
            |> load_editions()

          {:noreply, socket}

        {:error, form} ->
          {:noreply,
           socket
           |> put_flash(:error, "Edition could not be saved")
           |> assign(form: form, nested_errors: errors)}
      end
    end
  end

  def handle_event("save", %{"edition" => params}, socket) do
    actor = socket.assigns.current_user
    errors = required_errors(params) ++ nested_errors(params)
    form = Form.validate(socket.assigns.form, edition_params(params))
    nested_forms = validate_nested_forms(socket, params)

    if errors != [] do
      {:noreply,
       socket
       |> put_flash(:error, "Edition could not be saved")
       |> assign(nested_forms)
       |> assign(form: form, nested_errors: errors)}
    else
      submit_nested_catalog_forms(socket, params)

      case Form.submit(form, params: catalog_edge_params(params)) do
        {:ok, edition} ->
          socket =
            socket
            |> put_flash(:info, "Edition created")
            |> assign(:mode, :create)
            |> assign(:editing_edition, nil)
            |> assign_forms(actor)
            |> assign(:nested_errors, [])
            |> assign(:last_created_slug, edition.slug)
            |> assign(:last_created_summary, created_summary(edition, params))
            |> load_reference_data()
            |> load_editions()

          {:noreply, socket}

        {:error, form} ->
          {:noreply,
           socket
           |> put_flash(:error, "Edition could not be saved")
           |> assign(nested_forms)
           |> assign(form: form, nested_errors: errors)}
      end
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    edition =
      Edition
      |> Ash.get!(id, actor: socket.assigns.current_user)
      |> Ash.load!([:publisher, :identifiers, contributions: [:contributor]],
        actor: socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(:mode, :edit)
     |> assign(:editing_edition, edition)
     |> assign(:form, edit_form(edition, socket.assigns.current_user))
     |> assign(:nested_errors, [])}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:mode, :create)
     |> assign(:editing_edition, nil)
     |> assign_forms(socket.assigns.current_user)
     |> assign(:nested_errors, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-editions" data-created-edition-slug={@last_created_slug} class="space-y-8">
        <div class="border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
          <p class="font-mono text-xs uppercase tracking-wider text-stone-500">
            Catalog Administration
          </p>
          <div class="mt-1 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 class="font-serif text-3xl font-medium text-stone-900 dark:text-stone-100">
                Editions workspace
              </h1>
              <p class="mt-2 max-w-3xl text-sm text-stone-600 dark:text-stone-400">
                Create and update edition records with AshPhoenix-driven catalog edge sections for contributors, ISBNs, and optional link-only cover metadata. All writes submit through Ash policies with the signed-in admin as actor.
              </p>
            </div>
            <.link navigate={~p"/admin"} class="text-sm font-semibold text-[#8C2D19] hover:underline">
              Back to dashboard
            </.link>
          </div>
        </div>

        <.catalog_nav />

        <div
          :if={@last_created_summary}
          id="edition-created-summary"
          class="rounded-sm border border-green-200 bg-green-50 p-4 text-sm text-green-800"
        >
          <strong>{if @mode == :edit, do: "Edition updated.", else: "Edition created."}</strong>
          <span>{@last_created_summary.title}</span>
          <span :if={@last_created_summary.contributor}> · {@last_created_summary.contributor}</span>
          <span :if={@last_created_summary.identifier}> · {@last_created_summary.identifier}</span>
        </div>

        <div class="grid gap-8 xl:grid-cols-[minmax(0,1fr)_minmax(360px,0.8fr)]">
          <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
            <h2 id="edition-form-title" class="font-serif text-xl text-stone-900 dark:text-stone-100">
              {if @mode == :edit, do: "Update edition", else: "Create edition"}
            </h2>
            <p class="mt-1 text-sm text-stone-600 dark:text-stone-400">
              AshPhoenix owns the edition form. Contributor, identifier, and cover sections are also backed by AshPhoenix forms and submitted as nested catalog edge data.
            </p>

            <.form
              for={@form}
              id="edition-form"
              phx-change="validate"
              phx-submit="save"
              class="mt-6 space-y-6"
            >
              <div
                :if={@nested_errors != []}
                id="edition-errors"
                class="rounded-sm border border-red-200 bg-red-50 p-3 text-sm text-red-800"
              >
                <p class="font-semibold">Edition could not be saved</p>
                <ul class="mt-1 list-disc pl-5">
                  <li :for={error <- @nested_errors}>{error}</li>
                </ul>
              </div>

              <div class="grid gap-4 md:grid-cols-2">
                <.input field={@form[:title]} label="Title" required />
                <.input field={@form[:subtitle]} label="Subtitle" />
                <.input field={@form[:slug]} label="Slug" required />
                <.input field={@form[:format]} label="Format" placeholder="paperback" />
                <.input
                  field={@form[:publisher_id]}
                  type="select"
                  label="Publisher"
                  prompt="Choose publisher"
                  options={@publisher_options}
                  required
                />
                <.input
                  field={@form[:work_id]}
                  type="select"
                  label="Work"
                  prompt="Choose work"
                  options={@work_options}
                  required
                />
                <.input
                  field={@form[:imprint_id]}
                  type="select"
                  label="Imprint"
                  prompt="No imprint"
                  options={@imprint_options}
                />
              </div>

              <.nested_catalog_forms
                :if={@mode == :create}
                contributor_form={@contributor_form}
                identifier_form={@identifier_form}
                cover_form={@cover_form}
              />

              <div class="flex gap-3">
                <button
                  type="submit"
                  class="inline-flex items-center justify-center rounded-sm border border-[#8C2D19] bg-[#8C2D19] px-3 py-2 text-sm font-semibold text-white transition hover:bg-[#6F2415] dark:border-[#E05A47] dark:bg-[#E05A47] dark:text-[#12110F] dark:hover:bg-[#F07362]"
                >
                  {if @mode == :edit, do: "Update edition", else: "Create edition"}
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

          <aside class="rounded-sm border border-[#E7E2D8] bg-white p-5 dark:border-[#2E2A27] dark:bg-[#12110F]">
            <h2 class="font-serif text-xl text-stone-900 dark:text-stone-100">Recent editions</h2>
            <div id="edition-list" class="mt-4 space-y-3">
              <article
                :for={edition <- @editions}
                id={"edition-#{edition.id}"}
                class="rounded-sm border border-[#E7E2D8] p-3 text-sm dark:border-[#2E2A27]"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h3 class="font-semibold text-stone-900 dark:text-stone-100">{edition.title}</h3>
                    <p class="text-stone-600 dark:text-stone-400">{edition.publisher.name}</p>
                    <p class="font-mono text-xs text-stone-500">{edition.slug}</p>
                  </div>
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-id={edition.id}
                    class="text-xs font-semibold uppercase tracking-wider text-[#8C2D19] hover:underline"
                  >
                    Edit
                  </button>
                </div>
                <p :if={edition.contributions != []} class="mt-1 text-stone-600 dark:text-stone-400">
                  {edition.contributions |> Enum.map(& &1.contributor.display_name) |> Enum.join(", ")}
                </p>
                <p :if={edition.identifiers != []} class="font-mono text-xs text-stone-500">
                  {edition.identifiers |> Enum.map(& &1.value) |> Enum.join(", ")}
                </p>
              </article>
            </div>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :contributor_form, :any, required: true
  attr :identifier_form, :any, required: true
  attr :cover_form, :any, required: true

  defp nested_catalog_forms(assigns) do
    ~H"""
    <fieldset class="rounded-sm border border-[#E7E2D8] p-4 dark:border-[#2E2A27]">
      <legend class="px-1 font-mono text-xs uppercase tracking-wider text-stone-500">
        Nested contributor · AshPhoenix.Form
      </legend>
      <div class="mt-3 grid gap-4 md:grid-cols-2">
        <.nested_input
          field={@contributor_form[:display_name]}
          nested="contributor"
          key="display_name"
          label="Contributor name"
        />
        <.nested_input
          field={@contributor_form[:sort_name]}
          nested="contributor"
          key="sort_name"
          label="Sort name"
        />
        <.nested_input
          field={@contributor_form[:slug]}
          nested="contributor"
          key="slug"
          label="Contributor slug"
        />
        <.nested_input
          name="edition[contributor][role]"
          id="edition_contributor_role"
          label="Role"
          value="author"
        />
      </div>
    </fieldset>

    <fieldset class="rounded-sm border border-[#E7E2D8] p-4 dark:border-[#2E2A27]">
      <legend class="px-1 font-mono text-xs uppercase tracking-wider text-stone-500">
        Nested identifier · AshPhoenix.Form
      </legend>
      <div class="mt-3 grid gap-4 md:grid-cols-2">
        <.nested_input
          name="edition[identifier][identifier_type]"
          id="edition_identifier_type"
          label="Identifier type"
          value="isbn_13"
        />
        <.nested_input
          field={@identifier_form[:value]}
          nested="identifier"
          key="value"
          label="Identifier value"
        />
      </div>
    </fieldset>

    <fieldset class="rounded-sm border border-[#E7E2D8] p-4 dark:border-[#2E2A27]">
      <legend class="px-1 font-mono text-xs uppercase tracking-wider text-stone-500">
        Optional link-only cover · AshPhoenix.Form
      </legend>
      <div class="mt-3 grid gap-4 md:grid-cols-2">
        <.nested_input field={@cover_form[:provider]} nested="cover" key="provider" label="Provider" />
        <.nested_input
          field={@cover_form[:source_url]}
          nested="cover"
          key="source_url"
          label="Source URL"
        />
        <.nested_input
          field={@cover_form[:rights_basis]}
          nested="cover"
          key="rights_basis"
          label="Rights basis"
        />
        <.nested_input
          field={@cover_form[:attribution_text]}
          nested="cover"
          key="attribution_text"
          label="Attribution"
        />
      </div>
    </fieldset>
    """
  end

  defp assign_forms(socket, actor) do
    socket
    |> assign(:form, new_form(actor))
    |> assign(:contributor_form, nested_form(Contributor, actor))
    |> assign(:identifier_form, nested_form(Identifier, actor))
    |> assign(:cover_form, nested_form(CoverAsset, actor))
  end

  defp new_form(actor) do
    Edition
    |> Form.for_create(:create_with_catalog_edges, actor: actor, as: "edition")
    |> to_form()
  end

  defp edit_form(edition, actor) do
    edition
    |> Form.for_update(:update, actor: actor, as: "edition")
    |> to_form()
  end

  defp nested_form(resource, actor) do
    resource
    |> Form.for_create(:create, actor: actor, as: nested_as(resource))
    |> to_form()
  end

  defp nested_as(Contributor), do: "contributor"
  defp nested_as(Identifier), do: "identifier"
  defp nested_as(CoverAsset), do: "cover"

  defp validate_nested_forms(socket, params) do
    [
      contributor_form:
        Form.validate(socket.assigns.contributor_form, Map.get(params, "contributor", %{})),
      identifier_form:
        Form.validate(socket.assigns.identifier_form, Map.get(params, "identifier", %{})),
      cover_form: Form.validate(socket.assigns.cover_form, Map.get(params, "cover", %{}))
    ]
  end

  defp submit_nested_catalog_forms(_socket, _params) do
    # AshPhoenix nested section forms are used for casting/validation and field rendering.
    # The canonical write remains the Edition Ash action so the edition and its catalog edges
    # are governed by one Ash policy/actor boundary.
    :ok
  end

  defp load_reference_data(socket) do
    actor = socket.assigns.current_user

    publishers = Publisher |> Ash.Query.for_read(:read) |> Ash.read!(actor: actor)
    works = Work |> Ash.Query.for_read(:read) |> Ash.read!(actor: actor)
    imprints = Imprint |> Ash.Query.for_read(:read) |> Ash.read!(actor: actor)

    socket
    |> assign(:publisher_options, Enum.map(publishers, &{&1.name, &1.id}))
    |> assign(:work_options, Enum.map(works, &{&1.title, &1.id}))
    |> assign(:imprint_options, Enum.map(imprints, &{&1.name, &1.id}))
  end

  defp load_editions(socket) do
    editions =
      Edition
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load([:publisher, :identifiers, contributions: [:contributor]])
      |> Ash.read!(actor: socket.assigns.current_user)
      |> Enum.sort_by(&{String.downcase(&1.title), &1.id})
      |> Enum.take(20)

    assign(socket, :editions, editions)
  end

  defp created_summary(edition, params) do
    %{
      title: edition.title,
      contributor: get_in(params, ["contributor", "display_name"]),
      identifier: get_in(params, ["identifier", "value"])
    }
  end

  defp catalog_edge_params(params) do
    params
    |> edition_params()
    |> Map.put("contributor", params["contributor"] || %{})
    |> Map.put("identifier", params["identifier"] || %{})
    |> Map.put("cover", params["cover"] || %{})
  end

  defp edition_params(params), do: Map.take(params, @edition_fields)

  defp required_errors(params) do
    [
      required_error(params["title"], "Title can't be blank"),
      required_error(params["slug"], "Slug can't be blank"),
      required_error(params["publisher_id"], "Publisher can't be blank"),
      required_error(params["work_id"], "Work can't be blank")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp nested_errors(params) do
    contributor = params["contributor"] || %{}
    identifier = params["identifier"] || %{}

    [
      required_error(contributor["display_name"], "Contributor name can't be blank"),
      required_error(identifier["value"], "Identifier value can't be blank")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp required_error(value, message), do: if(blank_to_nil(value), do: nil, else: message)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  attr :field, Phoenix.HTML.FormField, default: nil
  attr :nested, :string, default: nil
  attr :key, :string, default: nil
  attr :name, :string, default: nil
  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :string, default: nil

  defp nested_input(assigns) do
    assigns =
      case assigns.field do
        %Phoenix.HTML.FormField{} = field ->
          assigns
          |> assign(:name, assigns.name || "edition[#{assigns.nested}][#{assigns.key}]")
          |> assign(:id, assigns.id || "edition_#{assigns.nested}_#{assigns.key}")
          |> assign(:value, assigns.value || field.value)
          |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))

        _ ->
          assign(assigns, :errors, [])
      end

    ~H"""
    <label class="block">
      <span class="mb-1 block text-sm font-medium text-stone-700 dark:text-stone-300">{@label}</span>
      <input
        id={@id}
        name={@name}
        value={@value}
        class="w-full rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] px-3 py-2 text-sm text-stone-900 focus:border-[#8C2D19] focus:outline-none focus:ring-1 focus:ring-[#8C2D19] dark:border-[#2E2A27] dark:bg-[#12110F] dark:text-stone-100"
      />
      <p :for={error <- @errors} class="mt-1 text-xs text-red-700">{error}</p>
    </label>
    """
  end

  defp catalog_nav(assigns) do
    ~H"""
    <nav class="flex flex-wrap gap-2" aria-label="Admin catalog sections">
      <.link
        navigate={~p"/admin/editions"}
        class="rounded-full border border-[#8C2D19] bg-[#8C2D19] px-3 py-1.5 text-xs font-semibold uppercase tracking-wider text-white"
      >Editions</.link>
      <.link
        navigate={~p"/admin/publishers"}
        class="rounded-full border border-[#E7E2D8] px-3 py-1.5 text-xs font-semibold uppercase tracking-wider text-stone-600"
      >Publishers</.link>
      <.link
        navigate={~p"/admin/contributors"}
        class="rounded-full border border-[#E7E2D8] px-3 py-1.5 text-xs font-semibold uppercase tracking-wider text-stone-600"
      >Contributors</.link>
      <.link
        navigate={~p"/admin/covers"}
        class="rounded-full border border-[#E7E2D8] px-3 py-1.5 text-xs font-semibold uppercase tracking-wider text-stone-600"
      >Covers</.link>
    </nav>
    """
  end
end
