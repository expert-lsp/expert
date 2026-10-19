defmodule Forge.Ast.Module do
  @moduledoc """
  Module utilities
  """

  @doc """
  Formats a module name as a string.
  """
  @spec name(module() | Macro.t() | String.t()) :: String.t()
  def name([{:__MODULE__, _, _} | rest]) do
    [__MODULE__ | rest]
    |> Module.concat()
    |> name()
  end

  def name(module_name) when is_list(module_name) do
    module_name
    |> Module.concat()
    |> name()
  end

  def name(module_name) when is_binary(module_name) do
    module_name
  end

  # Module names made of plain segments, nearly all of them, print as they
  # are without the inspect machinery; `inspect/1` prints the rest, among
  # them names whose first segment is `Elixir`, which it keeps the prefix of.
  def name(module_name) when is_atom(module_name) do
    case Atom.to_string(module_name) do
      "Elixir." <> <<first, _::binary>> = string when first in ?A..?Z ->
        name = binary_part(string, 7, byte_size(string) - 7)

        if plain_segments?(name) and name != "Elixir" and not String.starts_with?(name, "Elixir."),
          do: name,
          else: inspect(module_name)

      _ ->
        inspect(module_name)
    end
  end

  defp plain_segments?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_,
       do: plain_segments?(rest)

  defp plain_segments?(<<?., first, rest::binary>>) when first in ?A..?Z,
    do: plain_segments?(rest)

  defp plain_segments?(<<>>), do: true
  defp plain_segments?(_rest), do: false

  @doc """
  local module name is the last part of a module name

  ## Examples:
      iex> local_name('Forge.Ast.Module')
      "Module"
  """
  def local_name(entity) when is_list(entity) do
    entity
    |> to_string()
    |> local_name()
  end

  def local_name(entity) when is_binary(entity) do
    entity
    |> String.split(".")
    |> List.last()
  end

  @doc """
  Splits a module into is parts, but handles erlang modules

  Module.split will explode violently when called on an erlang module. This
  implementation will tell you which kind of module it has split, and return the
  pieces. You can also use the options to determine if the pieces are returned as
  strings or atoms

  Options:
    `as` :atoms or :binaries. Default is :binary. Determines what type the elements
    of the returned list are.

  Returns:
    A tuple where the first element is either `:elixir` or `:erlang`, which tells you
    the kind of module that has been split. The second element is a list of the
    module's components. Note: Erlang modules will only ever have a single component.
  """
  @type split_opt :: {:as, :binaries | :atoms}
  @type split_opts :: [split_opt()]
  @type split_return :: {:elixir | :erlang, [String.t()] | [atom()]}

  @spec safe_split(module()) :: split_return()
  @spec safe_split(module(), split_opts()) :: split_return()
  def safe_split(module, opts \\ [])

  def safe_split(module, opts) when is_atom(module) do
    string_name = Atom.to_string(module)

    do_safe_split(string_name, opts)
  end

  defp do_safe_split(string_name, opts \\ []) do
    {type, split_module} =
      case String.split(string_name, ".") do
        ["Elixir" | rest] ->
          {:elixir, rest}

        [_erlang_module] = module ->
          {:erlang, module}
      end

    split_module =
      case Keyword.get(opts, :as, :binaries) do
        :binaries ->
          split_module

        :atoms ->
          Enum.map(split_module, &String.to_atom/1)
      end

    {type, split_module}
  end

  @spec to_atom(module() | String.t()) :: module()
  def to_atom(module) when is_atom(module) do
    module
  end

  def to_atom(":" <> module_string) do
    String.to_existing_atom(module_string)
  end

  def to_atom(module_string) when is_binary(module_string) do
    case do_safe_split("Elixir." <> module_string) do
      {:erlang, [module]} -> String.to_existing_atom(module)
      {:elixir, parts} -> Module.concat(parts)
    end
  end
end
