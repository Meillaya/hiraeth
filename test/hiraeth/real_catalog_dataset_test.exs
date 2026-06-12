defmodule Hiraeth.RealCatalogDatasetTest do
  use ExUnit.Case, async: true

  alias Hiraeth.RealCatalog.{Dataset, Validator}

  @dataset_dir Path.expand("../../priv/catalog_sources/real_publishers", __DIR__)
  @expected_files %{
    "deep_vellum_official_store" => "deep_vellum.json",
    "dalkey_archive_official_store" => "dalkey_archive.json",
    "archipelago_books_official_store" => "archipelago_books.json"
  }

  describe "real publisher dataset contract" do
    test "tracked dataset files exist for the three approved publishers" do
      assert File.dir?(@dataset_dir)
      assert File.exists?(Path.join(@dataset_dir, "README.md"))
      assert File.exists?(Path.join(@dataset_dir, "schema.json"))

      for filename <- Map.values(@expected_files) do
        assert File.exists?(Path.join(@dataset_dir, filename))
      end
    end

    test "approved real-publisher files validate with exactly 50 records each" do
      assert {:ok, summary} = Validator.validate_dir(@dataset_dir)

      assert Map.keys(summary.providers) |> Enum.sort() ==
               Map.keys(@expected_files) |> Enum.sort()

      for {provider, filename} <- @expected_files do
        assert %{file: ^filename, record_count: 50, approved_count: 50} =
                 summary.providers[provider]
      end

      assert summary.total_records == 150
      assert summary.duplicate_isbns == []
      assert summary.copy_risk_findings == []
      assert summary.cover_findings == []
    end

    test "loaded records contain only approved display and prose fields" do
      assert {:ok, datasets} = Dataset.load_dir(@dataset_dir)

      rejected_keys =
        ~w(blurb bio author_bio review reviews user_review user_reviews jacket_copy price inventory availability cart checkout account body_html content excerpt html rendered_html)

      allowed_displayed_fields =
        ~w(title subtitle contributors publisher imprint format published_on isbn_13 cover source_url description synopsis editorial_praise storefront_url)

      for dataset <- datasets,
          record <- dataset.records do
        flattened_keys = record |> flatten_keys() |> Enum.map(&String.downcase/1)
        refute Enum.any?(flattened_keys, &(&1 in rejected_keys))

        assert Enum.all?(record.displayed_fields, &(&1 in allowed_displayed_fields))
        assert record.curation.status == "approved"
      end
    end

    test "tracked publisher fixtures include curated prose where official snippets are available" do
      assert {:ok, datasets} = Dataset.load_dir(@dataset_dir)

      for dataset <- datasets do
        prose_records = Enum.filter(dataset.records, &Map.has_key?(&1, :description))
        assert length(prose_records) >= 1
        assert get_in(dataset, [:prose_curation, :records_with_prose]) == length(prose_records)

        for record <- prose_records do
          assert record.description |> String.length() |> Kernel.>(20)
          assert record.storefront_url == record.source_uri
          assert "description" in record.displayed_fields
          assert "storefront_url" in record.displayed_fields
          assert String.contains?(record.curation.notes, "Prose snippet curated from")
        end
      end
    end

    test "schema mirrors validator unsafe field contract" do
      schema =
        @dataset_dir
        |> Path.join("schema.json")
        |> File.read!()
        |> Jason.decode!()

      forbidden_fields =
        schema
        |> get_in(["properties", "records", "items", "not", "anyOf"])
        |> Enum.map(&get_in(&1, ["required"]))
        |> List.flatten()
        |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new(
                 ~w(price inventory availability cart checkout account body_html content excerpt html rendered_html blurb bio author_bio review reviews user_review user_reviews jacket_copy)
               ),
               forbidden_fields
             )

      assert get_in(schema, ["properties", "records", "items", "additionalProperties"]) == false
    end

    test "approved records may include sourced public prose, editorial praise, and storefront CTAs" do
      assert {:ok, [dataset | _datasets]} = Dataset.load_dir(@dataset_dir)
      [record | remaining_records] = dataset.records

      prose_record =
        record
        |> Map.put(:description, "A sourced publisher synopsis for public book detail display.")
        |> Map.put(:storefront_url, record.source_uri)
        |> Map.put(:editorial_praise, [
          %{
            "quote" => "A precise, source-attributed editorial praise excerpt.",
            "source" => "Publisher official page",
            "source_uri" => record.source_uri
          }
        ])
        |> Map.update!(:displayed_fields, fn fields ->
          Enum.uniq(fields ++ ["description", "editorial_praise", "storefront_url"])
        end)

      assert {:ok, _summary} =
               Validator.validate_datasets([
                 %{dataset | records: [prose_record | remaining_records]}
               ])
    end

    test "rejects public prose when source provenance is missing" do
      assert {:ok, [dataset | _datasets]} = Dataset.load_dir(@dataset_dir)
      [record | remaining_records] = dataset.records

      prose_without_provenance =
        record
        |> Map.put(:source_uri, "")
        |> Map.put(:description, "A public synopsis without a source URI must not be accepted.")
        |> Map.put(:storefront_url, "")
        |> Map.put(:editorial_praise, [
          %{"quote" => "Praise without field-level source evidence.", "source" => "Unknown"}
        ])
        |> Map.update!(:displayed_fields, fn fields ->
          Enum.uniq(fields ++ ["description", "editorial_praise", "storefront_url"])
        end)

      assert {:error, findings} =
               Validator.validate_datasets([
                 %{
                   dataset
                   | license_note: "",
                     records: [prose_without_provenance | remaining_records]
                 }
               ])

      assert "public prose requires source provenance" in Enum.map(findings, & &1.reason)
    end
  end

  describe "dataset validator rejects unsafe rows" do
    test "rejects invalid ISBN, non-HTTPS cover, long copied text, duplicate ISBN, and non-book rows" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "hiraeth-bad-real-catalog-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      File.write!(Path.join(tmp, "schema.json"), "{}")
      File.write!(Path.join(tmp, "README.md"), "bad fixture")

      bad_record = %{
        "source_uri" => "https://example.test/book",
        "source_product_id" => "bad-1",
        "publisher" => "Deep Vellum",
        "work" => %{"title" => "Unsafe Bundle", "publication_state" => "published"},
        "edition" => %{
          "title" => "Unsafe Bundle",
          "format" => "bundle",
          "published_on" => "2026-01-01",
          "isbn_13" => "9781953861405"
        },
        "contributors" => [%{"name" => "Ada Example", "role" => "author"}],
        "cover" => %{
          "source_url" => "http://cdn.shopify.com/s/files/1/0433/1651/0883/files/bad.jpg",
          "provider" => "deep_vellum_official_store",
          "rights_basis" => "publisher_store_link_only",
          "attribution_text" => "Example",
          "attribution_url" => "https://example.test/book",
          "cache_policy" => "link_only"
        },
        "jacket_copy" => String.duplicate("publisher marketing copy ", 20),
        "displayed_fields" => ["title", "jacket_copy", "cover"],
        "curation" => %{"status" => "approved", "notes" => "bad"}
      }

      invalid_isbn_record = put_in(bad_record, ["edition", "isbn_13"], "9780000000000")

      payload = %{
        "provider" => "deep_vellum_official_store",
        "retrieved_at" => "2026-06-12T00:00:00Z",
        "license_note" => "test",
        "records" => [bad_record, bad_record, invalid_isbn_record]
      }

      File.write!(Path.join(tmp, "deep_vellum.json"), Jason.encode!(payload, pretty: true))

      assert {:error, findings} = Validator.validate_dir(tmp)
      reasons = Enum.map(findings, & &1.reason)

      assert "invalid isbn_13 check digit" in reasons
      assert "duplicate isbn_13" in reasons
      assert "cover source_url must be HTTPS" in reasons
      assert "non-book format is not allowed" in reasons
      assert "long copied text or disallowed prose field is present" in reasons
      assert "displayed field is not factual metadata" in reasons
    end

    test "still rejects commerce state and unsafe source content when prose metadata is allowed" do
      assert {:ok, [dataset | _datasets]} = Dataset.load_dir(@dataset_dir)
      [record | remaining_records] = dataset.records

      raw_html_prose_record =
        record
        |> Map.put(:description, "<p>Raw source HTML should not be accepted.</p>")
        |> Map.put(:storefront_url, record.source_uri)
        |> Map.update!(:displayed_fields, fn fields ->
          Enum.uniq(fields ++ ["description", "storefront_url"])
        end)

      assert {:error, raw_html_findings} =
               Validator.validate_datasets([
                 %{dataset | records: [raw_html_prose_record | remaining_records]}
               ])

      assert "raw HTML or executable content is not allowed in public prose" in Enum.map(
               raw_html_findings,
               & &1.reason
             )

      unsafe_record =
        record
        |> Map.put(:price, "$18.00")
        |> Map.put(:inventory, "12")
        |> Map.put(:availability, "in stock")
        |> Map.put(:cart, "https://archipelagobooks.org/cart")
        |> Map.put(:checkout, "https://archipelagobooks.org/checkout")
        |> Map.put(:account, "https://archipelagobooks.org/account")
        |> Map.put(:content, String.duplicate("unapproved content dump ", 20))
        |> Map.put(:body_html, "<script>alert('xss')</script>")

      assert {:error, findings} =
               Validator.validate_datasets([
                 %{dataset | records: [unsafe_record | remaining_records]}
               ])

      assert "commerce state is not public catalog metadata" in Enum.map(findings, & &1.reason)

      assert "raw HTML or executable content is not allowed in public prose" in Enum.map(
               findings,
               & &1.reason
             )
    end

    test "rejects HTTPS cover URLs from hosts outside the provider allowlist" do
      tmp =
        write_dataset_fixture("bad-cover-host", [
          record_fixture(%{"cover_url" => "https://evil.example.test/cover.jpg"})
        ])

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)

      assert "cover source_url host is not allowlisted for provider" in Enum.map(
               findings,
               & &1.reason
             )
    end

    test "rejects blank required identity fields and unapproved curation status" do
      record =
        record_fixture(%{})
        |> Map.put("source_uri", "")
        |> Map.put("publisher", "")
        |> Map.put("contributors", [])
        |> put_in(["work", "title"], "")
        |> put_in(["edition", "title"], "")
        |> put_in(["curation", "status"], "pending")

      tmp = write_dataset_fixture("bad-required-fields", [record], "")
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)
      reasons = Enum.map(findings, & &1.reason)

      assert "provider is required" in reasons
      assert "source_uri is required" in reasons
      assert "publisher is required" in reasons
      assert "work title is required" in reasons
      assert "edition title is required" in reasons
      assert "at least one contributor is required" in reasons
      assert "curation status must be approved" in reasons
    end

    test "rejects non-HTTPS and non-provider source URIs" do
      for {source_uri, reason} <- [
            {"http://store.deepvellum.org/products/not-https", "source_uri must be HTTPS"},
            {
              "https://unapproved.example.test/products/not-official",
              "source_uri host is not allowlisted for provider"
            }
          ] do
        record = Map.put(record_fixture(%{}), "source_uri", source_uri)
        tmp = write_dataset_fixture("bad-source-uri", [record])
        on_exit(fn -> File.rm_rf!(tmp) end)

        assert {:error, findings} = Validator.validate_dir(tmp)
        assert reason in Enum.map(findings, & &1.reason)
      end
    end

    test "allows explicit no-cover reasons and rejects missing cover fallback evidence" do
      assert {:ok, [dataset | _datasets]} = Dataset.load_dir(@dataset_dir)
      [record | remaining_records] = dataset.records

      approved_no_cover_record =
        record
        |> Map.delete(:cover)
        |> Map.put(:no_cover_reason, "Official public source exposes no cover image.")
        |> Map.update!(:displayed_fields, &List.delete(&1, "cover"))

      approved_no_cover_dataset = %{
        dataset
        | records: [approved_no_cover_record | remaining_records]
      }

      assert {:ok, _summary} = Validator.validate_datasets([approved_no_cover_dataset])

      missing_cover_record = Map.delete(record, :cover)
      missing_cover_dataset = %{dataset | records: [missing_cover_record | remaining_records]}

      assert {:error, findings} = Validator.validate_datasets([missing_cover_dataset])

      assert "cover source_url or no_cover_reason is required" in Enum.map(
               findings,
               & &1.reason
             )
    end

    test "rejects displayed fields whose factual value is missing" do
      record =
        record_fixture(%{})
        |> put_in(["edition", "published_on"], nil)

      tmp = write_dataset_fixture("bad-missing-displayed-value", [record])
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)
      assert "displayed field value is missing" in Enum.map(findings, & &1.reason)
    end

    test "rejects files that do not contain exactly 50 approved records" do
      tmp = write_dataset_fixture("bad-count", [record_fixture(%{})])
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)
      assert "dataset must contain exactly 50 approved records" in Enum.map(findings, & &1.reason)
    end

    test "rejects unknown edition formats" do
      tmp = write_dataset_fixture("bad-unknown-format", [record_fixture(%{"format" => "banana"})])
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)
      assert "edition format is not valid" in Enum.map(findings, & &1.reason)
    end

    test "rejects supporter-only SKUs even when the edition format is otherwise valid" do
      tmp =
        write_dataset_fixture("bad-supporter-sku", [
          record_fixture(%{"source_sku" => "Dalkey Supporter"})
        ])

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)
      assert "supporter-only SKU is not allowed" in Enum.map(findings, & &1.reason)
    end

    test "rejects every disallowed non-book product type" do
      for {format, reason} <- [
            {"bundle", "non-book format is not allowed"},
            {"subscription", "non-book format is not allowed"},
            {"gift_card", "non-book format is not allowed"},
            {"merch", "non-book format is not allowed"},
            {"shirt", "non-book format is not allowed"},
            {"supporter_only", "non-book format is not allowed"}
          ] do
        tmp =
          write_dataset_fixture("bad-format-#{format}", [record_fixture(%{"format" => format})])

        on_exit(fn -> File.rm_rf!(tmp) end)

        assert {:error, findings} = Validator.validate_dir(tmp)
        assert reason in Enum.map(findings, & &1.reason)
      end
    end

    test "rejects duplicate ISBNs across publisher files" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "hiraeth-cross-duplicate-real-catalog-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      File.write!(Path.join(tmp, "schema.json"), "{}")
      File.write!(Path.join(tmp, "README.md"), "cross duplicate fixture")

      duplicate_isbn = "9781953861405"

      write_provider_file(tmp, "deep_vellum.json", "deep_vellum_official_store", [
        record_fixture(%{"isbn_13" => duplicate_isbn, "title" => "Deep Duplicate"})
      ])

      write_provider_file(tmp, "dalkey_archive.json", "dalkey_archive_official_store", [
        record_fixture(%{
          "isbn_13" => duplicate_isbn,
          "title" => "Dalkey Duplicate",
          "publisher" => "Dalkey Archive",
          "provider" => "dalkey_archive_official_store",
          "cover_url" => "https://cdn.shopify.com/s/files/1/0594/2915/9067/files/duplicate.jpg"
        })
      ])

      assert {:error, findings} = Validator.validate_dir(tmp)
      assert "duplicate isbn_13" in Enum.map(findings, & &1.reason)
    end

    test "rejects duplicate ISBNs after normalization" do
      tmp =
        write_dataset_fixture("bad-normalized-duplicate-isbn", [
          record_fixture(%{"isbn_13" => "9781953861405", "title" => "Plain ISBN"}),
          record_fixture(%{"isbn_13" => "978-1-953861-40-5", "title" => "Hyphenated ISBN"})
        ])

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, findings} = Validator.validate_dir(tmp)
      assert "duplicate isbn_13" in Enum.map(findings, & &1.reason)
    end
  end

  defp write_dataset_fixture(name, records, provider \\ "deep_vellum_official_store") do
    tmp = Path.join(System.tmp_dir!(), "hiraeth-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "schema.json"), "{}")
    File.write!(Path.join(tmp, "README.md"), name)
    write_provider_file(tmp, "deep_vellum.json", provider, records)
    tmp
  end

  defp write_provider_file(dir, filename, provider, records) do
    payload = %{
      "provider" => provider,
      "retrieved_at" => "2026-06-12T00:00:00Z",
      "license_note" => "test",
      "records" => records
    }

    File.write!(Path.join(dir, filename), Jason.encode!(payload, pretty: true))
  end

  defp record_fixture(overrides) do
    provider = Map.get(overrides, "provider", "deep_vellum_official_store")
    title = Map.get(overrides, "title", "Safe Test Book")
    isbn = Map.get(overrides, "isbn_13", "9781953861405")
    publisher = Map.get(overrides, "publisher", "Deep Vellum")
    format = Map.get(overrides, "format", "paperback")

    cover_url =
      Map.get(
        overrides,
        "cover_url",
        "https://cdn.shopify.com/s/files/1/0433/1651/0883/files/safe.jpg"
      )

    %{
      "source_uri" => "https://example.test/book/#{System.unique_integer([:positive])}",
      "source_product_id" => "fixture-#{System.unique_integer([:positive])}",
      "source_sku" => Map.get(overrides, "source_sku", isbn),
      "publisher" => publisher,
      "work" => %{"title" => title, "publication_state" => "published"},
      "edition" => %{
        "title" => title,
        "format" => format,
        "published_on" => "2026-01-01",
        "isbn_13" => isbn
      },
      "contributors" => [%{"name" => "Ada Example", "role" => "author"}],
      "cover" => %{
        "source_url" => cover_url,
        "provider" => provider,
        "rights_basis" => "publisher_store_link_only",
        "attribution_text" => "Example",
        "attribution_url" => "https://example.test/book",
        "cache_policy" => "link_only"
      },
      "displayed_fields" => [
        "title",
        "contributors",
        "publisher",
        "format",
        "published_on",
        "isbn_13",
        "cover"
      ],
      "curation" => %{"status" => "approved", "notes" => "fixture"}
    }
  end

  defp flatten_keys(term), do: flatten_keys(term, [])

  defp flatten_keys(%_struct{} = struct, acc),
    do: struct |> Map.from_struct() |> flatten_keys(acc)

  defp flatten_keys(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, keys ->
      flatten_keys(value, [to_string(key) | keys])
    end)
  end

  defp flatten_keys(list, acc) when is_list(list), do: Enum.reduce(list, acc, &flatten_keys/2)
  defp flatten_keys(_value, acc), do: acc
end
