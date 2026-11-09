defmodule Forge.Document do
  @moduledoc """
  A representation of a LSP text document

  A document is the fundamental data structure of the Expert language server.
  All language server documents are represented and backed by documents, which
  provide functionality for fetching lines, applying changes, and tracking versions.
  """
  import Forge.Document.Line

  alias __MODULE__.Path, as: DocumentPath
  alias Forge.Document.Edit
  alias Forge.Document.Line
  alias Forge.Document.Lines
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Math
  alias Forge.Protocol.Convertible

  require Logger

  @derive {Inspect, only: [:path, :version, :dirty?, :lines]}

  defstruct [:uri, :language_id, :path, :version, dirty?: false, lines: nil]

  @type version :: non_neg_integer()
  @type fragment_position :: Position.t() | Convertible.t()
  @type t :: %__MODULE__{
          uri: String.t(),
          language_id: String.t(),
          version: version(),
          dirty?: boolean,
          lines: Lines.t(),
          path: String.t()
        }

  @type change_application_error ::
          {:error, {:invalid_range, map()}} | {:error, :invalid_version}

  # public

  @doc """
  Creates a new document from a uri or path, the source code
  as a binary and the vewrsion.
  """
  @spec new(Forge.path() | Forge.uri(), String.t(), version()) :: t()
  def new(maybe_uri, text, version, language_id \\ nil) do
    uri = DocumentPath.ensure_uri(maybe_uri)
    path = DocumentPath.from_uri(uri)

    language_id =
      if String.ends_with?(path, ".exs") do
        "elixir-script"
      else
        language_id || language_id_from_path(path)
      end

    %__MODULE__{
      uri: uri,
      version: version,
      lines: Lines.new(text),
      path: path,
      language_id: language_id
    }
  end

  @doc """
  Returns the number of lines in the document

  This is a constant time operation.
  """
  @spec size(t) :: non_neg_integer()
  def size(%__MODULE__{} = document) do
    Lines.size(document.lines)
  end

  @doc """
  Marks the document file as dirty

  This function is mainly used internally by expert
  """
  @spec mark_dirty(t) :: t
  def mark_dirty(%__MODULE__{} = document) do
    %__MODULE__{document | dirty?: true}
  end

  @doc """
  Marks the document file as clean

  This function is mainly used internally by expert
  """
  @spec mark_clean(t) :: t
  def mark_clean(%__MODULE__{} = document) do
    %__MODULE__{document | dirty?: false}
  end

  @doc """
  Get the text at the given line using `fetch` semantics

  Returns `{:ok, text}` if the line exists, and `:error` if it doesn't. The line text is
  returned without the line end character(s).

  This is a constant time operation.
  """
  @spec fetch_text_at(t, version()) :: {:ok, String.t()} | :error
  def fetch_text_at(%__MODULE__{} = document, line_number) do
    case fetch_line_at(document, line_number) do
      {:ok, line(text: text)} -> {:ok, text}
      _ -> :error
    end
  end

  @doc """
  Get the `Forge.Document.Line` at the given index using `fetch` semantics.

  This function is of limited utility, you probably want `fetch_text_at/2` instead.
  """
  @spec fetch_line_at(t, version()) :: {:ok, Line.t()} | :error
  def fetch_line_at(%__MODULE__{} = document, line_number) do
    case Lines.fetch_line(document.lines, line_number) do
      {:ok, line} -> {:ok, line}
      _ -> :error
    end
  end

  @doc """
  Returns a fragment defined by the from and to arguments

  Builds a string that represents the text of the document from the two positions given.
  The from position, defaults to `:beginning` meaning the start of the document.
  Positions can be a `Document.Position.t` or anything that will convert to a position using
  `Forge.Protocol.Convertible.to_native/2`.
  """
  @spec fragment(t, fragment_position() | :beginning, fragment_position()) :: String.t()
  @spec fragment(t, fragment_position()) :: String.t()
  def fragment(%__MODULE__{} = document, from \\ :beginning, to) do
    line_count = size(document)
    from_pos = convert_fragment_position(document, from)
    to_pos = convert_fragment_position(document, to)

    from_line = Math.clamp(from_pos.line, document.lines.starting_index, line_count)
    to_line = Math.clamp(to_pos.line, from_line, line_count + 1)

    # source code positions are 1 based, but string slices are zero-based. Need an ad-hoc conversion
    # here.
    from_character = from_pos.character - 1
    to_character = to_pos.character - 1

    line_range = from_line..to_line

    line_range
    |> Enum.reduce([], fn line_number, acc ->
      to_append =
        case fetch_line_at(document, line_number) do
          {:ok, line(text: text, ending: ending)} ->
            line_text = text <> ending

            cond do
              line_number == from_line and line_number == to_line ->
                slice_length = to_character - from_character
                String.slice(line_text, from_character, slice_length)

              line_number == from_line ->
                slice_length = String.length(line_text) - from_character
                String.slice(line_text, from_character, slice_length)

              line_number == to_line ->
                String.slice(line_text, 0, to_character)

              true ->
                line_text
            end

          :error ->
            []
        end

      [acc, to_append]
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  @spec apply_content_changes(t, version(), [Convertible.t() | nil]) ::
          {:ok, t} | change_application_error()
  def apply_content_changes(%__MODULE__{version: current_version}, new_version, _)
      when new_version <= current_version do
    {:error, :invalid_version}
  end

  def apply_content_changes(%__MODULE__{} = document, _, []) do
    {:ok, document}
  end

  def apply_content_changes(%__MODULE__{} = document, version, changes) when is_list(changes) do
    result =
      Enum.reduce_while(changes, document, fn
        nil, document ->
          {:cont, document}

        change, document ->
          case apply_change(document, change) do
            {:ok, new_document} ->
              {:cont, new_document}

            error ->
              {:halt, error}
          end
      end)

    case result do
      %__MODULE__{} = document ->
        document = mark_dirty(%__MODULE__{document | version: version})

        {:ok, document}

      error ->
        error
    end
  end

  @doc """
  Converts a document to a string

  This function converts the given document back into a string, with line endings
  preserved.
  """
  def to_string(%__MODULE__{} = document) do
    document
    |> to_iodata()
    |> IO.iodata_to_binary()
  end

  @spec language_id_from_path(Forge.path()) :: String.t()
  defp language_id_from_path(path) do
    case Path.extname(path) do
      ".ex" ->
        "elixir"

      ".exs" ->
        "elixir-script"

      ".eex" ->
        "eex"

      ".heex" ->
        "phoenix-heex"

      extension ->
        Logger.warning("can't infer lang ID for #{path}, ext: #{extension}.")

        "unsupported (#{extension})"
    end
  end

  # private

  defp line_count(%__MODULE__{} = document) do
    Lines.size(document.lines)
  end

  defp apply_change(
         %__MODULE__{} = document,
         %Range{start: %Position{} = start_pos, end: %Position{} = end_pos},
         new_text
       ) do
    start_line = start_pos.line

    new_lines_iodata =
      cond do
        start_line > line_count(document) ->
          append_to_end(document, new_text)

        start_line < 1 ->
          prepend_to_beginning(document, new_text)

        true ->
          apply_valid_edits(document, new_text, start_pos, end_pos)
      end

    new_document =
      new_lines_iodata
      |> IO.iodata_to_binary()
      |> Lines.new()

    {:ok, %__MODULE__{document | lines: new_document}}
  end

  defp apply_change(%__MODULE__{} = document, %Edit{range: nil} = edit) do
    {:ok, %__MODULE__{document | lines: Lines.new(edit.text)}}
  end

  defp apply_change(%__MODULE__{} = document, %Edit{range: %Range{}} = edit) do
    if valid_edit?(edit) do
      apply_change(document, edit.range, edit.text)
    else
      {:error, {:invalid_range, edit.range}}
    end
  end

  defp apply_change(%__MODULE__{} = document, %{range: range, text: text}) do
    with {:ok, native_range} <- Convertible.to_native(range, document) do
      apply_change(document, Edit.new(text, native_range))
    end
  end

  defp apply_change(%__MODULE__{} = document, %{text: text}) do
    apply_change(document, Edit.new(text, nil))
  end

  defp apply_change(%__MODULE__{} = document, convertible_edit) do
    with {:ok, edit} <- Convertible.to_native(convertible_edit, document) do
      apply_change(document, edit)
    end
  end

  defp valid_edit?(%Edit{
         range: %Range{start: %Position{} = start_pos, end: %Position{} = end_pos}
       }) do
    start_pos.line >= 0 and start_pos.character >= 0 and end_pos.line >= 0 and
      end_pos.character >= 0
  end

  defp append_to_end(%__MODULE__{} = document, edit_text) do
    [to_iodata(document), edit_text]
  end

  defp prepend_to_beginning(%__MODULE__{} = document, edit_text) do
    [edit_text, to_iodata(document)]
  end

  defp apply_valid_edits(%__MODULE__{} = document, edit_text, start_pos, end_pos) do
    Lines.reduce(document.lines, [], fn line() = line, acc ->
      case edit_action(line, edit_text, start_pos, end_pos) do
        :drop ->
          acc

        {:append, io_data} ->
          [acc, io_data]
      end
    end)
  end

  defp edit_action(line() = line, edit_text, %Position{} = start_pos, %Position{} = end_pos) do
    %Position{line: start_line, character: start_char} = start_pos
    %Position{line: end_line, character: end_char} = end_pos

    line(line_number: line_number, text: text, ending: ending) = line

    cond do
      line_number < start_line ->
        {:append, [text, ending]}

      line_number > end_line ->
        {:append, [text, ending]}

      line_number == start_line && line_number == end_line ->
        prefix_text = utf8_prefix(line, start_char)
        suffix_text = utf8_suffix(line, end_char)
        {:append, [prefix_text, edit_text, suffix_text, ending]}

      line_number == start_line ->
        prefix_text = utf8_prefix(line, start_char)
        {:append, [prefix_text, edit_text]}

      line_number == end_line ->
        suffix_text = utf8_suffix(line, end_char)
        {:append, [suffix_text, ending]}

      true ->
        :drop
    end
  end

  defp utf8_prefix(line(text: text), start_code_unit) do
    byte_count = byte_size(text)
    desired_length = start_code_unit - 1
    length = min(max(0, desired_length), byte_count)

    binary_part(text, 0, length)
  end

  defp utf8_suffix(line(text: text), start_code_unit) do
    byte_count = byte_size(text)
    start_index = min(start_code_unit - 1, byte_count)
    length = byte_count - start_index

    binary_part(text, start_index, length)
  end

  defp to_iodata(%__MODULE__{} = document) do
    Lines.to_iodata(document.lines)
  end

  @spec convert_fragment_position(t, Position.t() | :beginning | Convertible.t()) :: Position.t()
  defp convert_fragment_position(%__MODULE__{}, %Position{} = pos) do
    pos
  end

  defp convert_fragment_position(%__MODULE__{} = document, :beginning) do
    Position.new(document, 1, 1)
  end

  defp convert_fragment_position(%__MODULE__{} = document, convertible) do
    {:ok, %Position{} = converted} = Convertible.to_native(convertible, document)
    converted
  end
end
