defmodule Engine.Search.Indexer.Extractors.FunctionDefinition do
  alias Engine.Analyzer
  alias Engine.Search.Indexer.Source.Reducer
  alias Engine.Search.Subject
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Search.Indexer.Entry

  @function_definitions [:def, :defp, :defmacro, :defmacrop]

  def extract({definition, _, [{fn_name, _, _} = def_ast | body]} = ast, %Reducer{} = reducer)
      when is_atom(fn_name) and definition in @function_definitions do
    with {:ok, detail_range} <- Ast.Range.fetch(def_ast, reducer.analysis.document),
         true <- valid_bodyless_head?(body, reducer.analysis, detail_range),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, detail_range.start),
         {fun_name, arity} when is_atom(fun_name) <- fun_name_and_arity(def_ast) do
      min_arity = arity - count_defaults(extract_args(def_ast))
      block_r = block_range(reducer.analysis, ast)
      fun_type = type(definition)
      app = Engine.ApplicationCache.application(module)

      entries =
        for a <- min_arity..arity do
          Entry.block_definition(
            reducer.analysis.document.path,
            Reducer.current_block(reducer),
            Subject.mfa(module, fun_name, a),
            fun_type,
            block_r,
            detail_range,
            app
          )
        end

      args_and_guards =
        case def_ast do
          {:when, _, [{_, _, args} | guards]} -> [args | guards]
          {_, _, args} -> args
        end

      {:ok, entries, [args_and_guards, body]}
    else
      _ ->
        :ignored
    end
  end

  def extract({:defdelegate, _, [call, _]} = node, %Reducer{} = reducer) do
    document = reducer.analysis.document

    with {:ok, detail_range} <- Ast.Range.fetch(call, document),
         {:ok, module} <- Analyzer.current_module(reducer.analysis, detail_range.start),
         {:ok, {delegated_module, delegated_name, _delegated_arity}} <-
           fetch_delegated_mfa(node, reducer.analysis, detail_range.start) do
      {delegate_name, args} = Macro.decompose_call(call)
      arity = length(args)

      metadata = %{
        original_arity: arity,
        original_function: delegated_name,
        original_mfa: Subject.mfa(delegated_module, delegated_name, arity),
        original_module: delegated_module
      }

      entries =
        for a <- (arity - count_defaults(extract_args(call)))..arity do
          document.path
          |> Entry.definition(
            Reducer.current_block(reducer),
            Subject.mfa(module, delegate_name, a),
            {:function, :delegate},
            detail_range,
            Engine.ApplicationCache.application(module)
          )
          |> Entry.put_metadata(metadata)
        end

      {:ok, entries}
    else
      _ ->
        :ignored
    end
  end

  def extract(_ast, _reducer) do
    :ignored
  end

  def fetch_delegated_mfa({:defdelegate, _, [call | keywords]}, analysis, position) do
    {_, keyword_args} =
      Macro.prewalk(keywords, [], fn
        {{:__block__, _, [:to]}, {:__aliases__, _, delegated_module}} = ast, acc ->
          {ast, Keyword.put(acc, :to, delegated_module)}

        {{:__block__, _, [:as]}, {:__block__, _, [remote_fun_name]}} = ast, acc ->
          {ast, Keyword.put(acc, :as, remote_fun_name)}

        ast, acc ->
          {ast, acc}
      end)

    with {function_name, args} <- Macro.decompose_call(call),
         {:ok, module} <- Analyzer.expand_alias(keyword_args[:to], analysis, position) do
      function_name = Keyword.get(keyword_args, :as, function_name)
      {:ok, {module, function_name, length(args)}}
    else
      _ ->
        :error
    end
  end

  defp extract_args({:when, _, [{_fun_name, _, fun_args} | _]}), do: fun_args || []
  defp extract_args({_fun_name, _, fun_args}), do: fun_args || []

  defp valid_bodyless_head?([], %Analysis{valid?: false, document: document}, range) do
    # Partial AST can make `def run(arg do ... end` look like a bodyless declaration.
    source = Forge.Document.fragment(document, range.start, range.end)
    match?({:ok, _}, Code.string_to_quoted(source))
  end

  defp valid_bodyless_head?(_body, _analysis, _range), do: true

  defp count_defaults(args) do
    Enum.count(args, &match?({:\\, _, _}, &1))
  end

  defp type(:def), do: {:function, :public}
  defp type(:defp), do: {:function, :private}
  defp type(:defmacro), do: {:macro, :public}
  defp type(:defmacrop), do: {:macro, :private}

  defp fun_name_and_arity({:when, _, [{fun_name, _, fun_args} | _]}) do
    # a function with guards
    {fun_name, arity(fun_args)}
  end

  defp fun_name_and_arity({fun_name, _, fun_args}) do
    {fun_name, arity(fun_args)}
  end

  defp arity(nil), do: 0
  defp arity(args) when is_list(args), do: length(args)

  defp block_range(%Analysis{} = analysis, def_ast) do
    case Ast.Range.fetch(def_ast, analysis.document) do
      {:ok, range} -> range
      _ -> nil
    end
  end
end
