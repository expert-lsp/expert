defmodule Forge.CodeIntelligence.Symbols.Workspace do
  alias Forge.Document
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  defmodule Link do
    defstruct [:uri, :range, :detail_range]

    @type t :: %__MODULE__{
            uri: Forge.uri(),
            range: Forge.Document.Range.t(),
            detail_range: Forge.Document.Range.t()
          }

    def new(uri, range, detail_range \\ nil) do
      %__MODULE__{uri: uri, range: range, detail_range: detail_range}
    end
  end

  defstruct [:name, :type, :link, container_name: nil]

  @type t :: %__MODULE__{
          container_name: String.t() | nil,
          link: Link.t(),
          name: String.t(),
          type: atom()
        }

  def from_entry(%Entry{} = entry) do
    link =
      entry.path
      |> Document.Path.to_uri()
      |> Link.new(entry.block_range, entry.range)

    name = symbol_name(entry.type, entry)

    %__MODULE__{
      name: name,
      type: entry.type,
      link: link
    }
  end

  @module_types [:struct, :module]
  defp symbol_name(type, entry) when type in @module_types do
    Formats.module(entry.subject)
  end

  defp symbol_name({:protocol, _}, entry) do
    Formats.module(entry.subject)
  end

  defp symbol_name(_type, %{metadata: %{display_name: name}}) when is_binary(name), do: name

  defp symbol_name(_, entry),
    do: entry.subject
end
