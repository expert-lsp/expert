defmodule Forge.Path do
  @moduledoc """
  Path utilities with cross-platform compatibility fixes.

  This module provides path handling functions that work consistently
  across Windows, macOS, and Linux, particularly for glob patterns
  which have platform-specific quirks.
  """

  def glob(path_segments) when is_list(path_segments) do
    path_segments
    |> Path.join()
    |> normalize()
    |> Path.wildcard()
    |> native_paths()
  end

  def normalize(path) when is_binary(path) do
    String.replace(path, "\\", "/")
  end

  def native(path) when is_binary(path) do
    :filename.nativename(path)
  end

  @doc """
  Checks if `file_path` is contained within `possible_parent`.

  ## Examples

      iex> Forge.Path.contains?("/home/user/project/lib/foo.ex", "/home/user/project")
      true

      iex> Forge.Path.contains?("/home/user/project", "/home/user/project")
      true

      iex> Forge.Path.contains?("/home/user/project_v2/lib/foo.ex", "/home/user/project")
      false

  """
  def contains?(file_path, possible_parent)
      when is_binary(file_path) and is_binary(possible_parent) do
    file_parts = file_path |> normalize() |> Path.split()
    parent_parts = possible_parent |> normalize() |> Path.split()

    List.starts_with?(file_parts, parent_parts)
  end

  def normalize_paths(paths) when is_list(paths) do
    Enum.map(paths, &normalize/1)
  end

  def native_paths(paths) when is_list(paths) do
    Enum.map(paths, &native/1)
  end

  @doc """
  Checks if the `parent_path` is a parent directory of the `child_path`.

  ## Examples

      iex> Forge.Path.parent_path?("/home/user/docs/file.txt", "/home/user")
      true

      iex> Forge.Path.parent_path?("/home/user/docs/file.txt", "/home/admin")
      false

      iex> Forge.Path.parent_path?("/home/user/docs", "/home/user/docs")
      true

      iex> Forge.Path.parent_path?("/home/user/docs", "/home/user/docs/subdir")
      false

      iex> Forge.Path.parent_path?("/home/user/docs_v2/file.txt", "/home/user/docs")
      false
  """
  def parent_path?(child_path, parent_path) when byte_size(child_path) < byte_size(parent_path) do
    false
  end

  def parent_path?(child_path, parent_path) do
    child_parts = child_path |> Path.expand() |> Path.split()
    parent_parts = parent_path |> Path.expand() |> Path.split()

    List.starts_with?(child_parts, parent_parts)
  end

  @spec expert_cache_dir() :: String.t()
  def expert_cache_dir do
    :user_cache
    |> :filename.basedir("expert")
    |> to_string()
  end

  @doc """
  Checks if `path` is a template file (such as generator templates under
  `priv/templates`, `installer/templates`, `rel/templates`, or files with `.eex` in their name).

  ## Examples

      iex> Forge.Path.template_path?("/app/priv/templates/phx.gen.auth/settings_live.ex")
      true

      iex> Forge.Path.template_path?("installer/templates/phx_new/config.exs")
      true

      iex> Forge.Path.template_path?("rel/templates/env.sh.eex")
      true

      iex> Forge.Path.template_path?("/app/lib/my_app/templates/email.ex")
      false

      iex> Forge.Path.template_path?("/app/priv/repo/migrations/20260101_create_users.exs")
      false

      iex> Forge.Path.template_path?("/app/lib/my_app/user.ex")
      false

  """
  def template_path?(path) when is_binary(path) do
    parts = path |> normalize() |> Path.split()
    filename = Path.basename(path)

    template_dir?(parts) or
      String.contains?(filename, ".eex.") or
      String.ends_with?(filename, ".eex")
  end

  def template_path?(_), do: false

  defp template_dir?(parts) do
    case Enum.split_while(parts, &(&1 not in ["priv", "installer", "rel"])) do
      {_, []} ->
        false

      {_, [_prefix | rest]} ->
        "templates" in rest
    end
  end
end
