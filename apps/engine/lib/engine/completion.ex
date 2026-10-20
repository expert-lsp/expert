defmodule Engine.Completion do
  import Forge.Document.Line
  import Forge.Logging

  alias Engine.CodeMod.Format.Cache
  alias Engine.Module.Loader
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection.StructReference
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate
  alias Forge.Document
  alias Forge.Document.Position

  def elixir_sense_expand(%Env{} = env) do
    {doc_string, position} = strip_struct_operator(env)

    line = position.line
    character = position.character
    hint = ElixirSense.Core.Source.prefix(doc_string, line, character)

    if String.trim(hint) == "" do
      []
    else
      fetch_result =
        timed_log("formatter for file", fn ->
          Cache.fetch_formatter(env.project, env.document.path)
        end)

      locals_without_parens =
        case fetch_result do
          {:ok, _formatter, opts} ->
            Keyword.fetch!(opts, :locals_without_parens)

          :error ->
            []
        end

      for suggestion <-
            timed_log("ES suggestions", fn ->
              ElixirSense.suggestions(doc_string, line, character)
            end),
          suggestion <- expand_default_arguments(suggestion),
          candidate =
            timed_log("from_elixir_sense", fn ->
              from_elixir_sense(suggestion, locals_without_parens)
            end),
          candidate != nil do
        candidate
      end
    end
  end

  # ElixirSense groups default-argument variants into one full-arity suggestion.
  # Expand them before conversion so argument names are selected for each arity.
  defp expand_default_arguments(%{type: type, arity: arity, default_args: defaults} = suggestion)
       when type in [:function, :macro] do
    for variant_arity <- (arity - defaults)..arity do
      %{suggestion | arity: variant_arity}
    end
  end

  defp expand_default_arguments(suggestion), do: [suggestion]

  defp from_elixir_sense(suggestion, locals_without_parens) do
    suggestion
    |> Candidate.from_elixir_sense()
    |> maybe_suppress_parens(locals_without_parens)
  end

  defp maybe_suppress_parens(%struct{} = candidate, locals_without_parens)
       when struct in [Candidate.Function, Candidate.Macro, Candidate.Typespec] do
    atom_name = String.to_atom(candidate.name)
    suppress_parens? = local_without_parens?(atom_name, candidate.arity, locals_without_parens)

    %{candidate | parens?: not suppress_parens?}
  end

  defp maybe_suppress_parens(candidate, _), do: candidate

  defp local_without_parens?(fun, arity, locals_without_parens) do
    arity > 0 and
      Enum.any?(locals_without_parens, fn
        {^fun, :*} -> true
        {^fun, ^arity} -> true
        _ -> false
      end)
  end

  def struct_fields(%Analysis{} = analysis, %Position{} = position) do
    container_struct_module =
      analysis
      |> Forge.Ast.cursor_path(position)
      |> container_struct_module()

    with {:ok, struct_module} <-
           Engine.Analyzer.expand_alias(container_struct_module, analysis, position),
         true <- Loader.ensure_loaded?(struct_module),
         true <- function_exported?(struct_module, :__struct__, 0) do
      struct_module
      |> struct()
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.map(&Candidate.StructField.new(&1, struct_module))
    else
      _ -> []
    end
  end

  defp container_struct_module(cursor_path) do
    Enum.find_value(cursor_path, fn
      # current module struct: `%__MODULE__{|}`
      {:%, _, [{:__MODULE__, _, _} | _]} -> [:__MODULE__]
      # struct leading by current module: `%__MODULE__.Struct{|}`
      {:%, _, [{:__aliases__, _, [{:__MODULE__, _, _} | tail]} | _]} -> [:__MODULE__ | tail]
      # Struct leading by alias or just a aliased Struct: `%Struct{|}`, `%Project.Struct{|}`
      {:%, _, [{:__aliases__, _, aliases} | _]} -> aliases
      _ -> nil
    end)
  end

  # HACK: This fixes ElixirSense struct completions for certain cases.
  # We should try removing when we update or remove ElixirSense.
  defp strip_struct_operator(%Env{} = env) do
    with true <- Env.in_context?(env, :struct_reference),
         {:ok, completion_length} <- fetch_struct_completion_length(env) do
      column = env.position.character
      percent_position = column - (completion_length + 1)

      new_line_start = String.slice(env.line, 0, percent_position - 1)
      new_line_end = String.slice(env.line, percent_position..-1//1)
      new_line = [new_line_start, new_line_end]
      new_position = Position.new(env.document, env.position.line, env.position.character - 1)
      line_to_replace = env.position.line

      stripped_text =
        env.document.lines
        |> Enum.with_index(1)
        |> Enum.reduce([], fn
          {line(ending: ending), ^line_to_replace}, acc ->
            [acc, new_line, ending]

          {line(text: line_text, ending: ending), _}, acc ->
            [acc, line_text, ending]
        end)
        |> IO.iodata_to_binary()

      {stripped_text, new_position}
    else
      _ ->
        doc_string = Document.to_string(env.document)
        {doc_string, env.position}
    end
  end

  defp fetch_struct_completion_length(env) do
    case Code.Fragment.cursor_context(env.prefix) do
      {:struct, context} -> StructReference.reference_length(context)
      {:local_or_var, local_name} -> {:ok, length(local_name)}
      _ -> :error
    end
  end
end
