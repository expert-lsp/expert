defmodule Engine.CodeIntelligence.Declaration do
  alias ElixirSense.Core.Binding
  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Parser
  alias ElixirSense.Core.State
  alias ElixirSense.Core.State.{ModFunInfo, SpecInfo}
  alias ElixirSense.Core.SurroundContext
  alias ElixirSense.Providers.Location, as: SenseLocation
  alias Forge.Document
  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Document.Range

  require Introspection

  @spec declaration(Document.t(), Position.t()) ::
          {:ok, Location.t() | [Location.t()] | nil}
  def declaration(%Document{} = document, %Position{} = position) do
    source = Document.to_string(document)
    cursor = {position.line, position.character}

    locations =
      case Code.Fragment.surround_context(source, cursor) do
        :none ->
          []

        context ->
          metadata = Parser.parse_string(source, true, false, cursor)
          env = Metadata.get_cursor_env(metadata, cursor, {context.begin, context.end})

          context
          |> declarations(env, metadata)
          |> Enum.flat_map(&to_location(&1, document))
      end

    case Enum.uniq_by(locations, &{&1.uri, &1.range}) do
      [] -> {:ok, nil}
      [location] -> {:ok, location}
      locations -> {:ok, locations}
    end
  end

  defp declarations(context, %State.Env{} = env, metadata) do
    binding = Binding.from_env(env, metadata, context.begin)

    context.context
    |> SurroundContext.to_binding(env.module)
    |> declarations_for_binding(context, env, metadata, binding)
  end

  defp declarations_for_binding(nil, _context, _env, _metadata, _binding), do: []

  defp declarations_for_binding({:keyword, _}, _context, _env, _metadata, _binding), do: []

  defp declarations_for_binding(
         {:variable, variable, version},
         context,
         env,
         metadata,
         _binding
       ) do
    case Metadata.find_var(metadata, variable, version, context.begin) do
      nil -> declarations_for_function({nil, variable}, context, env, metadata)
      _variable -> []
    end
  end

  defp declarations_for_binding({:attribute, _}, _context, _env, _metadata, _binding),
    do: []

  defp declarations_for_binding(
         {{:variable, _, _} = receiver, function},
         context,
         env,
         metadata,
         binding
       ) do
    declarations_for_expanded_receiver(receiver, function, context, env, metadata, binding)
  end

  defp declarations_for_binding(
         {{:attribute, _} = receiver, function},
         context,
         env,
         metadata,
         binding
       ) do
    declarations_for_expanded_receiver(receiver, function, context, env, metadata, binding)
  end

  defp declarations_for_binding(
         {module, function},
         context,
         env,
         metadata,
         _binding
       ) do
    declarations_for_function({module, function}, context, env, metadata)
  end

  defp declarations_for_expanded_receiver(receiver, function, context, env, metadata, binding) do
    case Binding.expand(binding, receiver) do
      {:atom, module} ->
        declarations_for_function(
          {{:atom, module}, function},
          context,
          env,
          metadata
        )

      _other ->
        []
    end
  end

  defp declarations_for_function({module, function}, context, env, metadata) do
    module = binding_module(module)

    case Introspection.actual_mod_fun(
           {module, function},
           env,
           metadata.mods_funs_to_positions,
           metadata.types,
           context.begin,
           true
         ) do
      {_module, resolved_function, false, _kind} ->
        arity = call_arity(metadata, env.module, resolved_function, context.end)
        callback_declarations(env.module, resolved_function, arity, metadata, env)

      {resolved_module, resolved_function, true, :mod_fun} ->
        arity = call_arity(metadata, resolved_module, resolved_function, context.end)
        callback_declarations(resolved_module, resolved_function, arity, metadata, env)

      _other ->
        []
    end
  end

  defp binding_module({:atom, module}), do: module
  defp binding_module(_module), do: nil

  defp call_arity(metadata, module, function, {line, column}) do
    Metadata.get_call_arity(metadata, module, function, line, column) || :any
  end

  defp callback_declarations(nil, _function, _arity, _metadata, _env), do: []

  defp callback_declarations(module, function, arity, metadata, env) do
    declarations =
      metadata
      |> Metadata.get_module_behaviours(env, module)
      |> Kernel.++([module])
      |> Enum.uniq()
      |> Enum.flat_map(fn behaviour ->
        if Introspection.is_callback(behaviour, function, arity, metadata) do
          callback_location(behaviour, function, arity, metadata)
        else
          []
        end
      end)

    case declarations do
      [] -> overridable_declarations(module, function, arity, metadata)
      declarations -> declarations
    end
  end

  defp callback_location(module, function, arity, metadata) do
    case find_callback_spec(metadata.specs, module, function, arity) do
      %SpecInfo{} = spec ->
        [sense_location(nil, :callback, SenseLocation.info_to_range(spec))]

      nil ->
        case callback_source_location(module, function, arity) do
          %SenseLocation{} = location -> [location]
          nil -> []
        end
    end
  end

  defp find_callback_spec(specs, module, function, arity) do
    Enum.find_value(specs, fn
      {{^module, ^function, spec_arity}, %SpecInfo{kind: kind} = spec}
      when kind in [:callback, :macrocallback] ->
        if Introspection.matches_arity?(spec_arity, arity), do: spec

      _entry ->
        nil
    end)
  end

  defp callback_source_location(module, function, arity) do
    with source when is_binary(source) <- module_source(module),
         metadata = Parser.parse_file(source, false, false, nil),
         %SpecInfo{} = spec <- find_callback_spec(metadata.specs, module, function, arity) do
      sense_location(source, :callback, SenseLocation.info_to_range(spec))
    else
      _failure -> nil
    end
  end

  defp module_source(module) do
    with true <- Code.ensure_loaded?(module),
         source when not is_nil(source) <- module.module_info(:compile)[:source] do
      source
      |> to_string()
      |> resolve_source_path()
    else
      _failure -> nil
    end
  end

  defp resolve_source_path(path) do
    cond do
      File.regular?(path) ->
        path

      elixir_source = Application.get_env(:language_server, :elixir_src) ->
        case Regex.run(~r{/lib/.+\.ex$}, path) do
          [suffix] ->
            candidate = Path.join(elixir_source, String.trim_leading(suffix, "/"))
            if File.regular?(candidate), do: candidate

          _no_suffix ->
            nil
        end

      true ->
        nil
    end
  end

  defp overridable_declarations(module, function, arity, metadata) do
    metadata.mods_funs_to_positions
    |> Enum.flat_map(fn
      {{^module, ^function, defined_arity}, %ModFunInfo{overridable: {true, origin}}}
      when Introspection.matches_arity?(defined_arity, arity) ->
        case SenseLocation.find_mod_fun_source(origin, :__using__, :any) do
          %SenseLocation{} = location -> [location]
          nil -> []
        end

      _entry ->
        []
    end)
  end

  defp sense_location(file, type, {{line, column}, {end_line, end_column}}) do
    %SenseLocation{
      type: type,
      file: file,
      line: line,
      column: column,
      end_line: end_line,
      end_column: end_column
    }
  end

  defp to_location(%SenseLocation{file: nil} = location, %Document{} = document) do
    [Location.new(to_range(location, document), document)]
  end

  defp to_location(%SenseLocation{file: file} = location, _document) when is_binary(file) do
    uri = Document.Path.ensure_uri(file)

    case Document.Store.open_temporary(uri) do
      {:ok, document} -> [Location.new(to_range(location, document), document)]
      _error -> []
    end
  end

  defp to_range(%SenseLocation{} = location, %Document{} = document) do
    Range.new(
      Position.new(document, location.line, location.column),
      Position.new(document, location.end_line, location.end_column)
    )
  end
end
