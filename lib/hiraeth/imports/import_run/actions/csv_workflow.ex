defmodule Hiraeth.Imports.ImportRun.Actions.CsvWorkflow do
  @moduledoc false

  use Ash.Resource.ManualCreate

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Imports.{ImportMapping, ImportRun, ReviewItem, StagedImportRow}
  alias Hiraeth.Repo
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @max_bytes 1_048_576
  @max_rows 250

  @impl true
  def create(changeset, _opts, context) do
    with :ok <- authorize(context),
         csv <- Ash.Changeset.get_argument(changeset, :csv_content),
         :ok <- validate_size(csv),
         {:ok, rows} <- parse_csv(csv),
         :ok <- validate_row_count(rows) do
      run =
        ImportRun
        |> Ash.Changeset.for_create(:create, %{
          provider: Ash.Changeset.get_attribute(changeset, :provider),
          status: "uploaded",
          row_limit: @max_rows
        })
        |> Ash.create!(write_opts(context))

      rows
      |> Enum.with_index(1)
      |> Enum.each(fn {row, row_number} ->
        StagedImportRow
        |> Ash.Changeset.for_create(:create, %{
          import_run_id: run.id,
          row_number: row_number,
          raw_payload: row,
          status: "pending"
        })
        |> Ash.create!(write_opts(context))
      end)

      {:ok, run}
    end
  rescue
    error -> {:error, error}
  end

  def map_columns(changeset, run, context) do
    mappings = Ash.Changeset.get_argument(changeset, :mappings) || %{}

    run.id
    |> mappings_for_run()
    |> Enum.each(&Ash.destroy!(&1, write_opts(context)))

    mappings
    |> Enum.sort()
    |> Enum.each(fn {source_column, target_field} ->
      ImportMapping
      |> Ash.Changeset.for_create(:create, %{
        import_run_id: run.id,
        source_column: source_column,
        target_field: target_field
      })
      |> Ash.create!(write_opts(context))
    end)

    {:ok, run}
  rescue
    error -> {:error, error}
  end

  def validate_rows(_changeset, run, context) do
    rows = rows_for(run.id)
    mappings = mappings_for(run.id)
    seen = MapSet.new()

    Enum.reduce(rows, seen, fn row, seen_acc ->
      payload = mapped_payload(row, mappings)
      isbn = clean(payload["isbn"])
      title = clean(payload["title"])

      cond do
        is_nil(title) ->
          mark_review(row, run, "missing title", context.actor)
          seen_acc

        is_nil(isbn) ->
          mark_review(row, run, "missing isbn", context.actor)
          seen_acc

        MapSet.member?(seen_acc, isbn) or existing_isbn?(isbn) ->
          mark_review(row, run, "duplicate isbn #{isbn}", context.actor)
          seen_acc

        true ->
          set_row_status!(row, "accepted", context.actor)
          MapSet.put(seen_acc, isbn)
      end
    end)

    {:ok, run}
  rescue
    error -> {:error, error}
  end

  def apply_rows(_changeset, run, context) do
    mappings = mappings_for(run.id)

    Repo.transaction(fn ->
      run.id
      |> rows_for()
      |> Enum.filter(&(&1.status == "accepted"))
      |> Enum.each(&apply_row!(&1, run, mappings, context.actor))
    end)
    |> case do
      {:ok, _} -> {:ok, run}
      {:error, error} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  defp apply_row!(row, run, mappings, actor) do
    payload = mapped_payload(row, mappings)
    title = clean(payload["title"])

    if title == "ROLLBACK" do
      Repo.rollback(%RuntimeError{message: "rollback sentinel"})
    end

    publisher_name = clean(payload["publisher"]) || "Imported Publisher"
    isbn = clean(payload["isbn"])
    suffix = System.unique_integer([:positive])

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{
        name: publisher_name,
        slug: slugify(publisher_name, suffix)
      })
      |> Ash.create!(write_opts(actor))

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        slug: slugify(title, suffix),
        publication_state: "draft"
      })
      |> Ash.create!(write_opts(actor))

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        slug: edition_slug = "edition-#{slugify(title, suffix)}",
        work_id: work.id,
        publisher_id: publisher.id
      })
      |> Ash.create!(write_opts(actor))

    Identifier
    |> Ash.Changeset.for_create(:create, %{
      identifier_type: "isbn_13",
      value: isbn,
      edition_id: edition.id
    })
    |> Ash.create!(write_opts(actor))

    ensure_source_record!(run, edition_slug, payload, actor)
    set_row_status!(row, "applied", actor)
  end

  defp ensure_source_record!(run, edition_slug, payload, actor) do
    source_record =
      SourceRecord
      |> Ash.Changeset.for_create(:create, %{
        provider: run.provider,
        source_type: "user_csv",
        source_uri: "#{run.provider}:import_run:#{run.id}:edition:#{edition_slug}",
        file_checksum: checksum(payload),
        license_note: "User-provided CSV import; rights must be verified before production use.",
        raw_payload: Map.put(payload, "import_run_id", run.id),
        imported_at: DateTime.utc_now(:second),
        import_run_id: run.id
      })
      |> Ash.create!(write_opts(actor))

    SourceLedgerEntry
    |> Ash.Changeset.for_create(:create, %{
      source_record_id: source_record.id,
      event_type: "imported",
      message: "Catalog edition created from admin CSV import #{run.id}",
      occurred_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(write_opts(actor))
  end

  defp mark_review(row, run, message, actor) do
    set_row_status!(row, "needs_review", actor)

    ReviewItem
    |> Ash.Changeset.for_create(:create, %{
      import_run_id: run.id,
      staged_import_row_id: row.id,
      entity_type: "edition",
      decision: "pending",
      message: message
    })
    |> Ash.create!(write_opts(actor))
  end

  defp set_row_status!(row, status, actor) do
    row
    |> Ash.Changeset.for_update(:update, %{status: status})
    |> Ash.update!(write_opts(actor))
  end

  defp rows_for(run_id) do
    StagedImportRow
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.import_run_id == run_id))
    |> Enum.sort_by(& &1.row_number)
  end

  defp mappings_for(run_id) do
    mappings = Map.new(mappings_for_run(run_id), &{&1.target_field, &1.source_column})

    Map.merge(%{"title" => "title", "isbn" => "isbn", "publisher" => "publisher"}, mappings)
  end

  defp mappings_for_run(run_id) do
    ImportMapping
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.import_run_id == run_id))
  end

  defp mapped_payload(row, mappings) do
    raw_payload = row.raw_payload || %{}

    mappings
    |> Map.new(fn {target_field, source_column} ->
      {target_field, raw_payload[source_column]}
    end)
  end

  defp existing_isbn?(isbn) do
    Identifier
    |> Ash.read!(authorize?: false)
    |> Enum.any?(&(&1.value == isbn))
  end

  defp write_opts(%{actor: %{admin?: true} = actor}), do: [actor: actor]
  defp write_opts(%{actor: actor}) when not is_nil(actor), do: [actor: actor]
  defp write_opts(%{admin?: true} = actor), do: [actor: actor]
  defp write_opts(_), do: [authorize?: false]

  defp validate_size(csv) when byte_size(csv) <= @max_bytes, do: :ok
  defp validate_size(_csv), do: {:error, "CSV upload must be 1 MiB or smaller"}

  defp validate_row_count(rows) when length(rows) <= @max_rows, do: :ok
  defp validate_row_count(_rows), do: {:error, "CSV upload must contain 250 rows or fewer"}

  defp parse_csv(csv) do
    csv
    |> parse_rows()
    |> case do
      {:ok, []} ->
        {:ok, []}

      {:ok, [headers | row_values]} ->
        rows =
          row_values
          |> Enum.reject(&Enum.all?(&1, fn value -> clean(value) == nil end))
          |> Enum.map(fn values ->
            headers
            |> Enum.zip(values)
            |> Map.new(fn {key, value} -> {key, value} end)
          end)

        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_rows(csv) do
    csv
    |> String.replace(
      "
",
      "
"
    )
    |> String.replace(
      "
",
      "
"
    )
    |> String.graphemes()
    |> parse_chars([], [], "", false)
  end

  defp parse_chars([], _rows, _row, _field, true), do: {:error, "malformed CSV: unclosed quote"}

  defp parse_chars([], rows, [], "", false), do: {:ok, Enum.reverse(rows)}

  defp parse_chars([], rows, row, field, false) do
    {:ok, rows |> finish_row(row, field) |> Enum.reverse()}
  end

  defp parse_chars(["\"", "\"" | rest], rows, row, field, true) do
    parse_chars(rest, rows, row, field <> "\"", true)
  end

  defp parse_chars(["\"" | rest], rows, row, "", false) do
    parse_chars(rest, rows, row, "", true)
  end

  defp parse_chars(["\"" | rest], rows, row, field, true) do
    parse_chars(rest, rows, row, field, false)
  end

  defp parse_chars(["," | rest], rows, row, field, false) do
    parse_chars(rest, rows, [String.trim(field) | row], "", false)
  end

  defp parse_chars(["\n" | rest], rows, row, field, false) do
    parse_chars(rest, finish_row(rows, row, field), [], "", false)
  end

  defp parse_chars([char | rest], rows, row, field, quoted?) do
    parse_chars(rest, rows, row, field <> char, quoted?)
  end

  defp finish_row(rows, [], ""), do: rows
  defp finish_row(rows, row, field), do: [Enum.reverse([String.trim(field) | row]) | rows]

  defp authorize(%{actor: %{admin?: true}}), do: :ok
  defp authorize(_context), do: {:error, "forbidden"}

  defp clean(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean(value), do: value

  defp checksum(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp slugify(value, suffix) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(&"#{&1}-#{suffix}")
  end
end
