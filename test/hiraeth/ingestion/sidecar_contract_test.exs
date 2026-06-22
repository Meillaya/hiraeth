defmodule Hiraeth.Ingestion.SidecarContractTest do
  @moduledoc """
  Contract tests for the Scrapling FastAPI sidecar API.

  These tests verify the request/response schemas and error contracts
  of the sidecar endpoints without depending on the sidecar process.
  They use deterministic fixture JSON and Req.Test mocking.
  """

  use ExUnit.Case, async: true

  alias Hiraeth.Ingestion.SidecarClient

  # ---------------------------------------------------------------------------
  # Deterministic fixtures: complete BookRecord shapes returned by the sidecar
  # ---------------------------------------------------------------------------

  @shopify_record %{
    "provider" => "deep_vellum",
    "source_uri" => "https://deepvellum.org/products/test-book",
    "work" => %{
      "title" => "Test Book One",
      "subtitle" => "A Subtitle",
      "original_title" => nil,
      "original_language_code" => nil,
      "subjects" => ["fiction", "poetry"]
    },
    "edition" => %{
      "title" => "Test Book One",
      "subtitle" => "A Subtitle",
      "format" => "paperback",
      "published_on" => "2026-01-15",
      "isbn_13" => "9780000000019",
      "language_code" => "eng",
      "page_count" => 256,
      "dimensions" => nil
    },
    "contributors" => [
      %{"name" => "Author One", "role" => "author"},
      %{"name" => "Translator One", "role" => "translator"}
    ],
    "cover" => %{
      "source_url" => "https://deepvellum.org/covers/test-book.jpg",
      "rights_basis" => "provider_link_allowed",
      "attribution_text" => "Cover image courtesy of Deep Vellum"
    },
    "field_sources" => %{
      "title" => %{
        "provider" => "deep_vellum",
        "source_uri" => "https://deepvellum.org/products/test-book",
        "source_type" => "publisher_api",
        "rights_basis" => "Test fixture."
      }
    }
  }

  @woocommerce_record %{
    "provider" => "unnamed_press",
    "source_uri" => "https://unnamedpress.org/product/test-book-2",
    "work" => %{
      "title" => "Test Book Two",
      "subtitle" => nil,
      "original_title" => nil,
      "original_language_code" => nil,
      "subjects" => ["nonfiction"]
    },
    "edition" => %{
      "title" => "Test Book Two",
      "subtitle" => nil,
      "format" => "hardcover",
      "published_on" => "2026-02-20",
      "isbn_13" => "9780000000026",
      "language_code" => "eng",
      "page_count" => nil,
      "dimensions" => nil
    },
    "contributors" => [
      %{"name" => "Author Two", "role" => "author"}
    ],
    "cover" => %{
      "source_url" => "https://unnamedpress.org/covers/test-book-2.jpg",
      "rights_basis" => "provider_link_allowed",
      "attribution_text" => "Cover image courtesy of Unnamed Press"
    },
    "field_sources" => %{}
  }

  @scrape_record %{
    "provider" => "tilted_axis",
    "source_uri" => "https://tiltedaxispress.org/books/test-book-3",
    "work" => %{
      "title" => "Test Book Three",
      "subtitle" => nil,
      "original_title" => "Libro de Prueba Tres",
      "original_language_code" => "spa",
      "subjects" => ["fiction", "literary"]
    },
    "edition" => %{
      "title" => "Test Book Three",
      "subtitle" => nil,
      "format" => "paperback",
      "published_on" => "2026-03-10",
      "isbn_13" => "9780000000033",
      "language_code" => "eng",
      "page_count" => 320,
      "dimensions" => nil
    },
    "contributors" => [
      %{"name" => "Author Three", "role" => "author"}
    ],
    "cover" => %{
      "source_url" => "https://tiltedaxispress.org/covers/test-book-3.jpg",
      "rights_basis" => "provider_link_allowed",
      "attribution_text" => "Cover image courtesy of Tilted Axis"
    },
    "field_sources" => %{
      "title" => %{
        "provider" => "tilted_axis",
        "source_uri" => "https://tiltedaxispress.org/books/test-book-3",
        "source_type" => "scrapling_spider",
        "rights_basis" => "Test fixture."
      }
    }
  }

  # ---------------------------------------------------------------------------
  # 1. Health endpoint contract
  # ---------------------------------------------------------------------------

  describe "health endpoint contract" do
    test "returns expected schema: status ok and scrapling true" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/health/"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "ok", "scrapling" => true}))
      end

      assert {:ok, %{status: "ok", scrapling: true}} =
               SidecarClient.health(req_options: [plug: plug])
    end
  end

  # ---------------------------------------------------------------------------
  # 2–3. Fetch endpoint contract
  # ---------------------------------------------------------------------------

  describe "fetch endpoint contract" do
    test "shopify config returns BookRecord list with correct fields" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/fetch/"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Request contract: must contain provider and config with api.type
        assert decoded["provider"] == "deep_vellum"
        assert is_map(decoded["config"])
        assert decoded["config"]["api"]["type"] == "shopify"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "provider" => "deep_vellum",
            "status" => "success",
            "records" => [@shopify_record]
          })
        )
      end

      assert {:ok, %{records: [record]}} =
               SidecarClient.fetch(
                 %{
                   provider: "deep_vellum",
                   config: %{api: %{type: "shopify", endpoint: "https://deepvellum.org"}}
                 },
                 req_options: [plug: plug]
               )

      # Verify complete BookRecord schema contract
      assert record["provider"] == "deep_vellum"
      assert record["source_uri"] == "https://deepvellum.org/products/test-book"

      assert is_map(record["work"])
      assert record["work"]["title"] == "Test Book One"
      assert record["work"]["subtitle"] == "A Subtitle"
      assert record["work"]["original_title"] == nil
      assert record["work"]["original_language_code"] == nil
      assert record["work"]["subjects"] == ["fiction", "poetry"]

      assert is_map(record["edition"])
      assert record["edition"]["title"] == "Test Book One"
      assert record["edition"]["format"] == "paperback"
      assert record["edition"]["published_on"] == "2026-01-15"
      assert record["edition"]["isbn_13"] == "9780000000019"
      assert record["edition"]["language_code"] == "eng"
      assert record["edition"]["page_count"] == 256

      assert is_list(record["contributors"])
      assert [%{"name" => "Author One", "role" => "author"} | _] = record["contributors"]

      assert is_map(record["cover"])
      assert record["cover"]["source_url"] == "https://deepvellum.org/covers/test-book.jpg"
      assert record["cover"]["rights_basis"] == "provider_link_allowed"
      assert record["cover"]["attribution_text"] == "Cover image courtesy of Deep Vellum"

      assert is_map(record["field_sources"])
      assert get_in(record, ["field_sources", "title", "source_type"]) == "publisher_api"
    end

    test "woocommerce config returns BookRecord list" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/fetch/"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["provider"] == "unnamed_press"
        assert decoded["config"]["api"]["type"] == "woocommerce"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "provider" => "unnamed_press",
            "status" => "success",
            "records" => [@woocommerce_record]
          })
        )
      end

      assert {:ok, %{records: [record]}} =
               SidecarClient.fetch(
                 %{
                   provider: "unnamed_press",
                   config: %{
                     api: %{type: "woocommerce", endpoint: "https://unnamedpress.org"}
                   }
                 },
                 req_options: [plug: plug]
               )

      assert record["provider"] == "unnamed_press"
      assert record["work"]["title"] == "Test Book Two"
      assert record["edition"]["format"] == "hardcover"
      assert record["edition"]["isbn_13"] == "9780000000026"
      assert record["contributors"] == [%{"name" => "Author Two", "role" => "author"}]
    end

    test "invalid provider config returns 400 with error message" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/fetch/"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["provider"] == "bad_provider"
        assert decoded["config"]["api"]["type"] == "unsupported_api"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{"detail" => "Unsupported api.type: unsupported_api"})
        )
      end

      assert {:error, "sidecar fetch failed with status 400"} =
               SidecarClient.fetch(
                 %{
                   provider: "bad_provider",
                   config: %{api: %{type: "unsupported_api"}}
                 },
                 req_options: [plug: plug]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Scrape endpoint contract
  # ---------------------------------------------------------------------------

  describe "scrape endpoint contract" do
    test "spider config returns BookRecord list" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/scrape/"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Request contract: must contain provider and spider config
        assert decoded["provider"] == "tilted_axis"
        assert is_map(decoded["config"])
        assert decoded["config"]["start_urls"] == ["https://tiltedaxispress.org/books"]
        assert is_map(decoded["config"]["selectors"])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "provider" => "tilted_axis",
            "status" => "success",
            "records" => [@scrape_record]
          })
        )
      end

      assert {:ok, %{records: [record]}} =
               SidecarClient.scrape(
                 %{
                   provider: "tilted_axis",
                   config: %{
                     start_urls: ["https://tiltedaxispress.org/books"],
                     selectors: %{
                       item: ".book-item",
                       title: ".title",
                       author: ".author"
                     }
                   }
                 },
                 req_options: [plug: plug]
               )

      assert record["provider"] == "tilted_axis"
      assert record["work"]["original_title"] == "Libro de Prueba Tres"
      assert record["work"]["original_language_code"] == "spa"
      assert record["edition"]["page_count"] == 320
      assert record["cover"]["source_url"] == "https://tiltedaxispress.org/covers/test-book-3.jpg"
    end
  end

  # ---------------------------------------------------------------------------
  # 5–6. Error handling contract
  # ---------------------------------------------------------------------------

  describe "error handling contract" do
    test "sidecar timeout returns timeout error" do
      Req.Test.stub(:contract_timeout, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, "timeout"} =
               SidecarClient.health(req_options: [plug: {Req.Test, :contract_timeout}])
    end
  end
end
