defmodule Expert.CodeIntelligence.Completion.Translations.ModuleOrBehaviour do
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.SortScope
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Translations
  alias Expert.Project.Intelligence
  alias Forge.Ast.Env
  alias GenLSP.Enumerations.CompletionItemKind

  defimpl Translatable, for: Candidate.Module do
    def translate(module, builder, %Env{} = env) do
      Translations.ModuleOrBehaviour.translate(module, builder, env)
    end
  end

  defimpl Translatable, for: Candidate.Struct do
    def translate(module, builder, %Env{} = env) do
      Translations.ModuleOrBehaviour.translate(module, builder, env)
    end
  end

  defimpl Translatable, for: Candidate.Behaviour do
    def translate(behaviour, builder, %Env{} = env) do
      Translations.ModuleOrBehaviour.translate(behaviour, builder, env)
    end
  end

  defimpl Translatable, for: Candidate.Protocol do
    def translate(protocol, builder, %Env{} = env) do
      Translations.ModuleOrBehaviour.translate(protocol, builder, env)
    end
  end

  def translate(%_{} = module, builder, %Env{} = env) do
    if Env.in_context?(env, :struct_reference) do
      complete_in_struct_reference(env, builder, module)
    else
      detail = builder.fallback(module.summary, module.full_name)

      env
      |> completion(builder, module.name, detail)
      |> Map.put(:data, %{"uri" => env.document.uri, "module" => module.full_name})
    end
  end

  defp complete_in_struct_reference(%Env{} = env, builder, %Candidate.Struct{} = struct) do
    immediate_descendent_structs =
      immediate_descendent_struct_modules(env.project, struct.full_name)

    if Enum.empty?(immediate_descendent_structs) do
      Translations.Struct.completion(env, builder, struct.name, struct.full_name)
    else
      do_complete_in_struct_reference(env, builder, struct, immediate_descendent_structs)
    end
  end

  defp complete_in_struct_reference(%Env{} = env, builder, %Candidate.Module{} = module) do
    immediate_descendent_structs =
      immediate_descendent_struct_modules(env.project, module.full_name)

    do_complete_in_struct_reference(env, builder, module, immediate_descendent_structs)
  end

  defp do_complete_in_struct_reference(
         %Env{} = env,
         builder,
         module_or_struct,
         immediate_descendent_structs
       ) do
    structs_mapset = MapSet.new(immediate_descendent_structs)
    dot_counts = module_dot_counts(module_or_struct.full_name)
    ancestors = ancestors(immediate_descendent_structs, dot_counts)

    Enum.flat_map(ancestors, fn ancestor ->
      local_name = local_module_name(module_or_struct.full_name, ancestor, module_or_struct.name)

      more =
        env.project
        |> Intelligence.collect_struct_modules(ancestor, to: :infinity)
        |> Enum.count()

      if struct?(ancestor, structs_mapset) do
        [
          Translations.Struct.completion(env, builder, local_name, ancestor),
          Translations.Struct.completion(env, builder, local_name, ancestor, more - 1)
        ]
      else
        [Translations.Struct.completion(env, builder, local_name, ancestor, more)]
      end
    end)
  end

  defp struct?(module, structs_mapset) do
    MapSet.member?(structs_mapset, module)
  end

  defp ancestors(results, dot_counts) do
    results
    |> Enum.map(fn module ->
      module |> String.split(".") |> Enum.take(dot_counts + 1) |> Enum.join(".")
    end)
    |> Enum.uniq()
  end

  # this skips grapheme translations
  defp module_dot_counts(module_name), do: module_dot_counts(module_name, 0)

  defp module_dot_counts(<<>>, count), do: count
  defp module_dot_counts(<<".", rest::binary>>, count), do: module_dot_counts(rest, count + 1)
  defp module_dot_counts(<<_::utf8, rest::binary>>, count), do: module_dot_counts(rest, count)

  def completion(%Env{} = env, builder, module_name, detail \\ nil) do
    detail = builder.fallback(detail, "#{module_name} (Module)")

    env
    |> builder.plain_text(module_name,
      label: module_name,
      kind: CompletionItemKind.module(),
      detail: detail
    )
    |> builder.set_sort_scope(SortScope.module())
  end

  defp local_module_name(parent_module, child_module, aliased_module) do
    # Returns the "local" module name, so if you're completing
    # Types.Som and the module completion is "Types.Something.Else",
    # "Something.Else" is returned.

    parent_pieces = String.split(parent_module, ".")
    parent_pieces = Enum.take(parent_pieces, length(parent_pieces) - 1)
    local_module_name = Enum.join(parent_pieces, ".")
    local_module_length = String.length(local_module_name)

    local_name =
      child_module
      |> String.slice(local_module_length..-1//1)
      |> strip_leading_period()

    if String.starts_with?(local_name, aliased_module) do
      local_name
    else
      [_ | tail] = String.split(local_name, ".")
      Enum.join([aliased_module | tail], ".")
    end
  end

  defp strip_leading_period(<<".", rest::binary>>), do: rest
  defp strip_leading_period(string_without_period), do: string_without_period

  defp immediate_descendent_struct_modules(%Forge.Project{} = project, module_name) do
    Intelligence.collect_struct_modules(project, module_name, to: :grandchild)
  end
end
