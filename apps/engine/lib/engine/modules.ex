defmodule Engine.Modules do
  @moduledoc """
  Utilities for dealing with modules on the remote control node
  """

  alias Engine.Module.Loader
  alias Future.Code.Typespec

  @typedoc "Module documentation record as defined by EEP-48"
  @type docs_v1 :: tuple()

  @typedoc "A type, spec, or callback definition"
  @type definition ::
          {name :: atom(), arity :: arity(), formatted :: String.t(), quoted :: Macro.t()}

  @cache_timeout Application.compile_env(:engine, :modules_cache_expiry, {10, :second})

  @doc """
  Ensure the given module is compiled, returning the BEAM object code if successful.
  """
  @spec ensure_beam(module()) ::
          {:ok, beam :: binary()} | {:error, reason}
        when reason:
               :embedded
               | :badfile
               | :nofile
               | :on_load_failure
               | :unavailable
               | :get_object_code_failed
  def ensure_beam(module) when is_atom(module) do
    with {:module, _} <- Code.ensure_compiled(module),
         {_module, beam, _filename} <- :code.get_object_code(module) do
      {:ok, beam}
    else
      :error -> {:error, :get_object_code_failed}
      {:error, error} -> {:error, error}
    end
  end

  def exunit_module?(module) when is_atom(module) do
    Loader.ensure_loaded?(module) and
      (function_exported?(module, :__ex_unit__, 1) or function_exported?(module, :__ex_unit__, 2))
  end

  def exunit_module?(_module), do: false

  def exports(module) when is_atom(module) do
    with {:module, ^module} <- Loader.ensure_loaded(module),
         true <- function_exported?(module, :__info__, 1) do
      {:ok,
       %{
         functions: module.__info__(:functions),
         macros: module.__info__(:macros)
       }}
    else
      _ -> :error
    end
  end

  @doc """
  Fetch the docs chunk from BEAM object code.
  """
  @spec fetch_docs(beam :: binary()) :: {:ok, docs_v1()} | :error
  @docs_chunk ~c"Docs"
  def fetch_docs(beam) when is_binary(beam) do
    case :beam_lib.chunks(beam, [@docs_chunk]) do
      {:ok, {_module, [{@docs_chunk, bin}]}} ->
        {:ok, :erlang.binary_to_term(bin)}

      _ ->
        :error
    end
  end

  @doc """
  Fetch the specs from BEAM object code.
  """
  @spec fetch_specs(beam :: binary()) :: {:ok, [definition()]} | :error
  def fetch_specs(beam) when is_binary(beam) do
    case Typespec.fetch_specs(beam) do
      {:ok, specs} ->
        defs =
          for {{name, arity}, defs} <- specs,
              def <- defs do
            quoted = Typespec.spec_to_quoted(name, def)
            formatted = format_definition(quoted)

            {name, arity, formatted, quoted}
          end

        {:ok, defs}

      _ ->
        :error
    end
  end

  @doc """
  Fetch the types from BEAM object code.
  """
  @spec fetch_types(beam :: binary()) :: {:ok, [definition()]} | :error
  def fetch_types(beam) when is_binary(beam) do
    case Typespec.fetch_types(beam) do
      {:ok, types} ->
        defs =
          for {kind, {name, _body, args} = type} <- types do
            arity = length(args)
            quoted_type = Typespec.type_to_quoted(type)
            quoted = {:@, [], [{kind, [], [quoted_type]}]}
            formatted = format_definition(quoted)

            {name, arity, formatted, quoted}
          end

        {:ok, defs}

      _ ->
        :error
    end
  end

  @doc """
  Fetch the specs from BEAM object code.
  """
  @spec fetch_callbacks(beam :: binary()) :: {:ok, [definition()]} | :error
  def fetch_callbacks(beam) when is_binary(beam) do
    case Typespec.fetch_callbacks(beam) do
      {:ok, callbacks} ->
        defs =
          for {{name, arity}, defs} <- callbacks,
              def <- defs do
            quoted = Typespec.spec_to_quoted(name, def)
            formatted = format_definition(quoted)

            {name, arity, formatted, quoted}
          end

        {:ok, defs}

      _ ->
        :error
    end
  end

  @doc """
  Get a list of a module's functions

  This function will attempt to load the given module using our module cache, and
  if it's found, will return a keyword list of function names and arities.
  """
  @spec fetch_functions(module()) :: {:ok, [{function(), arity()}]} | :error
  def fetch_functions(module) when is_atom(module) do
    with {:module, module} <- Loader.ensure_loaded(module) do
      cond do
        function_exported?(module, :__info__, 1) ->
          {:ok, module.__info__(:functions)}

        function_exported?(module, :module_info, 1) ->
          {:ok, module.module_info(:functions)}

        true ->
          :error
      end
    end
  end

  defp format_definition(quoted) do
    quoted
    |> Future.Code.quoted_to_algebra()
    |> Inspect.Algebra.format(60)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns all modules matching a prefix

  `with_prefix` returns all modules on the node on which it runs that start with the given prefix.
  It's worth noting that it will return _all modules_ regardless if they have been loaded or not.

  You can optionally pass a predicate MFA to further select which modules are returned, but
  it's important to understand that the predicate can only be a function reference to a function that
  exists on the `engine` node. I.e. you CANNOT pass anonymous functions to this module.

  Each module will be added as the first argument to the given list of args in the predicate,
  for example:

      iex> Modules.with_prefix("Gen", {Kernel, :macro_exported?, [:__using__, 1]})
      [GenEvent, GenServer]

  """
  def with_prefix(prefix_module, predicate_mfa \\ {Function, :identity, []})

  def with_prefix(prefix_module, mfa) when is_atom(prefix_module) do
    prefix_module
    |> to_string()
    |> with_prefix(mfa)
  end

  def with_prefix("Elixir." <> _ = prefix, mfa) do
    results =
      for {module_string, already_loaded?} <- all_modules(),
          String.starts_with?(module_string, prefix),
          module = Module.concat([module_string]),
          ensure_loaded?(module, already_loaded?),
          apply_predicate(module, mfa) do
        {module_string, module}
      end

    {module_strings, modules_with_prefix} = Enum.unzip(results)

    mark_loaded(module_strings)

    modules_with_prefix
  end

  def with_prefix(prefix, mfa) do
    with_prefix("Elixir." <> prefix, mfa)
  end

  defp apply_predicate(module_arg, {invoked_module, function, args}) do
    apply(invoked_module, function, [module_arg | args])
  end

  defp ensure_loaded?(_, true), do: true
  defp ensure_loaded?(module, _), do: Loader.ensure_loaded?(module)

  defp mark_loaded(modules) when is_list(modules) do
    newly_loaded = Map.new(modules, &{&1, true})
    {expires, all_loaded} = :persistent_term.get(__MODULE__)
    updated = Map.merge(all_loaded, newly_loaded)

    :persistent_term.put(__MODULE__, {expires, updated})
  end

  defp all_modules do
    case term() do
      {:ok, modules} ->
        modules

      :error ->
        {_expires, modules} = cache = rebuild_cache()
        :persistent_term.put(__MODULE__, cache)
        modules
    end
  end

  defp term do
    {expires_at, modules} = :persistent_term.get(__MODULE__, {nil, []})

    if expired?(expires_at) do
      :error
    else
      {:ok, modules}
    end
  end

  defp expired?(nil), do: true

  defp expired?(expires) do
    DateTime.after?(DateTime.utc_now(), expires)
  end

  defp rebuild_cache do
    {amount, unit} = @cache_timeout

    expires = DateTime.add(DateTime.utc_now(), amount, unit, Calendar.UTCOnlyTimeZoneDatabase)

    module_map =
      Map.new(:code.all_available(), fn {module_charlist, _path, already_loaded?} ->
        {to_string(module_charlist), already_loaded?}
      end)

    {expires, module_map}
  end
end
