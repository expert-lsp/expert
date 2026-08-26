defmodule Engine.CodeIntelligence.Implementations do
  alias ElixirSense.Providers.Location, as: ElixirSenseLocation
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Document.Range

  @spec implementations(Document.t(), Position.t()) ::
          {:ok, [Location.t()]} | {:error, String.t()}
  def implementations(%Document{} = document, %Position{} = position) do
    document
    |> Document.to_string()
    |> ElixirSense.implementations(position.line, position.character)
    |> Enum.reduce_while({:ok, []}, fn location, {:ok, locations} ->
      case from_elixir_sense_location(location, document) do
        {:ok, location} -> {:cont, {:ok, [location | locations]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, locations} -> {:ok, Enum.reverse(locations)}
      error -> error
    end
  end

  defp from_elixir_sense_location(%ElixirSenseLocation{} = location, current_document) do
    %{file: file, line: line, column: column, end_line: end_line, end_column: end_column} =
      location

    case location_document(file, current_document) do
      {:ok, document} ->
        range =
          Range.new(
            Position.new(document, line, column),
            Position.new(document, end_line, end_column)
          )

        {:ok, Location.new(range, document)}

      _ ->
        {:error, "Could not open implementation source file: #{inspect(file)}"}
    end
  end

  defp location_document(nil, %Document{} = document), do: {:ok, document}

  defp location_document(file, _current_document) do
    file
    |> Document.Path.ensure_uri()
    |> Document.Store.open_temporary()
  end
end
