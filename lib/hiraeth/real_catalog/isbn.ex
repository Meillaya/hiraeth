defmodule Hiraeth.RealCatalog.ISBN do
  @moduledoc """
  ISBN-13 normalization and check digit validation for real catalog datasets.
  """

  def normalize(value) when is_binary(value) do
    digits = String.replace(value, ~r/[^0-9]/, "")

    if valid_isbn13?(digits), do: {:ok, digits}, else: {:error, :invalid_isbn_13}
  end

  def normalize(_value), do: {:error, :invalid_isbn_13}

  def normalize!(value) do
    case normalize(value) do
      {:ok, isbn} -> isbn
      {:error, reason} -> raise ArgumentError, "invalid ISBN-13: #{inspect(reason)}"
    end
  end

  def valid_isbn13?(<<_::binary-size(13)>> = isbn) do
    if String.match?(isbn, ~r/^97[89]\d{10}$/) do
      {check_digit, body} = isbn |> String.graphemes() |> List.pop_at(12)

      sum =
        body
        |> Enum.with_index()
        |> Enum.reduce(0, fn {digit, index}, acc ->
          weight = if rem(index, 2) == 0, do: 1, else: 3
          acc + String.to_integer(digit) * weight
        end)

      Integer.to_string(rem(10 - rem(sum, 10), 10)) == check_digit
    else
      false
    end
  end

  def valid_isbn13?(_isbn), do: false
end
