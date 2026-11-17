defmodule Expert.CodeIntelligence.Completion do
  alias Expert.CodeIntelligence.Completion.Builder
  alias Expert.CodeIntelligence.Completion.Callables
  alias Expert.CodeIntelligence.Completion.Candidate
  alias Expert.CodeIntelligence.Completion.Candidates
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Modules
  alias Expert.CodeIntelligence.Completion.StructFields
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Variables
  alias Expert.CodeIntelligence.Hex
  alias Expert.Configuration
  alias Expert.Integrations
  alias Expert.Project.Intelligence
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Document.Changes
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Project
  alias GenLSP.Enumerations.CompletionTriggerKind
  alias GenLSP.Structures.CompletionContext
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.CompletionList

  require Logger

  def trigger_characters do
    [".", "@", "&", "%", "^", ":", "!", "-", "~"]
  end

  @spec complete(Project.t(), Analysis.t(), Position.t(), CompletionContext.t()) ::
          CompletionList.t()
  def complete(
        %Project{} = project,
        %Analysis{} = analysis,
        %Position{} = position,
        %CompletionContext{} = context
      ) do
    case Env.new(project, analysis, position) do
      {:ok, env} ->
        hex_context =
          if Hex.project_file?(project, analysis.document) do
            case Hex.Context.detect(env.analysis, position) do
              {:ok, ctx} -> ctx
              :error -> nil
            end
          end

        hex_items = hex_items_for_context(hex_context, project, env)
        {regular_items, contextual_incomplete?} = completions(project, env, analysis, context)
        all = hex_items ++ regular_items
        log_candidates(all)

        if not is_nil(hex_context) or contextual_incomplete? do
          %CompletionList{items: all, is_incomplete: true}
        else
          maybe_to_completion_list(all)
        end

      {:error, _} = error ->
        Logger.error("Failed to build completion env #{inspect(error)}")
        maybe_to_completion_list()
    end
  end

  defp hex_items_for_context(nil, _project, _env), do: []

  defp hex_items_for_context(ctx, %Project{} = project, %Env{} = env) when is_map(ctx) do
    ctx
    |> Hex.candidates_for_context(project)
    |> Enum.map(&Translatable.translate(&1, Builder, env))
  end

  defp log_candidates(candidates) do
    log_iolist =
      Enum.reduce(candidates, ["Emitting Completions: ["], fn %CompletionItem{} = completion,
                                                              acc ->
        name = Map.get(completion, :label)
        kind = completion |> Map.get(:kind, :unknown) |> to_string()

        [acc, [kind, ":", name], " "]
      end)

    Logger.info([log_iolist, "]"])
  end

  defp completions(
         %Project{} = project,
         %Env{} = env,
         %Analysis{} = document_analysis,
         %CompletionContext{} = context
       ) do
    case Integrations.complete(env) do
      {:override, candidates, incomplete?, _transforms} ->
        {translate_contextual_candidates(candidates, env), incomplete?}

      {:augment, candidates, incomplete?, transforms} ->
        contextual_items = translate_contextual_candidates(candidates, env)

        ordinary_items =
          project
          |> ordinary_completions(env, document_analysis, context)
          |> transform(transforms)

        augment(contextual_items, ordinary_items, incomplete?)

      :ignore ->
        {ordinary_completions(project, env, document_analysis, context), false}
    end
  end

  defp translate_contextual_candidates(candidates, env) do
    Enum.flat_map(candidates, fn {candidate, transforms} ->
      case Translatable.translate(candidate, Builder, env) do
        :skip -> []
        items -> items |> List.wrap() |> transform(transforms)
      end
    end)
  end

  defp transform(items, transforms) do
    Enum.reduce(transforms, items, fn
      :wrap_list, items -> Enum.map(items, &wrap_list_item/1)
    end)
  end

  defp wrap_list_item(
         %CompletionItem{text_edit: %Changes{edits: %Edit{text: text} = edit} = changes} = item
       ) do
    %CompletionItem{item | text_edit: %Changes{changes | edits: %Edit{edit | text: "[#{text}]"}}}
  end

  defp wrap_list_item(item), do: item

  defp augment(items, ordinary_items, incomplete?) do
    items = Enum.map(items, &Builder.set_sort_scope(&1, "000"))
    {Enum.uniq_by(items ++ ordinary_items, &{&1.label, &1.kind}), incomplete?}
  end

  defp ordinary_completions(project, env, document_analysis, context) do
    prefix_tokens = Env.prefix_tokens(env, 1)

    cond do
      prefix_tokens == [] or not should_emit_completions?(env) ->
        []

      should_emit_do_end_snippet?(env) ->
        do_end_snippet = "do\n  $0\nend"

        env
        |> Builder.snippet(
          do_end_snippet,
          label: "do/end block",
          filter_text: "do"
        )
        |> List.wrap()

      Env.in_context?(env, :struct_field_key) ->
        env
        |> Context.new(document_analysis)
        |> StructFields.in_literal()
        |> Enum.map(&Translatable.translate(&1, Builder, env))

      true ->
        env
        |> Candidates.for_env(document_analysis)
        |> Enum.concat(variables(document_analysis, env))
        |> to_completion_items(project, env, context)
    end
  end

  # A recovered environment contains only the prefix. Use the document AST to
  # find bindings after that partial parse.
  defp variables(%Analysis{} = document_analysis, %Env{} = env) do
    analysis = if document_analysis.ast, do: document_analysis, else: env.analysis

    if variable_position?(env) do
      analysis
      |> Variables.in_scope(env.position)
      |> Enum.map(&%Candidate.Variable{name: Atom.to_string(&1)})
    else
      []
    end
  end

  defp variable_position?(%Env{} = env) do
    case Code.Fragment.cursor_context(env.prefix) do
      {:local_or_var, _name} -> not bitstring_modifier?(env)
      {:operator, operator} -> operator in [~c"^", ~c"&"]
      _ -> false
    end
  end

  defp bitstring_modifier?(%Env{} = env) do
    Env.in_context?(env, :bitstring) and
      match?(
        [_name, {:operator, operator, _} | _] when operator in [:"::", :-],
        Env.prefix_tokens(env, 2)
      )
  end

  defp should_emit_completions?(%Env{} = env) do
    if inside_comment?(env) or inside_string?(env) do
      false
    else
      always_emit_completions?() or has_meaningful_completions?(env)
    end
  end

  defp always_emit_completions? do
    # If VS Code receives an empty completion list, it will never issue
    # a new request, even if `is_incomplete: true` is specified.
    # https://github.com/lexical-lsp/lexical/issues/400
    Configuration.vscode_family?()
  end

  defp has_meaningful_completions?(%Env{} = env) do
    case Code.Fragment.cursor_context(env.prefix) do
      :none ->
        false

      {:unquoted_atom, name} ->
        length(name) > 1

      {:local_or_var, name} ->
        local_length = length(name)
        surround_begin = max(1, env.position.character - local_length)

        local_length > 1 or has_surround_context?(env.prefix, 1, surround_begin)

      _ ->
        true
    end
  end

  defp inside_comment?(env) do
    Env.in_context?(env, :comment)
  end

  defp inside_string?(env) do
    Env.in_context?(env, :string)
  end

  defp has_surround_context?(fragment, line, column)
       when is_binary(fragment) and line >= 1 and column >= 1 do
    Code.Fragment.surround_context(fragment, {line, column}) != :none
  end

  # We emit a do/end snippet if the prefix token is the do operator or 'd', and
  # there is a space before the token preceding it on the same line. This
  # handles situations like `@do|` where a do/end snippet would be invalid.
  defguardp valid_do_prefix(kind, value)
            when (kind === :identifier and value === ~c"d") or
                   (kind === :operator and value === :do)

  defguardp space_before_preceding_token(do_col, preceding_col)
            when do_col - preceding_col > 1

  defp should_emit_do_end_snippet?(%Env{} = env) do
    prefix_tokens = Env.prefix_tokens(env, 2)

    valid_prefix? =
      match?(
        [{kind, value, {line, do_col}}, {_, _, {line, preceding_col}}]
        when space_before_preceding_token(do_col, preceding_col) and
               valid_do_prefix(kind, value),
        prefix_tokens
      )

    valid_prefix? and Env.empty?(env.suffix)
  end

  defp to_completion_items(
         local_completions,
         %Project{} = project,
         %Env{} = env,
         %CompletionContext{} = context
       ) do
    debug_local_completions(local_completions)

    for result <- local_completions,
        displayable?(result),
        applies_to_context?(project, result, context),
        applies_to_env?(env, result),
        %CompletionItem{} = item <- to_completion_item(result, env) do
      item
    end
  end

  defp debug_local_completions(completions) do
    completions_by_type =
      Enum.group_by(completions, fn %candidate_module{} ->
        candidate_module
        |> Atom.to_string()
        |> String.split(".")
        |> List.last()
        |> String.downcase()
      end)

    log_iodata =
      Enum.reduce(completions_by_type, ["Local completions are: ["], fn {type, completions},
                                                                        acc ->
        names =
          Enum.map_join(completions, ", ", fn candidate ->
            Map.get(candidate, :name) || Map.get(candidate, :detail)
          end)

        [acc, [type, ": (", names], ")   "]
      end)

    Logger.info([log_iodata, "]"])
  end

  defp to_completion_item(candidate, env) do
    candidate
    |> Translatable.translate(Builder, env)
    |> List.wrap()
  end

  # Hide internal namespaced modules from project completion results.
  defp displayable?(result) do
    case result do
      %_{full_name: full_name} when is_binary(full_name) ->
        not Forge.Namespace.Module.prefixed?(full_name)

      %_{origin: origin} when is_binary(origin) ->
        not Forge.Namespace.Module.prefixed?(origin)

      _ ->
        true
    end
  end

  defp applies_to_env?(%Env{} = env, %struct_module{} = result) do
    cond do
      Env.in_context?(env, :struct_reference) ->
        struct_reference_completion?(result, env)

      Env.in_context?(env, :bitstring) ->
        struct_module in [Candidate.BitstringOption, Candidate.Variable]

      Env.in_context?(env, :alias) ->
        struct_module in [
          Candidate.Behaviour,
          Candidate.Module,
          Candidate.Protocol,
          Candidate.Struct
        ]

      Env.in_context?(env, :use) ->
        # only allow modules that define __using__ in a use statement
        usable?(env, result)

      Env.in_context?(env, :impl) ->
        # only allow behaviour modules after @impl
        behaviour?(env, result)

      Env.in_context?(env, :spec) or Env.in_context?(env, :type) ->
        typespec_or_type_candidate?(result, env)

      true ->
        struct_module != Candidate.Typespec
    end
  end

  # Accept a module after `use` when it or a nested module defines `__using__/1`.
  defp usable?(%Env{} = env, %{full_name: full_name}) when is_binary(full_name) do
    Enum.any?(in_tree(env.project, full_name), fn module ->
      case Callables.exports(env.project, module) do
        {:ok, exports} -> {"__using__", 1} in exports.macros
        :error -> false
      end
    end)
  end

  defp usable?(_env, _completion), do: false

  # Accept a module after `@impl` when it or a nested module is a behaviour.
  defp behaviour?(%Env{} = env, %{full_name: full_name}) when is_binary(full_name) do
    Enum.any?(in_tree(env.project, full_name), fn module ->
      case Modules.compiled(env.project, module) do
        {:ok, compiled} -> :behaviour in compiled.kinds
        :error -> false
      end
    end)
  end

  defp behaviour?(_env, _completion), do: false

  defp in_tree(project, full_name),
    do: [full_name | Modules.with_prefix(project, full_name <> ".")]

  defp struct_reference_completion?(%Candidate.Struct{}, _) do
    true
  end

  defp struct_reference_completion?(%Candidate.Module{} = module, %Env{} = env) do
    Intelligence.defines_struct?(env.project, module.full_name, to: :great_grandchild)
  end

  defp struct_reference_completion?(%Candidate.Macro{name: "__MODULE__"}, _) do
    true
  end

  defp struct_reference_completion?(_, _) do
    false
  end

  defp typespec_or_type_candidate?(%struct_module{}, _)
       when struct_module in [Candidate.Module, Candidate.Typespec, Candidate.ModuleAttribute] do
    true
  end

  defp typespec_or_type_candidate?(%Candidate.Function{} = function, %Env{} = env) do
    function.origin == env.position_module
  end

  defp typespec_or_type_candidate?(_, _) do
    false
  end

  defp applies_to_context?(%Project{} = project, result, %CompletionContext{} = context) do
    struct_completion? =
      context.trigger_kind == CompletionTriggerKind.trigger_character() and
        context.trigger_character == "%"

    if struct_completion? do
      case result do
        %Candidate.Module{} = result ->
          Intelligence.defines_struct?(project, result.full_name, from: :child, to: :child)

        %Candidate.Struct{} ->
          true

        _other ->
          false
      end
    else
      true
    end
  end

  defp maybe_to_completion_list(items \\ [])

  defp maybe_to_completion_list([]) do
    %CompletionList{items: [], is_incomplete: true}
  end

  defp maybe_to_completion_list(items), do: items
end
