defmodule Engine.Integrations.Spark.Common do
  alias Engine.Analyzer
  alias Engine.Analyzer.Uses
  alias Engine.ManagerApi
  alias Forge.Ast
  alias Forge.Ast.Analysis.Use
  alias Forge.Ast.Env
  alias Forge.Search.Indexer.Entry

  def use_context(cursor_path, env) do
    Enum.find_value(cursor_path, :error, fn
      {:use, _, [module_ast | arguments]} ->
        with {:ok, module} <- expand_module(module_ast, env),
             do: {:ok, module, List.last(arguments)}

      _ ->
        nil
    end)
  end

  def function_context(cursor_path, env) do
    with {:ok, module_ast, name, arity, argument_index, argument} <-
           Ast.remote_call_at_cursor(cursor_path),
         {:ok, module} <- expand_module(module_ast, env) do
      {:ok, module, name, arity, argument_index, argument}
    end
  end

  def dsl_context(project, %Env{} = env) do
    env.analysis
    |> Uses.at(env.position)
    |> Enum.find_value(:error, &dsl_for_use(project, &1, env))
  end

  def active_extensions(project, dsl, %Use{} = use, env) do
    extensions = fetch_extensions(project)
    configured = configured_extensions(use, dsl, env)

    defaults =
      Enum.reduce(dsl.single_extension_kinds, dsl.default_extensions, fn kind, defaults ->
        if Map.get(configured, kind, []) == [],
          do: defaults,
          else: defaults -- Map.get(dsl.default_extension_kinds, kind, [])
      end)

    (defaults ++ Enum.flat_map(configured, fn {_kind, modules} -> modules end))
    |> Enum.uniq()
    |> expand_extensions(extensions, %{})
    |> apply_patches()
  end

  def find_node(sections, names, current_call_name \\ nil) do
    root = %{options: [], entities: [], sections: sections}
    last_name = List.last(names)

    Enum.reduce_while(names, {:ok, root}, fn name, {:ok, node} ->
      case child(node, name) do
        nil when name == last_name and name == current_call_name -> {:halt, {:ok, node}}
        nil -> {:halt, :error}
        child -> {:cont, {:ok, child}}
      end
    end)
  end

  def child(node, name) do
    Enum.find(Map.get(node, :sections, []), &(&1.name == name)) ||
      Enum.find(Map.get(node, :entities, []), &(&1.name == name)) ||
      Enum.find(top_level_children(node), &(&1.name == name))
  end

  def top_level_children(node) do
    node
    |> Map.get(:sections, [])
    |> Enum.filter(& &1.top_level?)
    |> Enum.flat_map(fn section -> section.options ++ section.entities ++ section.sections end)
  end

  def selected_type_module({:__block__, _, [value]}, aliases, env),
    do: selected_type_module(value, aliases, env)

  def selected_type_module(value, aliases, _env) when is_atom(value),
    do: Map.fetch(aliases, to_string(value))

  def selected_type_module(value, _aliases, env) do
    with {:ok, module} <- expand_module(value, env), do: {:ok, module_name(module)}
  end

  def fetch(project, kind, owner) do
    subject = Entry.integration_subject("spark", kind, owner)

    case ManagerApi.search_store_exact(project, subject,
           type: :metadata,
           subtype: :integration
         ) do
      {:ok, [%Entry{metadata: %{payload: payload}} | _]} -> {:ok, payload}
      _ -> :error
    end
  end

  def option_key(key) when is_atom(key), do: key
  def option_key({:__block__, _, [key]}) when is_atom(key), do: key
  def option_key(_), do: nil

  defp dsl_for_use(project, %Use{} = use, %Env{} = env) do
    env = %Env{env | position: use.range.start}

    with {:ok, module} <- Analyzer.expand_alias(use.module, env.analysis, env.position),
         {:ok, dsl} <- fetch(project, :dsl, module) do
      {:ok, dsl, use}
    else
      _ -> nil
    end
  end

  defp configured_extensions(%Use{opts: opts} = use, dsl, %Env{} = env) do
    env = %Env{env | position: use.range.start}
    extension_keys = ["extensions" | dsl.extension_kinds]

    Enum.reduce(List.flatten(opts), %{}, fn
      {key_ast, value}, acc ->
        case option_key(key_ast) do
          key when not is_nil(key) ->
            key = to_string(key)

            if key in extension_keys do
              modules = modules_from_ast(value, env)
              Map.update(acc, key, modules, &(&1 ++ modules))
            else
              acc
            end

          nil ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp expand_extensions([], _extensions, _seen), do: []

  defp expand_extensions([module | rest], extensions, seen) do
    if Map.has_key?(seen, module) do
      expand_extensions(rest, extensions, seen)
    else
      seen = Map.put(seen, module, true)

      case Map.fetch(extensions, module) do
        {:ok, extension} ->
          [extension | expand_extensions(extension.added_extensions ++ rest, extensions, seen)]

        :error ->
          expand_extensions(rest, extensions, seen)
      end
    end
  end

  defp apply_patches(extensions) do
    patches = Enum.flat_map(extensions, & &1.patches)

    Enum.map(extensions, fn extension ->
      %{extension | sections: patch_sections(extension.sections, patches, [])}
    end)
  end

  defp patch_sections(sections, patches, path) do
    Enum.map(sections, fn section ->
      section_path = path ++ [section.name]
      patched = for %{section_path: ^section_path, entity: entity} <- patches, do: entity

      %{
        section
        | entities: section.entities ++ patched,
          sections: patch_sections(section.sections, patches, section_path)
      }
    end)
  end

  defp modules_from_ast(list, env) when is_list(list),
    do: Enum.flat_map(list, &modules_from_ast(&1, env))

  defp modules_from_ast({:__block__, _, [value]}, env), do: modules_from_ast(value, env)

  defp modules_from_ast(ast, env) do
    case expand_module(ast, env) do
      {:ok, module} -> [module_name(module)]
      :error -> []
    end
  end

  defp expand_module({:__aliases__, _, segments}, env),
    do: Analyzer.expand_alias(segments, env.analysis, env.position)

  defp expand_module({:__block__, _, [value]}, env), do: expand_module(value, env)

  defp expand_module({:__MODULE__, _, _}, env),
    do: Analyzer.current_module(env.analysis, env.position)

  defp expand_module(module, _env) when is_atom(module), do: {:ok, module}
  defp expand_module(_, _env), do: :error

  defp fetch_extensions(project) do
    case ManagerApi.search_store_prefix(
           project,
           Entry.integration_subject_prefix("spark", :extension),
           type: :metadata,
           subtype: :integration
         ) do
      {:ok, entries} ->
        Map.new(entries, fn %Entry{metadata: %{owner_module: module, payload: payload}} ->
          {module, payload}
        end)

      _ ->
        %{}
    end
  end

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
end
