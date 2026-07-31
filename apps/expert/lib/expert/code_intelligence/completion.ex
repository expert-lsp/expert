defmodule Expert.CodeIntelligence.Completion do
  alias Expert.CodeIntelligence.Completion.Builder
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Hex
  alias Expert.Configuration
  alias Expert.EngineApi
  alias Expert.Project.Intelligence
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Document.Changes
  alias Forge.Document.Edit
  alias Forge.Document.Position
  alias Forge.Project
  alias GenLSP.Enumerations.CompletionTriggerKind
  alias GenLSP.Structures.CompletionContext
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.CompletionList

  require Logger

  @expert_deps Enum.map([:expert | Mix.Project.deps_apps()], &Atom.to_string/1)

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
            case Hex.Context.detect(analysis, position) do
              {:ok, ctx} -> ctx
              :error -> nil
            end
          end

        hex_items = hex_items_for_context(hex_context, project, env)
        {regular_items, contextual_incomplete?} = completions(project, env, context)
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

  defp completions(%Project{} = project, %Env{} = env, %CompletionContext{} = context) do
    case EngineApi.contextual_completion(project, env) do
      {:override, candidates, incomplete?, _transforms} ->
        {translate_contextual_candidates(candidates, env), incomplete?}

      {:augment, candidates, incomplete?, transforms} ->
        contextual_items = translate_contextual_candidates(candidates, env)
        ordinary_items = project |> ordinary_completions(env, context) |> transform(transforms)
        augment(contextual_items, ordinary_items, incomplete?)

      :ignore ->
        {ordinary_completions(project, env, context), false}
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

  defp ordinary_completions(project, env, context) do
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
        project
        |> EngineApi.complete_struct_fields(env.analysis, env.position)
        |> Enum.map(&Translatable.translate(&1, Builder, env))

      true ->
        project
        |> EngineApi.complete(env)
        |> to_completion_items(project, env, context)
    end
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
    project_apps = EngineApi.project_apps(project)

    for result <- local_completions,
        displayable?(project, project_apps, result),
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

  defp displayable?(%Project{} = project, project_apps, result) do
    suggested_module =
      case result do
        %_{full_name: full_name} when is_binary(full_name) -> full_name
        %_{origin: origin} when is_binary(origin) -> origin
        _ -> ""
      end

    cond do
      Forge.Namespace.Module.prefixed?(suggested_module) ->
        false

      # If we're working on the dependency, we should include it!
      Project.name(project) in @expert_deps ->
        true

      true ->
        project_module?(project, project_apps, suggested_module, result)
    end
  end

  defp project_module?(_, _, "", _), do: true

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp project_module?(%Project{} = project, project_apps, suggested_module, result) do
    module = module_string_to_atom(suggested_module)
    module_app = Application.get_application(module)
    project_app = Application.get_application(project.project_module)

    metadata = Map.get(result, :metadata)

    result_app = metadata[:app]

    cond do
      module_app in project_apps ->
        true

      # This is useful for some struct field completions, where
      # a suggested module is not always part of the result struct,
      # but the application is.
      # If no application is set though, it's usually part of a result
      # that is not part of any application yet.
      result_app in project_apps or is_nil(metadata) ->
        true

      not is_nil(module_app) and module_app == project_app ->
        true

      is_nil(module_app) and not is_nil(project.project_module) and
          module == project.project_module ->
        true

      true ->
        # Results not belonging to an application or the project are most
        # likely to be defined in a test or .exs file.
        is_nil(module_app) and is_nil(project.project_module)
    end
  end

  defp module_string_to_atom(""), do: nil

  defp module_string_to_atom(module_string) do
    Forge.Ast.Module.to_atom(module_string)
  rescue
    _e in ArgumentError ->
      # Return nil if we can't safely convert the module string to an atom
      nil
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

  defp usable?(%Env{} = env, completion) do
    # returns true if the given completion is or is a parent of
    # a module that defines __using__
    case completion do
      %{full_name: full_name} ->
        with_prefix =
          EngineApi.modules_with_prefix(
            env.project,
            full_name,
            {Kernel, :macro_exported?, [:__using__, 1]}
          )

        not Enum.empty?(with_prefix)

      _ ->
        false
    end
  end

  defp behaviour?(%Env{} = env, completion) do
    # returns true if the given completion is or is a parent of
    # a module that is a behaviour

    case completion do
      %{full_name: full_name} ->
        with_prefix =
          EngineApi.modules_with_prefix(
            env.project,
            full_name,
            {Kernel, :function_exported?, [:behaviour_info, 1]}
          )

        not Enum.empty?(with_prefix)

      _ ->
        false
    end
  end

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
    case EngineApi.expand_alias(env.project, [:__MODULE__], env.analysis, env.position) do
      {:ok, expanded} ->
        expanded == function.origin

      _error ->
        false
    end
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
