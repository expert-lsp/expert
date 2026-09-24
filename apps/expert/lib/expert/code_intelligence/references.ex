defmodule Expert.CodeIntelligence.References do
  @moduledoc "Finds references with manager-owned index data and Engine entity resolution."

  alias Expert.CodeIntelligence.Variable
  alias Expert.EngineApi
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Store
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Subject

  def references(
        %Project{} = project,
        %Analysis{} = analysis,
        %Position{} = position,
        include_definitions?
      ) do
    case variable_at(analysis, position) do
      {:ok, name} ->
        analysis
        |> Variable.references(position, name, include_definitions?)
        |> Enum.map(&Location.new(&1.range, analysis.document.uri))

      :error ->
        project
        |> EngineApi.resolve_entity(analysis, position)
        |> find_references(project, analysis, position, include_definitions?)
    end
  end

  defp find_references(
         {:ok, resolved, _range},
         %Project{} = project,
         %Analysis{} = analysis,
         %Position{} = position,
         include_definitions?
       ) do
    resolved
    |> maybe_rewrite_resolution(analysis, position)
    |> do_find_references(project, include_definitions?)
  end

  defp find_references(_result, _project, _analysis, _position, _include_definitions?), do: []

  defp do_find_references({:module, module}, %Project{} = project, include_definitions?) do
    module
    |> Subject.module()
    |> query(project, type: :module, subtype: subtype(include_definitions?))
  end

  defp do_find_references({:struct, module}, %Project{} = project, include_definitions?) do
    module
    |> Subject.module()
    |> query(project, type: :struct, subtype: subtype(include_definitions?))
  end

  defp do_find_references(
         {:call, module, function_name, _arity},
         %Project{} = project,
         include_definitions?
       ) do
    subject = Subject.mfa(module, function_name, "")
    subtype = subtype(include_definitions?)

    case Store.prefix(project, subject, type: :_, subtype: subtype) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&function_entry?/1)
        |> Enum.map(&to_location/1)

      _ ->
        []
    end
  end

  defp do_find_references(
         {:module_attribute, module, attribute_name},
         %Project{} = project,
         include_definitions?
       ) do
    module
    |> Subject.module_attribute(attribute_name)
    |> query(project, type: :module_attribute, subtype: subtype(include_definitions?))
  end

  defp do_find_references(_resolved, _project, _include_definitions?), do: []

  defp function_entry?(%Entry{type: {:function, _}}), do: true
  defp function_entry?(_), do: false

  defp maybe_rewrite_resolution({:call, Kernel, :defstruct, 1}, analysis, position) do
    case Analyzer.current_module(analysis, position) do
      {:ok, struct_module} -> {:struct, struct_module}
      _ -> {:call, Kernel, :defstruct, 1}
    end
  end

  defp maybe_rewrite_resolution(resolution, _analysis, _position), do: resolution

  defp to_location(%Entry{} = entry) do
    entry.path
    |> Document.Path.ensure_uri()
    |> then(&Location.new(entry.range, &1))
  end

  defp query(subject, %Project{} = project, opts) do
    case Store.exact(project, subject, opts) do
      {:ok, entries} -> Enum.map(entries, &to_location/1)
      _ -> []
    end
  end

  defp subtype(true = _include_definitions?), do: :_
  defp subtype(false = _include_definitions?), do: :reference

  defp variable_at(%Analysis{} = analysis, %Position{} = position) do
    case Ast.surround_context(analysis, position) do
      {:ok, %{context: {:local_or_var, name}}} ->
        name = List.to_atom(name)

        case Variable.definition(analysis, position, name) do
          {:ok, _definition} -> {:ok, name}
          :error -> :error
        end

      _ ->
        :error
    end
  end
end
