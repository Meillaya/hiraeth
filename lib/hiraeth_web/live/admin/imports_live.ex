defmodule HiraethWeb.Admin.ImportsLive do
  use HiraethWeb, :live_view

  alias Hiraeth.Imports.{ImportMapping, ImportRun, ReviewItem, StagedImportRow}
  alias HiraethWeb.CatalogComponents

  @upload_name :csv
  @max_upload_size 2_000_000
  @target_fields ["title", "isbn", "publisher"]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Imports")
     |> assign(:run, nil)
     |> assign(:rows, [])
     |> assign(:review_items, [])
     |> assign(:import_runs_count, 0)
     |> assign(:upload_error_message, nil)
     |> assign(:summary, summary([]))
     |> assign(:upload_form, to_form(%{"provider" => "local_csv"}, as: :import_upload))
     |> assign(:current_mapping, default_mapping())
     |> assign(:mapping_form, to_form(default_mapping(), as: :mapping))
     |> assign_import_runs(actor)
     |> allow_upload(@upload_name,
       accept: ~w(.csv text/csv),
       max_entries: 1,
       max_file_size: @max_upload_size,
       auto_upload: false
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case load_run(id, socket.assigns.current_user) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:page_title, "Import detail")
         |> assign_run(run)}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Import run not found")
         |> push_navigate(to: ~p"/admin/imports")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign_import_runs(socket.assigns.current_user)}
  end

  @impl true
  def handle_event("validate_upload", %{"import_upload" => params}, socket) do
    {:noreply,
     socket
     |> assign(:upload_error_message, nil)
     |> assign(:upload_form, to_form(params, as: :import_upload))}
  end

  def handle_event("upload_import", %{"import_upload" => params}, socket) do
    actor = socket.assigns.current_user
    provider = present(params["provider"]) || "local_csv"

    uploaded =
      consume_uploaded_entries(socket, @upload_name, fn %{path: path}, entry ->
        {:ok, %{file_name: entry.client_name, content: File.read!(path)}}
      end)

    case uploaded do
      [%{file_name: file_name, content: content}] ->
        case upload_csv(provider, file_name, content, actor) do
          {:ok, run} ->
            {:noreply,
             socket
             |> put_flash(:info, "Import uploaded")
             |> push_navigate(to: ~p"/admin/imports/#{run.id}")}

          {:error, error} ->
            message = error_message(error)

            {:noreply,
             socket
             |> put_flash(:error, message)
             |> assign(:upload_error_message, message)
             |> assign(:upload_form, to_form(params, as: :import_upload))}
        end

      [] ->
        message = "Choose a CSV file before uploading"

        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign(:upload_error_message, message)}
    end
  end

  def handle_event("save_mapping", %{"mapping" => mapping}, socket) do
    actor = socket.assigns.current_user
    run = socket.assigns.run

    mappings =
      mapping
      |> Map.take(@target_fields)
      |> Enum.reject(fn {_target, source} -> present(source) == nil end)
      |> Map.new(fn {target, source} -> {source, target} end)

    case update_run(run, :map_columns, %{mappings: mappings}, actor) do
      {:ok, mapped} ->
        {:noreply,
         socket
         |> put_flash(:info, "Column mapping saved")
         |> assign(:mapping_form, to_form(mapping, as: :mapping))
         |> assign_run(mapped)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("dry_run", _params, socket) do
    actor = socket.assigns.current_user

    with {:ok, validated} <- update_run(socket.assigns.run, :validate_rows, %{}, actor),
         {:ok, dry_run} <- update_run(validated, :dry_run, %{}, actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Dry-run complete")
       |> assign_run(dry_run)}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("apply", _params, socket) do
    actor = socket.assigns.current_user

    case update_run(socket.assigns.run, :apply_accepted_rows, %{}, actor) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Accepted rows applied")
         |> assign_run(run)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  @impl true
  def render(%{live_action: :new} = assigns), do: render_new(assigns)
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-imports-shell" class="space-y-8">
        <.import_header title="CSV imports" eyebrow="Ingest workflow" />
        <.link
          id="new-import-link"
          navigate={~p"/admin/imports/new"}
          class="inline-flex rounded-sm bg-[#8C2D19] px-4 py-2 text-sm font-bold uppercase tracking-wider text-white"
        >
          New CSV import
        </.link>

        <CatalogComponents.empty_state
          :if={@import_runs_count == 0}
          id="imports-empty"
          title="No import runs yet"
          message="No import runs yet. Start a CSV import when you have a permissioned metadata file ready for synchronous review."
          action_label="Start a CSV import"
          action_path="/admin/imports/new"
        />

        <div id="import-runs" phx-update="stream" class="space-y-3">
          <article
            :for={{dom_id, run} <- @streams.import_runs}
            id={dom_id}
            class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-4 dark:border-[#2E2A27] dark:bg-[#1C1917]"
          >
            <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500">
              {run.status} · limit {run.row_limit}
            </p>
            <h2 class="font-serif text-lg font-semibold">{run.provider}</h2>
            <.link
              id={"open-import-#{run.id}"}
              navigate={~p"/admin/imports/#{run.id}"}
              class="mt-2 inline-block text-xs font-bold uppercase tracking-wider text-[#8C2D19] hover:underline"
            >
              Open import
            </.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp render_new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-import-new-shell" class="space-y-8">
        <.import_header title="New CSV import" eyebrow="Upload catalog rows" />

        <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
          <p class="text-sm text-stone-700 dark:text-stone-300">
            Upload a permissioned CSV. Synchronous v1 imports are capped at 250 rows and 1 MiB; larger workflows are intentionally deferred.
          </p>
          <CatalogComponents.error_block
            :if={@upload_error_message}
            id="import-parse-error"
            title="The CSV could not be parsed"
            message={"The CSV could not be parsed for provider #{field_value(@upload_form, :provider)}: #{@upload_error_message}. Check quoting, row count, and file size, then upload again."}
          />
          <.form
            for={@upload_form}
            id="import-upload-form"
            phx-change="validate_upload"
            phx-submit="upload_import"
            class="mt-5 grid gap-4 md:grid-cols-2"
          >
            <.input field={@upload_form[:provider]} label="Provider" required />
            <div>
              <label
                for={@uploads.csv.ref}
                class="block text-sm font-semibold text-stone-700 dark:text-stone-300"
              >
                CSV file
              </label>
              <.live_file_input
                upload={@uploads.csv}
                id="csv-upload"
                class="mt-2 block w-full text-sm"
              />
              <div
                id="csv-upload-entries"
                class="mt-2 space-y-1 text-xs text-stone-600 dark:text-stone-400"
              >
                <p :for={entry <- @uploads.csv.entries}>{entry.client_name} · {entry.progress}%</p>
              </div>
              <p :for={error <- upload_errors(@uploads.csv)} class="mt-1 text-sm text-red-700">
                {upload_error(error)}
              </p>
            </div>
            <div class="md:col-span-2">
              <button class="rounded-sm bg-[#8C2D19] px-4 py-2 text-sm font-bold uppercase tracking-wider text-white">
                Upload CSV
              </button>
            </div>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <section id="admin-import-detail-shell" class="space-y-8">
        <.import_header title="Import detail" eyebrow="Map, dry-run, apply" />

        <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-5 dark:border-[#2E2A27] dark:bg-[#1C1917]">
          <p class="font-mono text-xs uppercase tracking-wider text-stone-500">
            {@run.provider} · {@run.status}
          </p>
          <h2 class="mt-1 font-serif text-2xl font-semibold">Mapping</h2>
          <.form
            for={@mapping_form}
            id="mapping-form"
            phx-submit="save_mapping"
            class="mt-5 grid gap-4 md:grid-cols-3"
          >
            <.input
              field={@mapping_form[:title]}
              type="select"
              label="Title column"
              options={column_options(@rows)}
              required
            />
            <.input
              field={@mapping_form[:isbn]}
              type="select"
              label="ISBN column"
              options={column_options(@rows)}
              required
            />
            <.input
              field={@mapping_form[:publisher]}
              type="select"
              label="Publisher column"
              options={column_options(@rows)}
              required
            />
            <div class="md:col-span-3 flex flex-wrap gap-2">
              <button class="rounded-sm border border-[#8C2D19] px-4 py-2 text-xs font-bold uppercase tracking-wider text-[#8C2D19]">
                Save mapping
              </button>
              <button
                id="dry-run-import"
                type="button"
                phx-click="dry_run"
                class="rounded-sm bg-stone-800 px-4 py-2 text-xs font-bold uppercase tracking-wider text-white"
              >
                Dry-run
              </button>
              <button
                id="apply-import"
                type="button"
                phx-click="apply"
                class="rounded-sm bg-[#8C2D19] px-4 py-2 text-xs font-bold uppercase tracking-wider text-white"
              >
                Apply accepted rows
              </button>
            </div>
          </.form>
        </div>

        <div id="dry-run-summary" class="grid gap-3 md:grid-cols-4">
          <.summary_card label="Rows" value={@summary.total} />
          <.summary_card label="Accepted" value={@summary.accepted} />
          <.summary_card label="Needs review" value={@summary.needs_review} />
          <.summary_card label="Applied" value={@summary.applied} />
        </div>
        <p class="sr-only">Accepted: {@summary.accepted}</p>
        <p class="sr-only">Needs review: {@summary.needs_review}</p>

        <div id="row-validation-list" class="space-y-3">
          <article
            :for={row <- @rows}
            id={"staged-row-#{row.id}"}
            class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-4 dark:border-[#2E2A27] dark:bg-[#1C1917]"
          >
            <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500">
              Row {row.row_number} · {row.status}
            </p>
            <h3 class="font-serif text-lg font-semibold">
              {payload_value(row, @current_mapping, "title") || "Untitled row"}
            </h3>
            <p class="text-sm text-stone-700 dark:text-stone-300">
              ISBN {payload_value(row, @current_mapping, "isbn") || "missing"} · {payload_value(
                row,
                @current_mapping,
                "publisher"
              ) ||
                "publisher missing"}
            </p>
          </article>
        </div>

        <div
          id="review-item-links"
          class="rounded-sm border border-[#E7E2D8] bg-[#F5F2EB] p-5 dark:border-[#2E2A27] dark:bg-[#12110F]"
        >
          <h2 class="font-serif text-xl font-semibold">Review items</h2>
          <p :if={@review_items == []} class="mt-2 text-sm text-stone-600 dark:text-stone-400">
            No review items for this import.
          </p>
          <ul class="mt-3 space-y-2">
            <li :for={item <- @review_items} id={"import-review-#{item.id}"}>
              <.link
                href={~p"/admin/review/#{item.id}"}
                class="text-sm font-bold text-[#8C2D19] hover:underline"
              >
                {item.message || "Review item"}
              </.link>
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :eyebrow, :string, required: true

  defp import_header(assigns) do
    ~H"""
    <div class="border-b border-[#E7E2D8] pb-5 dark:border-[#2E2A27]">
      <p class="font-mono text-xs uppercase tracking-wider text-stone-500">{@eyebrow}</p>
      <h1 class="mt-1 font-serif text-3xl font-medium text-stone-900 dark:text-stone-100">
        {@title}
      </h1>
      <div class="mt-3 flex flex-wrap gap-4 text-sm font-semibold text-[#8C2D19]">
        <.link navigate={~p"/admin/imports"}>All imports</.link>
        <.link navigate={~p"/admin/imports/new"}>New CSV import</.link>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-sm border border-[#E7E2D8] bg-[#FCFAF7] p-4 dark:border-[#2E2A27] dark:bg-[#1C1917]">
      <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500">{@label}</p>
      <p class="mt-1 font-serif text-2xl font-semibold">{@value}</p>
      <p class="sr-only">{@label}: {@value}</p>
    </div>
    """
  end

  defp page_title(:new), do: "New CSV import"
  defp page_title(:show), do: "Import detail"
  defp page_title(_action), do: "Imports"

  defp upload_csv(provider, file_name, content, actor) do
    ImportRun
    |> Ash.Changeset.for_create(:upload_csv, %{
      provider: provider,
      file_name: file_name,
      csv_content: content
    })
    |> Ash.create(actor: actor)
  end

  defp update_run(run, action, params, actor) do
    run
    |> Ash.Changeset.for_update(action, params)
    |> Ash.update(actor: actor)
  end

  defp load_run(id, actor) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         run when not is_nil(run) <- Ash.get(ImportRun, uuid, actor: actor) |> ok_or_nil() do
      {:ok, run}
    else
      _error -> :error
    end
  end

  defp ok_or_nil({:ok, run}), do: run
  defp ok_or_nil(_), do: nil

  defp assign_run(socket, run) do
    rows = rows_for(run.id)
    review_items = review_items_for(run.id)

    socket
    |> assign(:run, run)
    |> assign(:rows, rows)
    |> assign(:review_items, review_items)
    |> assign(:summary, summary(rows))
    |> assign(:current_mapping, existing_or_default_mapping(run.id, rows))
    |> assign(:mapping_form, to_form(existing_or_default_mapping(run.id, rows), as: :mapping))
  end

  defp import_runs(actor) do
    ImportRun
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&{&1.provider, &1.status, &1.id})
  end

  defp assign_import_runs(socket, actor) do
    runs = import_runs(actor)

    socket
    |> assign(:import_runs_count, length(runs))
    |> stream(:import_runs, runs, reset: true, dom_id: &"import-run-#{&1.id}")
  end

  defp rows_for(run_id) do
    StagedImportRow
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.import_run_id == run_id))
    |> Enum.sort_by(& &1.row_number)
  end

  defp review_items_for(run_id) do
    ReviewItem
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.import_run_id == run_id))
    |> Enum.sort_by(& &1.id)
  end

  defp existing_or_default_mapping(run_id, rows) do
    mappings =
      ImportMapping
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.import_run_id == run_id))
      |> Map.new(&{&1.target_field, &1.source_column})

    if mappings == %{}, do: default_mapping_from_rows(rows), else: mappings
  end

  defp default_mapping do
    %{"title" => "title", "isbn" => "isbn", "publisher" => "publisher"}
  end

  defp default_mapping_from_rows([]), do: default_mapping()

  defp default_mapping_from_rows([row | _]) do
    keys = Map.keys(row.raw_payload || %{})

    Map.new(@target_fields, fn field ->
      {field, if(field in keys, do: field, else: List.first(keys))}
    end)
  end

  defp column_options([]), do: Enum.map(@target_fields, &{&1, &1})

  defp column_options([row | _]) do
    row.raw_payload
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end

  defp summary(rows) do
    %{
      total: length(rows),
      accepted: Enum.count(rows, &(&1.status == "accepted")),
      needs_review: Enum.count(rows, &(&1.status == "needs_review")),
      applied: Enum.count(rows, &(&1.status == "applied"))
    }
  end

  defp payload_value(row, mapping, target_field) do
    source_column = Map.get(mapping, target_field, target_field)
    present((row.raw_payload || %{})[source_column])
  end

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(value), do: value

  defp field_value(form, field), do: present(form[field].value) || "local_csv"

  defp error_message(error) when is_binary(error), do: error
  defp error_message(%{errors: [%{message: message} | _]}), do: message
  defp error_message(error), do: Exception.message(error)

  defp upload_error(:too_large), do: "CSV upload must be 1 MiB or smaller"
  defp upload_error(:too_many_files), do: "Upload one CSV at a time"
  defp upload_error(:not_accepted), do: "Upload a .csv file"
  defp upload_error(error), do: inspect(error)
end
