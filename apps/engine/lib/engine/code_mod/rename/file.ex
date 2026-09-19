defmodule Engine.CodeMod.Rename.File do
  @moduledoc """
  Builds file renames for module renames.

  A file rename is returned when the renamed module is the file's only
  top-level module and the source path follows an Elixir or Phoenix naming
  convention.

  ## Examples

  Regular and umbrella projects use the underscored module name:

      MyApp.Users -> MyApp.Accounts

      lib/my_app/users.ex
      #=> lib/my_app/accounts.ex

      apps/my_app/lib/my_app/users.ex
      #=> apps/my_app/lib/my_app/accounts.ex

  Namespace changes update the directory:

      MyApp.Users -> Billing.Accounts

      lib/my_app/users.ex
      #=> lib/billing/accounts.ex

  Phoenix `components`, `controllers`, and `live` directories are preserved:

      MyAppWeb.UserController -> MyAppWeb.AccountController

      lib/my_app_web/controllers/user_controller.ex
      #=> lib/my_app_web/controllers/account_controller.ex

  `nil` is returned for a custom source path, a nested module, or a file with
  multiple top-level modules.
  """
  alias Engine.CodeMod.Rename.Entry
  alias Engine.Search.Indexer
  alias Forge.Ast
  alias Forge.Document
  alias Forge.Formats
  alias Forge.Project

  @conventions [
    {:phoenix, "components"},
    {:phoenix, "controllers"},
    {:phoenix, "live"},
    :standard
  ]

  @doc """
  Returns the file rename for `entry`, if its source path follows a supported
  convention.

  Returns `nil` when the file should remain in place, or
  `{:error, {:file_already_exists, path}}` when the destination exists.
  """
  @spec maybe_rename(Document.t(), Entry.t(), String.t()) ::
          Document.Changes.RenameFile.t() | nil | {:error, term()}
  def maybe_rename(%Document{} = document, %Entry{} = entry, new_suffix) do
    if root_module?(entry, document) do
      rename_file(document, entry, new_suffix)
    end
  end

  defp root_module?(%Entry{} = entry, document) do
    with {:ok, entries} <-
           Indexer.Source.index_document(document, [Indexer.Extractors.Module]),
         [%Forge.Search.Indexer.Entry{} = root_module] <-
           Enum.filter(entries, &(&1.block_id == :root)) do
      root_module.subject == entry.subject and root_module.block_range == entry.block_range
    else
      _ -> false
    end
  end

  defp rename_file(document, %Entry{} = entry, new_suffix) do
    root_path = Project.root_path(Engine.get_project())
    relative_path = Path.relative_to(entry.path, root_path)
    extname = Path.extname(entry.path)

    with {:ok, prefix} <- fetch_conventional_prefix(relative_path),
         {:ok, convention} <- fetch_convention(entry, relative_path, prefix, extname),
         {:ok, new_name} <- fetch_new_name(document, entry, new_suffix) do
      suffix = conventional_suffix(new_name, convention)

      new_path =
        [root_path, prefix, "#{suffix}#{extname}"] |> Path.join() |> Forge.Path.normalize()

      new_uri = Document.Path.ensure_uri(new_path)

      cond do
        document.uri == new_uri -> nil
        File.exists?(new_path) -> {:error, {:file_already_exists, new_path}}
        true -> Document.Changes.RenameFile.new(document.uri, new_uri)
      end
    else
      _ -> nil
    end
  end

  defp fetch_convention(entry, relative_path, prefix, extname) do
    Enum.find_value(@conventions, :error, fn convention ->
      expected_path =
        Path.join([prefix, "#{conventional_suffix(entry.subject, convention)}#{extname}"])

      if relative_path == expected_path, do: {:ok, convention}
    end)
  end

  defp conventional_suffix(module, :standard) when is_atom(module) do
    module |> Formats.module() |> Macro.underscore()
  end

  defp conventional_suffix(module, :standard) when is_binary(module) do
    Macro.underscore(module)
  end

  defp conventional_suffix(module, {:phoenix, folder}) do
    module
    |> conventional_suffix(:standard)
    |> Path.split()
    |> case do
      [root, ^folder | rest] -> Path.join([root, folder | rest])
      [root | rest] -> Path.join([root, folder | rest])
    end
  end

  defp fetch_new_name(document, %Entry{} = entry, new_suffix) do
    text_edits = [Document.Edit.new(new_suffix, entry.edit_range)]

    with {:ok, edited_document} <-
           Document.apply_content_changes(document, document.version + 1, text_edits),
         {:ok, %{context: {:alias, alias}}} <-
           Ast.surround_context(edited_document, entry.edit_range.start) do
      {:ok, to_string(alias)}
    else
      _ -> :error
    end
  end

  defp fetch_conventional_prefix(path) do
    case Path.split(path) do
      ["apps", app_name, source | _] when source in ["lib", "test"] ->
        {:ok, Path.join(["apps", app_name, source])}

      [source | _] when source in ["lib", "test"] ->
        {:ok, source}

      _ ->
        :error
    end
  end
end
