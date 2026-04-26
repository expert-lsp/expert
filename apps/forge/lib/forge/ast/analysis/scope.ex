defmodule Forge.Ast.Analysis.Scope do
  alias Forge.Ast.Analysis.Alias
  alias Forge.Ast.Analysis.Import
  alias Forge.Ast.Analysis.Require
  alias Forge.Document.Position
  alias Forge.Document.Range

  defstruct [
    :id,
    :range,
    module: [],
    aliases: [],
    imports: [],
    requires: [],
    uses: []
  ]

  @type import_mfa :: {module(), atom(), non_neg_integer()}
  @type scope_position :: Position.t() | Position.line() | :end

  @type t :: %__MODULE__{
          id: any(),
          range: Range.t(),
          module: [atom()],
          aliases: [Alias.t()],
          imports: [import_mfa()]
        }

  def new(%__MODULE__{} = parent_scope, id, %Range{} = range, module \\ []) do
    uses =
      if module == parent_scope.module do
        # if we're still in the same module, we have the same uses
        parent_scope.uses
      else
        []
      end

    %__MODULE__{
      id: id,
      aliases: parent_scope.aliases,
      imports: parent_scope.imports,
      requires: parent_scope.requires,
      module: module,
      range: range,
      uses: uses
    }
  end

  def global(%Range{} = range) do
    %__MODULE__{id: :global, range: range}
  end

  @spec alias_map(t(), scope_position()) :: %{[module()] => t()}
  def alias_map(%__MODULE__{} = scope, position \\ :end) do
    scope.aliases
    # sorting by line ensures that aliases on later lines
    # override aliases on earlier lines
    |> Enum.sort_by(& &1.range.start.line)
    |> Enum.take_while(fn %Alias{range: alias_range} ->
      case position do
        %Position{} = pos ->
          pos.line >= alias_range.start.line

        line when is_integer(line) ->
          line >= alias_range.start.line

        :end ->
          true
      end
    end)
    |> Map.new(&{&1.as, &1})
  end

  def aliases(%__MODULE__{} = scope, position \\ :end) do
    scope.aliases
    |> Enum.sort_by(& &1.range.start.line)
    |> Enum.take_while(fn %Alias{range: alias_range} ->
      case position do
        %Position{} = pos -> pos.line >= alias_range.start.line
        line when is_integer(line) -> line >= alias_range.start.line
        :end -> true
      end
    end)
  end

  def requires(%__MODULE__{} = scope, position \\ :end) do
    scope.requires
    |> Enum.sort_by(& &1.range.start.line)
    |> Enum.take_while(fn %Require{range: require_range} ->
      case position do
        %Position{} = pos -> pos.line >= require_range.start.line
        line when is_integer(line) -> line >= require_range.start.line
        :end -> true
      end
    end)
  end

  def imports(%__MODULE__{} = scope, position \\ :end) do
    scope.imports
    |> Enum.sort_by(& &1.range.start.line)
    |> Enum.take_while(fn %Import{range: import_range} ->
      case position do
        %Position{} = pos -> pos.line >= import_range.start.line
        line when is_integer(line) -> line >= import_range.start.line
        :end -> true
      end
    end)
  end

  def fetch_alias_with_prefix(%__MODULE__{} = scope, prefix) do
    case Enum.find(scope.aliases, fn %Alias{} = alias -> alias.as == List.wrap(prefix) end) do
      %Alias{} = existing -> {:ok, existing}
      _ -> :error
    end
  end

  def empty?(%__MODULE__{id: :global}), do: false
  def empty?(%__MODULE__{aliases: [], imports: []}), do: true
  def empty?(%__MODULE__{}), do: false

  def end_line(%__MODULE__{} = scope, :end), do: scope.range.end.line
  def end_line(_, %Position{} = position), do: position.line
  def end_line(_, line) when is_integer(line), do: line
end
