defmodule Engine.CodeIntelligence.Entity do
  alias Forge.Ast
  alias Forge.Ast.Analysis
  alias Forge.Ast.Detection
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Formats
  alias Future.Code, as: Code
  alias Sourceror.Zipper

  require Logger
  require Sourceror.Identifier

  @type maybe_module :: module() | nil
  @type resolved ::
          {:module, maybe_module()}
          | {:struct, maybe_module()}
          | {:call, maybe_module(), fun_name :: atom(), arity :: non_neg_integer()}
          | {:type, maybe_module(), type_name :: atom(), arity :: non_neg_integer()}
          | {:module_attribute, container_module :: maybe_module(), attribute_name :: atom()}
          | {:variable, variable_name :: atom()}

  defguardp is_call(form) when Sourceror.Identifier.is_call(form) and elem(form, 0) != :.

  @doc """
  Attempts to resolve the entity at the given position in the document.

  Returns `{:ok, resolved, range}` if successful, `{:error, error}` otherwise.
  """
  @spec resolve(Analysis.t(), Position.t()) :: {:ok, resolved, Range.t()} | {:error, term()}
  def resolve(%Analysis{} = analysis, %Position{} = position) do
    analysis =
      analysis
      |> Ast.reanalyze_to(position)
      |> Engine.CodeIntelligence.Heex.maybe_normalize(position)

    with :ok <- check_commented(analysis, position),
         :ok <- check_in_string(analysis, position),
         {:ok, surround_context} <- Ast.surround_context(analysis, position),
         {:ok, resolved, {begin_pos, end_pos}} <-
           resolve(surround_context, analysis, position) do
      Logger.info("Resolved entity: #{inspect(resolved)}")
      {:ok, resolved, to_range(analysis.document, begin_pos, end_pos)}
    else
      :error ->
        {:error, :not_found}

      {:error, :surround_context} ->
        case maybe_local_capture_func(analysis, position) do
          {:ok, _, _} = result -> result
          _ -> {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  @spec to_range(Document.t(), Code.position(), Code.position()) :: Range.t()
  def to_range(%Document{} = document, {begin_line, begin_column}, {end_line, end_column}) do
    Range.new(
      Position.new(document, begin_line, begin_column),
      Position.new(document, end_line, end_column)
    )
  end

  defp check_commented(%Analysis{} = analysis, %Position{} = position) do
    if Analysis.commented?(analysis, position) do
      :error
    else
      :ok
    end
  end

  defp check_in_string(%Analysis{} = analysis, %Position{} = position) do
    if Detection.String.detected?(analysis, position) do
      {:error, :in_string}
    else
      :ok
    end
  end

  defp resolve(%{context: context, begin: begin_pos, end: end_pos}, analysis, position) do
    resolve(context, {begin_pos, end_pos}, analysis, position)
  end

  defp resolve({:alias, charlist}, node_range, analysis, position) do
    resolve_alias(charlist, node_range, analysis, position)
  end

  defp resolve({:alias, {:local_or_var, prefix}, charlist}, node_range, analysis, position) do
    resolve_alias(prefix ++ [?.] ++ charlist, node_range, analysis, position)
  end

  defp resolve({:local_or_var, ~c"__MODULE__" = chars}, node_range, analysis, position) do
    resolve_alias(chars, node_range, analysis, position)
  end

  defp resolve({:local_or_var, chars}, node_range, analysis, position) do
    maybe_fun = List.to_atom(chars)

    case Ast.path_at(analysis, position) do
      {:ok, [{^maybe_fun, _, nil} = local, {def, _, [local | _]} | _]}
      when def in [:def, :defp, :defmacro, :defmacrop] ->
        # This case handles resolving calls that come from zero-arg definitions in
        # a module, like hovering in `def my_fun| do`
        {:ok, module} = Engine.Analyzer.current_module(analysis, position)
        {:ok, {:call, module, maybe_fun, 0}, node_range}

      {:ok, [{^maybe_fun, _, args} | _]} ->
        # imported functions
        arity =
          case args do
            arg_list when is_list(arg_list) -> length(arg_list)
            _ -> 0
          end

        case fetch_module_for_function(analysis, position, maybe_fun, arity) do
          {:ok, module} -> {:ok, {:call, module, maybe_fun, arity}, node_range}
          _ -> {:ok, {:variable, List.to_atom(chars)}, node_range}
        end

      _ ->
        {:ok, {:variable, List.to_atom(chars)}, node_range}
    end
  end

  defp resolve({:local_arity, chars}, node_range, analysis, position) do
    fun = List.to_atom(chars)

    with {:ok, %Zipper{node: {:/, _, [_, {:__block__, _, [arity]}]}} = zipper} <-
           Ast.zipper_at(analysis.document, position),
         true <- inside_capture?(zipper) do
      module =
        case fetch_module_for_function(analysis, position, fun, arity) do
          {:ok, mod} -> mod
          _ -> current_module(analysis, position)
        end

      {:ok, {:call, module, fun, arity}, node_range}
    else
      _ ->
        {:error, :not_found}
    end
  end

  defp resolve({:struct, charlist}, {{start_line, start_col}, end_pos}, analysis, position) do
    # exclude the leading % from the node range so that it can be
    # resolved like a normal module alias
    node_range = {{start_line, start_col + 1}, end_pos}

    case resolve_alias(charlist, node_range, analysis, position) do
      {:ok, {struct_or_module, struct}, range} -> {:ok, {struct_or_module, struct}, range}
      :error -> {:error, :not_found}
    end
  end

  defp resolve({:dot, alias_node, fun_chars}, node_range, analysis, position) do
    fun = List.to_atom(fun_chars)

    with {:ok, module} <- expand_alias(alias_node, analysis, position) do
      case Ast.path_at(analysis, position) do
        {:ok, path} ->
          arity = resolve_arity(path, position, analysis)
          kind = kind_of_call(path, position)
          {:ok, {kind, module, fun, arity}, node_range}

        _ ->
          {:ok, {:call, module, fun, 0}, node_range}
      end
    end
  end

  defp resolve({:local_call, fun_chars}, node_range, analysis, position) do
    fun = List.to_atom(fun_chars)

    with {:ok, path} <- Ast.path_at(analysis, position),
         arity = resolve_arity(path, position, analysis),
         {module, ^fun, ^arity} <-
           Engine.Analyzer.resolve_local_call(analysis, position, fun, arity) do
      {:ok, {:call, module, fun, arity}, node_range}
    else
      _ ->
        module = current_module(analysis, position)
        {:ok, {:call, module, fun, 0}, node_range}
    end
  end

  defp resolve({:unquoted_atom, _} = context, node_range, analysis, position) do
    case expand_alias(context, analysis, position) do
      {:ok, module} -> {:ok, {:module, module}, node_range}
      _ -> {:error, {:unsupported, context}}
    end
  end

  defp resolve({:module_attribute, attr_name}, node_range, analysis, position) do
    current_module = current_module(analysis, position)

    {:ok, {:module_attribute, current_module, List.to_atom(attr_name)}, node_range}
  end

  defp resolve(context, _node_range, _analysis, _position) do
    {:error, {:unsupported, context}}
  end

  defp resolve_alias(charlist, node_range, analysis, position) do
    {{_line, start_column}, _} = node_range

    with false <- suffix_contains_module?(charlist, start_column, position),
         {:ok, path} <- Ast.path_at(analysis, position),
         :struct <- kind_of_alias(path) do
      resolve_struct(charlist, node_range, analysis, position)
    else
      _ ->
        resolve_module(charlist, node_range, analysis, position)
    end
  end

  defp resolve_struct(charlist, node_range, analysis, %Position{} = position) do
    with {:ok, struct} <- expand_alias(charlist, analysis, position) do
      {:ok, {:struct, struct}, node_range}
    end
  end

  # Modules on a single line, e.g. "Foo.Bar.Baz"
  defp resolve_module(charlist, {{line, column}, {line, _}}, analysis, %Position{} = position) do
    module_before_cursor = module_before_position(charlist, column, position)

    maybe_prepended =
      module_before_cursor
      |> maybe_prepend_phoenix_scope_module(analysis, position)
      |> maybe_prepend_ecto_schema(analysis, position)

    with {:ok, module} <- expand_alias(maybe_prepended, analysis, position) do
      end_column = column + String.length(module_before_cursor)
      {:ok, {:module, module}, {{line, column}, {line, end_column}}}
    end
  end

  # Modules on multiple lines, e.g. "Foo.\n  Bar.\n  Baz"
  # Since we no longer have formatting information at this point, we
  # just return the entire module for now.
  defp resolve_module(charlist, node_range, analysis, %Position{} = position) do
    with {:ok, module} <- expand_alias(charlist, analysis, position) do
      {:ok, {:module, module}, node_range}
    end
  end

  defp maybe_prepend_ecto_schema(module_string, %Analysis{} = analysis, %Position{} = position) do
    with true <- Ecto.Schema in Engine.Analyzer.uses_at(analysis, position),
         true <- in_inline_embed?(analysis, position),
         {:ok, parent_module} <- Engine.Analyzer.current_module(analysis, position) do
      parent_module
      |> Module.concat(module_string)
      |> Formats.module()
    else
      _ ->
        module_string
    end
  end

  @embeds [:embeds_one, :embeds_many]
  defp in_inline_embed?(%Analysis{} = analysis, %Position{} = position) do
    case Ast.path_at(analysis, position) do
      {:ok, path} ->
        path
        |> Zipper.zip()
        |> Zipper.find(fn
          {embed, meta, _} when embed in @embeds ->
            Keyword.has_key?(meta, :do)

          _ ->
            false
        end)
        |> then(&match?(%Zipper{}, &1))
    end
  end

  defp maybe_prepend_phoenix_scope_module(module_string, analysis, position) do
    with {:ok, scope_segments} <- fetch_phoenix_scope_alias_segments(analysis, position),
         {:ok, scope_module} <-
           Engine.Analyzer.expand_alias(scope_segments, analysis, position),
         cursor_module = Module.concat(scope_module, module_string),
         true <-
           phoenix_controller_module?(cursor_module) or phoenix_liveview_module?(cursor_module) do
      Formats.module(cursor_module)
    else
      _ ->
        module_string
    end
  end

  # fetch the alias segments from ancestor `scope` macros
  # e.g. `scope "/foo", FooWeb.Controllers`
  # the alias module is `FooWeb.Controllers`, and the segments is `[:FooWeb, :Controllers]`
  defp fetch_phoenix_scope_alias_segments(analysis, position) do
    # Ast.cursor_path returns nodes from innermost to outermost,
    # so we need to reverse.
    segments =
      analysis
      |> Ast.cursor_path(position)
      |> Enum.filter(&match?({:scope, _, [_ | _]}, &1))
      |> Enum.reverse()
      |> Enum.flat_map(fn
        {:scope, _, [_, {:__aliases__, _, segments} | _]} -> segments
        _ -> []
      end)

    if segments == [] do
      :error
    else
      {:ok, segments}
    end
  end

  defp phoenix_controller_module?(module) do
    function_exists?(module, :call, 2) and function_exists?(module, :action, 2)
  end

  defp phoenix_liveview_module?(module) do
    function_exists?(module, :mount, 3) and function_exists?(module, :render, 1)
  end

  # Take only the segments at and before the cursor, e.g.
  # Foo|.Bar.Baz -> Foo
  # Foo.|Bar.Baz -> Foo.Bar
  defp module_before_position(charlist, start_column, %Position{} = position)
       when is_list(charlist) do
    charlist
    |> List.to_string()
    |> module_before_position(position.character - start_column)
  end

  defp module_before_position(string, index) when is_binary(string) do
    {prefix, suffix} = String.split_at(string, index)

    case String.split(suffix, ".", parts: 2) do
      [before_dot, _after_dot] -> prefix <> before_dot
      [before_dot] -> prefix <> before_dot
    end
  end

  # %TopLevel|.Struct{} -> true
  # %TopLevel.Str|uct{} -> false
  defp suffix_contains_module?(charlist, start_column, %Position{} = position) do
    charlist
    |> List.to_string()
    |> suffix_contains_module?(position.character - start_column)
  end

  defp suffix_contains_module?(string, index) when is_binary(string) do
    {_, suffix} = String.split_at(string, index)

    case String.split(suffix, ".", parts: 2) do
      [_before_dot, after_dot] ->
        uppercase?(after_dot)

      [_before_dot] ->
        false
    end
  end

  defp uppercase?(after_dot) when is_binary(after_dot) do
    first_char = String.at(after_dot, 0)
    String.upcase(first_char) == first_char
  end

  defp expand_alias({:var, ~c"__MODULE__"}, analysis, %Position{} = position) do
    Engine.Analyzer.current_module(analysis, position)
  end

  defp expand_alias({:alias, {:local_or_var, prefix}, charlist}, analysis, %Position{} = position) do
    expand_alias(prefix ++ [?.] ++ charlist, analysis, position)
  end

  defp expand_alias({:alias, charlist}, analysis, %Position{} = position) do
    expand_alias(charlist, analysis, position)
  end

  defp expand_alias({:unquoted_atom, maybe_module_charlist}, _analysis, _position) do
    maybe_module = List.to_existing_atom(maybe_module_charlist)

    if function_exported?(maybe_module, :module_info, 1) do
      {:ok, maybe_module}
    else
      :error
    end
  rescue
    ArgumentError ->
      :error
  end

  defp expand_alias(charlist, analysis, %Position{} = position) when is_list(charlist) do
    charlist
    |> List.to_string()
    |> expand_alias(analysis, position)
  end

  defp expand_alias(module, analysis, %Position{} = position) when is_binary(module) do
    [module]
    |> Module.concat()
    |> Engine.Analyzer.expand_alias(analysis, position)
  end

  defp expand_alias(_, _analysis, _position), do: :error

  # Pipes:
  defp arity_at_position([{:|>, _, _} = pipe | _], %Position{} = position) do
    {_call, _, args} =
      pipe
      |> Macro.unpipe()
      |> Enum.find_value(fn {ast, _arg_position} ->
        if Ast.contains_position?(ast, position) do
          ast
        end
      end)

    length(args) + 1
  end

  # Calls inside of a pipe:
  # |> MyModule.some_function(1, 2)
  defp arity_at_position([{_, _, args} = call, {:|>, _, _} | _], _position) when is_call(call) do
    length(args) + 1
  end

  # Calls as part of a capture:
  # &MyModule.some_function/2
  defp arity_at_position(
         [
           # To correctly identify a fun/arity capture, the zero-arg call
           # should be the first argument to a `/` binary op, and that `/`
           # should be the only argument to a `&` unary op.
           {_, _, []} = call,
           {:/, _, [call, {:__block__, _, [arity]}]} = slash,
           {:&, _, [slash]} | _
         ],
         _position
       )
       when is_call(call) and is_integer(arity) do
    arity
  end

  # Calls not inside of a pipe:
  # MyModule.some_function(1, 2)
  # some_function.(1, 2)
  defp arity_at_position([{_, _, args} = call | _], _position) when is_call(call) do
    length(args)
  end

  defp arity_at_position([_non_call | rest], %Position{} = position) do
    arity_at_position(rest, position)
  end

  defp arity_at_position([], _position), do: 0

  defp resolve_arity(path, %Position{} = position, %Analysis{} = _analysis) do
    case Enum.find(path, &match?({:sigil_H, _, _}, &1)) do
      nil -> arity_at_position(path, position)
      sigil -> Engine.CodeIntelligence.Heex.arity(sigil, position, &arity_at_position/2)
    end
  end

  # Walk up the path to see whether we're in the right-hand argument of
  # a `::` type operator, which would make the kind a `:type`, not a call.
  # Calls that occur on the right of a `::` type operator have kind `:type`
  defp kind_of_call([{:"::", _, [_, right_arg]} | rest], %Position{} = position) do
    if Ast.contains_position?(right_arg, position) do
      :type
    else
      kind_of_call(rest, position)
    end
  end

  defp kind_of_call([_ | rest], %Position{} = position) do
    kind_of_call(rest, position)
  end

  defp kind_of_call([], _position), do: :call

  # There is a fixed set of situations where an alias is being used as
  # a `:struct`, otherwise resolve as a `:module`.
  defp kind_of_alias(path)

  # |%Foo{}
  defp kind_of_alias([{:%, _, _}]), do: :struct

  # %|Foo{}
  # %|Foo.Bar{}
  # %__MODULE__.|Foo{}
  defp kind_of_alias([{:__aliases__, _, _}, {:%, _, _} | _]), do: :struct

  # %|__MODULE__{}
  defp kind_of_alias([{:__MODULE__, _, nil}, {:%, _, _} | _]), do: :struct

  # %Foo|{}
  defp kind_of_alias([{:%{}, _, _}, {:%, _, _} | _]), do: :struct

  # %|__MODULE__.Foo{}
  defp kind_of_alias([head_of_aliases, {:__aliases__, _, [head_of_aliases | _]}, {:%, _, _} | _]) do
    :struct
  end

  # Catch-all:
  defp kind_of_alias(_), do: :module

  defp fetch_module_for_function(analysis, position, function_name, arity) do
    with :error <- fetch_module_for_local_function(analysis, position, function_name, arity) do
      Engine.Analyzer.import_module_for(analysis, position, function_name, arity)
    end
  end

  defp fetch_module_for_local_function(analysis, position, function_name, arity) do
    with {:ok, current_module} <- Engine.Analyzer.current_module(analysis, position),
         true <- function_exported?(current_module, function_name, arity) do
      {:ok, current_module}
    else
      _ -> :error
    end
  end

  defp function_exists?(module, function, arity) do
    # Wrap the `function_exported?` from `Kernel` to simplify testing.
    function_exported?(module, function, arity)
  end

  defp current_module(%Analysis{} = analysis, %Position{} = position) do
    case Engine.Analyzer.current_module(analysis, position) do
      {:ok, module} -> module
      _ -> nil
    end
  end

  defp maybe_local_capture_func(analysis, position) do
    with {:ok, %Zipper{node: {:/, _, [_, {:__block__, _, _}]}} = zipper} <-
           Ast.zipper_at(analysis.document, position),
         true <- inside_capture?(zipper) do
      {:/, _, [{local_func_name, _meta, _}, {:__block__, _, [arity]}]} = zipper.node
      function_name_length = local_func_name |> to_string() |> String.length()
      range = Ast.Range.fetch!(zipper.node, analysis.document)
      range = put_in(range.end.character, range.start.character + function_name_length)

      module =
        case fetch_module_for_function(analysis, position, local_func_name, arity) do
          {:ok, mod} -> mod
          _ -> current_module(analysis, position)
        end

      {:ok, {:call, module, local_func_name, arity}, range}
    else
      _ ->
        {:error, :not_found}
    end
  end

  defp inside_capture?(zipper) do
    case Zipper.up(zipper) do
      %Zipper{node: {:&, _, _}} -> true
      _ -> false
    end
  end
end
