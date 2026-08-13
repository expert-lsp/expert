defmodule Engine.Integrations.Spark.Hover do
  @behaviour Engine.Integrations

  alias Engine.CodeIntelligence.Entity
  alias Engine.Integrations.Spark.Common
  alias Forge.Ast
  alias Forge.Ast.Env
  alias Forge.Document.Position

  @impl Engine.Integrations
  def hover(%Env{} = env) do
    with false <- Env.in_context?(env, :comment) or Env.in_context?(env, :string),
         {:ok, %{begin: begin_pos, context: context, end: end_pos}} <-
           Ast.surround_context(env.analysis, env.position),
         name when is_binary(name) <- hover_name(context),
         env = move_to_token_end(env, end_pos),
         cursor_path = Ast.cursor_path(env.analysis, env.position),
         {:ok, documentation} <- documentation(cursor_path, name, env) do
      [{documentation, Entity.to_range(env.document, begin_pos, end_pos)}]
    else
      _ -> []
    end
  end

  defp documentation(cursor_path, name, env) do
    case Common.use_context(cursor_path, env) do
      {:ok, module, _argument} ->
        with {:ok, dsl} <- Common.fetch(env.project, :dsl, module),
             do: find_documentation(dsl.options, name)

      :error ->
        case Common.function_context(cursor_path, env) do
          {:ok, module, function, arity, argument_index, _argument} ->
            key = "#{Forge.Formats.mfa(module, function, arity)}/#{argument_index}"

            with {:ok, options} <- Common.fetch(env.project, :function, key),
                 do: find_documentation(options, name)

          :error ->
            dsl_documentation(cursor_path, name, env)
        end
    end
  end

  defp dsl_documentation(cursor_path, name, env) do
    if Ast.inside_definition?(cursor_path) and not Ast.remote_call?(cursor_path) do
      :error
    else
      with {:ok, dsl, use} <- Common.dsl_context(env.project, env) do
        extensions = Common.active_extensions(env.project, dsl, use, env)
        sections = Enum.flat_map(extensions, & &1.sections)
        names = Ast.enclosing_local_call_names(cursor_path)
        call_context = Ast.local_call_at_cursor(cursor_path)
        node_documentation(sections, names, call_context, name, env)
      end
    end
  end

  defp node_documentation(sections, names, call_context, name, env) do
    parent_names = if List.last(names) == name, do: Enum.drop(names, -1), else: names

    with :error <- documentation_in_node(sections, parent_names, name),
         :error <- documentation_in_node(sections, names, name),
         do: constraint_documentation(sections, names, call_context, name, env)
  end

  defp documentation_in_node(sections, names, name) do
    with {:ok, node} <- Common.find_node(sections, names),
         child when not is_nil(child) <- Common.child(node, name),
         documentation when is_binary(documentation) and documentation != "" <-
           Map.get(child, :documentation) do
      {:ok, documentation}
    else
      _ ->
        with {:ok, node} <- Common.find_node(sections, names),
             do: find_documentation(Map.get(node, :options, []), name)
    end
  end

  defp constraint_documentation(
         sections,
         names,
         {:ok, call_name, _index, _argument, arguments},
         name,
         env
       ) do
    case Common.find_node(sections, names) do
      {:ok, %{name: ^call_name} = node} ->
        with %{type: %{kind: :spark_type, behaviour: behaviour, aliases: aliases}} <-
               Enum.find(node.options, &(&1.name == "type")),
             index when is_integer(index) <-
               Enum.find_index(node.arguments, &(&1.name == "type")),
             type_ast when not is_nil(type_ast) <- Enum.at(arguments, index),
             argument_ast when not is_nil(argument_ast) <-
               Enum.find(arguments, &Ast.contains_cursor?/1),
             {:ok, keyword_path} <- Ast.keyword_path_at_cursor(argument_ast),
             {:ok, module} <- Common.selected_type_module(type_ast, aliases, env),
             {:ok, %{constraints: options}} <-
               Common.fetch(env.project, :behaviour, "#{behaviour}/#{module}") do
          find_documentation(options, Enum.drop(keyword_path, 1), name)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp constraint_documentation(_sections, _names, _call_context, _name, _env), do: :error

  defp find_documentation(options, name) do
    find_documentation(options, [], name)
  end

  defp find_documentation(options, [], name) do
    case Enum.find(options, &(&1.name == name)) do
      %{documentation: documentation} when is_binary(documentation) and documentation != "" ->
        {:ok, documentation}

      _ ->
        :error
    end
  end

  defp find_documentation(options, [key | path], name) do
    case Enum.find(options, &(&1.name == key)) do
      %{type: %{options: nested}} -> find_documentation(nested, path, name)
      _ -> :error
    end
  end

  defp move_to_token_end(%Env{} = env, {line, column}) do
    %Env{
      env
      | position: Position.new(env.document, line, column),
        prefix: String.slice(env.line, 0, column - 1),
        suffix: String.slice(env.line, (column - 1)..-1//1),
        zero_based_character: column - 1
    }
  end

  defp hover_name({context, chars})
       when context in [:keyword, :local_call, :local_or_var, :unquoted_atom],
       do: to_string(chars)

  defp hover_name(_context), do: nil
end
