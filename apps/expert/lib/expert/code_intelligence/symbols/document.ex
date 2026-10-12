defmodule Expert.CodeIntelligence.Symbols.Document do
  alias Forge.Document
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  defstruct [:name, :type, :range, :detail_range, :detail, :original_type, :subject, children: []]

  def from(%Document{} = document, %Entry{} = entry, children \\ []) do
    case name_and_type(entry.type, entry, document) do
      {name, type} ->
        range = entry.block_range || entry.range

        {:ok,
         %__MODULE__{
           name: name,
           type: type,
           range: range,
           detail_range: entry.range,
           children: children,
           original_type: entry.type,
           subject: entry.subject
         }}

      _ ->
        :error
    end
  end

  @do_regex ~r/\s*do\s*$/

  defp name_and_type({:function, type}, %Entry{} = entry, %Document{} = document)
       when type in [:public, :private, :delegate] do
    fragment =
      document
      |> Document.fragment(entry.range.start, entry.range.end)
      |> remove_line_breaks_and_multiple_spaces()

    prefix =
      case type do
        :public -> "def "
        :private -> "defp "
        :delegate -> "defdelegate "
      end

    {prefix <> fragment, entry.type}
  end

  @ignored_attributes ~w[spec doc moduledoc derive impl tag]
  @type_name_regex ~r/@type\s+[^\s]+/

  defp name_and_type(:module_attribute, %Entry{} = entry, document) do
    case String.split(entry.subject, "@") do
      [_, name] when name in @ignored_attributes ->
        nil

      [_, "type"] ->
        type_text = Document.fragment(document, entry.range.start, entry.range.end)

        name =
          case Regex.scan(@type_name_regex, type_text) do
            [[match]] -> match
            _ -> "@type ??"
          end

        {name, :type}

      [_, name] ->
        {"@#{name}", :module_attribute}
    end
  end

  defp name_and_type(ex_unit, %Entry{} = entry, document)
       when ex_unit in [:ex_unit_describe, :ex_unit_setup, :ex_unit_test] do
    name =
      document
      |> Document.fragment(entry.range.start, entry.range.end)
      |> String.trim()
      |> String.replace(@do_regex, "")

    {name, ex_unit}
  end

  defp name_and_type(:struct, %Entry{} = entry, _document) do
    module_name = Formats.module(entry.subject)
    {"%#{module_name}{}", :struct}
  end

  defp name_and_type(type, %Entry{subject: name}, _document) when is_atom(name) do
    {Formats.module(name), type}
  end

  defp name_and_type(type, %Entry{} = entry, _document) do
    {to_string(entry.subject), type}
  end

  defp remove_line_breaks_and_multiple_spaces(string) do
    string |> String.split(~r/\s/) |> Enum.reject(&match?("", &1)) |> Enum.join(" ")
  end
end
