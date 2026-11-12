defmodule Expert.CodeIntelligence.Completion.LocalsWithoutParens do
  @moduledoc """
  The calls a project's formatter writes without parentheses, read from its
  `.formatter.exs` and the formatter exports of its `import_deps`.

  The files are parsed, not evaluated, so only literal options are read.
  """

  alias Forge.Project

  @type t :: [{atom(), arity() | :*}]

  @spec for_project(Project.t()) :: t()
  def for_project(%Project{} = project) do
    root = Project.project_path(project)
    options = read(Path.join(root, ".formatter.exs"))

    exported =
      for dep <- List.wrap(options[:import_deps]),
          is_atom(dep),
          dep_options = read(Path.join([root, "deps", Atom.to_string(dep), ".formatter.exs"])),
          export = dep_options[:export],
          Keyword.keyword?(export),
          local <- List.wrap(export[:locals_without_parens]),
          do: local

    List.wrap(options[:locals_without_parens]) ++ exported
  end

  @spec without_parens?(t(), String.t(), arity()) :: boolean()
  def without_parens?(locals_without_parens, name, arity) do
    arity > 0 and
      Enum.any?(locals_without_parens, fn
        {local, local_arity} when local_arity in [:*, arity] -> Atom.to_string(local) == name
        _ -> false
      end)
  end

  defp read(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(contents),
         true <- Macro.quoted_literal?(quoted),
         {options, _binding} when is_list(options) <- Code.eval_quoted(quoted),
         true <- Keyword.keyword?(options) do
      options
    else
      _ -> []
    end
  end
end
