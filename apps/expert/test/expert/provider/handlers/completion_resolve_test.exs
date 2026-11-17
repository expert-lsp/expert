defmodule Expert.Provider.Handlers.CompletionResolveTest do
  use ExUnit.Case, async: false

  alias Expert.Document.Context
  alias Expert.Provider.Handlers.CompletionResolve
  alias Expert.Search
  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Store.Backends.Sqlite
  alias GenLSP.Requests.CompletionItemResolve
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.MarkupContent

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    project = tmp_dir |> Forge.Document.Path.to_uri() |> Forge.Project.new()
    start_supervised!({Expert.Project.Store, []})
    start_supervised!({Sqlite, [project, runtime_versions: %{erlang: "test", elixir: "test"}]})
    start_supervised!({Search.Store, [project, Sqlite]})
    start_supervised!({ModuleRegistry, project})
    {:ok, context: %Context{project: project}}
  end

  test "adds a function's summary and spec", %{context: context} do
    item = %CompletionItem{
      label: "map(enumerable, fun)",
      data: %{"module" => "Enum", "name" => "map", "arity" => 2, "kind" => "function"}
    }

    assert {:ok, %CompletionItem{documentation: %MarkupContent{value: doc}}} =
             CompletionResolve.handle(%CompletionItemResolve{id: 1, params: item}, context)

    assert doc =~ "Returns a list where each element is the result of invoking"
    assert doc =~ "```elixir\nmap("
  end

  test "adds a module's summary", %{context: context} do
    item = %CompletionItem{label: "GenServer", data: %{"module" => "GenServer"}}

    assert {:ok, %CompletionItem{documentation: %MarkupContent{value: "A behaviour module" <> _}}} =
             CompletionResolve.handle(%CompletionItemResolve{id: 1, params: item}, context)
  end

  test "returns items it can't document unchanged", %{context: context} do
    item = %CompletionItem{label: "value", data: nil}

    assert {:ok, ^item} =
             CompletionResolve.handle(%CompletionItemResolve{id: 1, params: item}, context)
  end
end
