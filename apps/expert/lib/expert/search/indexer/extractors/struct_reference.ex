defmodule Expert.Search.Indexer.Extractors.StructReference do
  alias Expert.Search.Indexer.Analyzer
  alias Expert.Search.Indexer.Source.Reducer
  alias Forge.Ast
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Subject

  require Logger

  @struct_fn_names [:struct, :struct!]

  # Handles usages via an alias, e.g. x = %MyStruct{...} or %__MODULE__{...}
  def extract(
        {:%, _, [struct_alias, {:%{}, _, _struct_args}]} = reference,
        %Reducer{} = reducer
      ) do
    case expand_alias(struct_alias, reducer) do
      {:ok, struct_module} ->
        {:ok, entry(reducer, struct_module, reference)}

      _ ->
        :ignored
    end
  end

  # Call to Kernel.struct with a fully qualified module e.g. Kernel.struct(MyStruct, ...)
  def extract(
        {{:., _, [kernel_alias, struct_fn_name]}, _, [struct_alias | _]} = reference,
        %Reducer{} = reducer
      )
      when struct_fn_name in @struct_fn_names do
    with {:ok, Kernel} <- expand_alias(kernel_alias, reducer),
         {:ok, struct_module} <- expand_alias(struct_alias, reducer) do
      {:ok, entry(reducer, struct_module, reference)}
    else
      _ ->
        :ignored
    end
  end

  # handles calls to Kernel.struct e.g. struct(MyModule) or struct(MyModule, foo: 3)
  def extract({struct_fn_name, _, [struct_alias | _] = args} = reference, %Reducer{} = reducer)
      when struct_fn_name in @struct_fn_names do
    reducer_position = Reducer.position(reducer)
    imports = Analyzer.imports_at(reducer.analysis, reducer_position)
    arity = length(args)

    with true <- Enum.member?(imports, {Kernel, struct_fn_name, arity}),
         {:ok, struct_module} <- expand_alias(struct_alias, reducer) do
      {:ok, entry(reducer, struct_module, reference)}
    else
      _ ->
        :ignored
    end
  end

  def extract(_, _) do
    :ignored
  end

  defp entry(%Reducer{} = reducer, struct_module, reference) do
    document = reducer.analysis.document
    block = Reducer.current_block(reducer)
    subject = Subject.module(struct_module)

    Entry.reference(
      document.path,
      block,
      subject,
      :struct,
      Ast.Range.fetch!(reference, document),
      Reducer.application(reducer, struct_module)
    )
  end

  defp expand_alias({:__aliases__, _, struct_alias}, %Reducer{} = reducer) do
    Analyzer.expand_alias(struct_alias, reducer.analysis, Reducer.position(reducer))
  end

  defp expand_alias({:__MODULE__, _, _}, %Reducer{} = reducer) do
    Analyzer.current_module(reducer.analysis, Reducer.position(reducer))
  end

  # We ignore struct references with variable names, e.g. %_{}, %var_name{}
  defp expand_alias({atom, _, ctx}, _reducer) when is_atom(atom) and is_atom(ctx), do: :ignored

  defp expand_alias(alias, %Reducer{} = reducer) do
    {line, column} = reducer.position

    Logger.error(
      "Could not expand alias: #{inspect(alias)} at #{reducer.analysis.document.path} #{line}:#{column}"
    )

    :error
  end
end
