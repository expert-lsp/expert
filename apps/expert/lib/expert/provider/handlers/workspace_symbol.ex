defmodule Expert.Provider.Handlers.WorkspaceSymbol do
  @behaviour Expert.Provider.Handler

  alias Expert.CodeIntelligence.Symbols
  alias Expert.Configuration
  alias Expert.Configuration.WorkspaceSymbols
  alias Expert.Project.Store
  alias Forge.CodeIntelligence.Symbols.Workspace
  alias Forge.Project
  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Logger

  @impl Expert.Provider.Handler
  def handle(
        %Requests.WorkspaceSymbol{params: %Structures.WorkspaceSymbolParams{} = params} = request,
        _context
      ) do
    config = Configuration.get()
    projects = Store.projects()

    symbols =
      if should_return_symbols?(params.query, config) do
        Enum.flat_map(projects, &gather_symbols(&1, request))
      else
        []
      end

    {:ok, symbols}
  end

  defp should_return_symbols?(query, %Configuration{
         workspace_symbols: %WorkspaceSymbols{min_query_length: min_length}
       }) do
    String.length(query) >= min_length
  end

  defp gather_symbols(
         %Project{} = project,
         %Requests.WorkspaceSymbol{
           params: %Structures.WorkspaceSymbolParams{} = params
         }
       ) do
    case Symbols.for_workspace(project, params.query) do
      {:ok, symbols} ->
        Enum.map(symbols, &to_lsp_symbol/1)

      {:error, :loading} ->
        []

      {:error, reason} ->
        Logger.warning("Could not query workspace symbols: #{inspect(reason)}")
        []

      [] ->
        []
    end
  catch
    :exit, reason ->
      Logger.warning("Could not query workspace symbols: #{inspect(reason)}")
      []
  end

  def to_lsp_symbol(%Workspace{} = root) do
    %Structures.WorkspaceSymbol{
      kind: to_kind(root.type),
      location: to_location(root.link),
      name: root.name,
      container_name: root.container_name
    }
  end

  defp to_location(%Workspace.Link{} = link) do
    %Structures.Location{uri: link.uri, range: link.detail_range}
  end

  defp to_kind(:struct), do: SymbolKind.struct()
  defp to_kind(:module), do: SymbolKind.module()
  defp to_kind({:protocol, _}), do: SymbolKind.module()
  defp to_kind({:xp_protocol, _}), do: SymbolKind.module()
  defp to_kind(:variable), do: SymbolKind.variable()
  defp to_kind({:function, _}), do: SymbolKind.function()
  defp to_kind({:macro, _}), do: SymbolKind.function()
  defp to_kind(:module_attribute), do: SymbolKind.constant()
  defp to_kind(:ex_unit_test), do: SymbolKind.method()
  defp to_kind(:ex_unit_describe), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup), do: SymbolKind.method()
  defp to_kind(:ex_unit_setup_all), do: SymbolKind.method()
  defp to_kind(:type), do: SymbolKind.type_parameter()
  defp to_kind(:spec), do: SymbolKind.interface()
  defp to_kind(:file), do: SymbolKind.file()
end
