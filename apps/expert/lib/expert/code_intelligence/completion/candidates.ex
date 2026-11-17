defmodule Expert.CodeIntelligence.Completion.Candidates do
  @moduledoc """
  Finds completion candidates for the code before the cursor.
  """

  alias Expert.CodeIntelligence.Completion.Attributes
  alias Expert.CodeIntelligence.Completion.BitstringOptions
  alias Expert.CodeIntelligence.Completion.Callables
  alias Expert.CodeIntelligence.Completion.Callbacks
  alias Expert.CodeIntelligence.Completion.Context
  alias Expert.CodeIntelligence.Completion.Fields
  alias Expert.CodeIntelligence.Completion.Modules
  alias Expert.CodeIntelligence.Completion.Typespecs
  alias Forge.Ast.Analysis
  alias Forge.Ast.Env
  alias Forge.Document

  @typed ~r/[\p{L}\p{N}\.\_\!\?\:\@\&\^\~\+\-\<\>\=\*\/\|\\]+$/u
  @multi_alias ~r/(alias|require|import|use)\s+(?<module>[^\s{}]+?)\.\{[^}]*?$/u
  @definition_head ~r/(^|\s)(def|defmacro)\s+([_\p{Ll}\p{Lo}][\p{L}\p{N}_]*[?!]?)?$/u
  @alias_forms [~c"alias", ~c"import", ~c"require"]
  @typespec_contexts [:spec, :type, :callback, :macrocallback]

  @spec for_env(Env.t(), Analysis.t()) :: [struct()]
  def for_env(%Env{} = env, %Analysis{} = document_analysis) do
    case Regex.run(@typed, env.prefix) do
      [typed] ->
        context = Context.new(env, document_analysis)
        typed = qualify(typed, context, env)
        cursor_context = typed |> String.to_charlist() |> Code.Fragment.cursor_context()

        with :error <- bitstring_options(cursor_context, context),
             {:add, definitions} <- definitions(typed, context, env) do
          definitions ++ expand(cursor_context, context)
        else
          {:only, candidates} -> candidates
        end

      nil ->
        []
    end
  end

  defp bitstring_options(cursor_context, context) do
    hint =
      case cursor_context do
        {:local_or_var, hint} -> List.to_string(hint)
        {:operator, operator} when operator in [~c"::", ~c"-"] -> ""
        {:operator, ~c"in"} -> "in"
        _other -> nil
      end

    with true <- is_binary(hint),
         {:ok, written} <- BitstringOptions.written(context.cursor_path) do
      {:only, BitstringOptions.matching(written, hint)}
    else
      _ -> :error
    end
  end

  # Typespec and definition heads limit the applicable candidate kinds.
  defp definitions(typed, context, env) do
    cond do
      Enum.any?(@typespec_contexts, &Env.in_context?(env, &1)) ->
        {:add, Typespecs.matching(context, typed)}

      Regex.match?(@definition_head, env.prefix) ->
        {:only, Callbacks.matching(context, typed)}

      context.function? ->
        {:add, []}

      true ->
        {:add, Callbacks.matching(context, typed)}
    end
  end

  # Multi-alias syntax makes the typed name relative to its parent alias.
  defp qualify(typed, %Context{} = context, %Env{} = env) do
    text_before = Document.fragment(env.document, env.position)

    text_before =
      binary_part(
        text_before,
        max(byte_size(text_before) - 4096, 0),
        min(byte_size(text_before), 4096)
      )

    typed =
      with %{"module" => parent} <- Regex.named_captures(@multi_alias, text_before),
           {:ok, {:__aliases__, _, segments}} <- Code.string_to_quoted(parent),
           true <- Enum.all?(segments, &is_atom/1) do
        inspect(Context.expand_alias(context, segments)) <> "." <> typed
      else
        _ -> typed
      end

    case {typed, context.module} do
      {"__MODULE__" <> rest, module} when not is_nil(module) -> inspect(module) <> rest
      _ -> typed
    end
  end

  defp expand({:alias, typed}, context), do: Modules.elixir(context, List.to_string(typed))

  defp expand(
         {:alias, {:local_or_var, ~c"__MODULE__"}, typed},
         %Context{module: module} = context
       )
       when not is_nil(module) do
    Modules.elixir(context, "#{inspect(module)}.#{typed}")
  end

  defp expand({:unquoted_atom, typed}, context),
    do: Modules.erlang(context, List.to_string(typed))

  defp expand({:module_attribute, hint}, context),
    do: Attributes.matching(context, List.to_string(hint))

  defp expand({:struct, {:module_attribute, hint}}, context),
    do: Attributes.matching(context, List.to_string(hint))

  defp expand({:dot, path, hint}, context), do: dot(path, List.to_string(hint), context, [])

  defp expand({:dot_arity, path, hint}, context) do
    case module(path, context) do
      {:ok, module} -> Callables.remote(context, module, List.to_string(hint), exact?: true)
      :error -> []
    end
  end

  defp expand({:local_or_var, hint}, context), do: Callables.local(context, List.to_string(hint))

  defp expand({:local_arity, hint}, context),
    do: Callables.local(context, List.to_string(hint), exact?: true)

  defp expand({:local_call, form}, context) when form in @alias_forms,
    do: Modules.elixir(context, "")

  defp expand({:operator, ~c"^"}, _context), do: []
  defp expand({:operator, ~c"&"}, context), do: expression(context)

  defp expand({:operator, operator}, context),
    do: Callables.local(context, List.to_string(operator))

  defp expand({:operator_arity, operator}, context),
    do: Callables.local(context, List.to_string(operator), exact?: true)

  defp expand({:operator_call, _operator}, context), do: Callables.local(context, "")

  defp expand({:struct, typed}, context) when is_list(typed),
    do: Modules.elixir(context, List.to_string(typed), structs_only?: true)

  defp expand({:struct, {:alias, {:local_or_var, ~c"__MODULE__"}, typed}}, %Context{} = context)
       when not is_nil(context.module) do
    Modules.elixir(context, "#{inspect(context.module)}.#{typed}", structs_only?: true)
  end

  defp expand({:struct, {:dot, path, hint}}, context),
    do: dot(path, List.to_string(hint), context, structs_only?: true)

  defp expand({:struct, {:local_or_var, hint}}, context),
    do: Callables.local(context, List.to_string(hint))

  defp expand(:expr, context), do: expression(context)
  defp expand({:dot_call, _path, _hint}, context), do: expression(context)
  defp expand({:local_call, _name}, context), do: expression(context)
  defp expand({:anonymous_call, _call}, context), do: expression(context)

  defp expand(_cursor_context, _context), do: []

  defp expression(context) do
    Callables.local(context, "") ++
      Modules.erlang(context, "") ++
      Modules.elixir(context, "") ++
      Attributes.matching(context, "")
  end

  # An empty hint after a dot also includes nested modules.
  defp dot(path, hint, context, opts) do
    case module(path, context) do
      {:ok, module} when hint == "" ->
        nested =
          if Macro.classify_atom(module) == :alias,
            do: Modules.elixir(context, inspect(module) <> ".", opts),
            else: []

        if Keyword.get(opts, :structs_only?, false),
          do: nested,
          else: nested ++ Callables.remote(context, module, "")

      {:ok, module} ->
        Callables.remote(context, module, hint)

      :error ->
        case path do
          {:var, variable} -> Fields.after_dot(context, List.to_atom(variable), hint)
          _other -> []
        end
    end
  end

  defp module({:alias, typed}, context) do
    segments = typed |> List.to_string() |> String.split(".") |> Enum.map(&String.to_atom/1)
    {:ok, Context.expand_alias(context, segments)}
  end

  defp module({:alias, {:local_or_var, ~c"__MODULE__"}, typed}, %Context{module: module})
       when not is_nil(module) do
    {:ok, Module.concat([module | typed |> List.to_string() |> String.split(".")])}
  end

  defp module({:unquoted_atom, typed}, _context), do: {:ok, List.to_atom(typed)}

  defp module({:var, ~c"__MODULE__"}, %Context{module: module}) when not is_nil(module),
    do: {:ok, module}

  defp module(_path, _context), do: :error
end
