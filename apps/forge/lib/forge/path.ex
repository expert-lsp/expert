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
    file_norm = normalize(file_path)
    parent_norm = normalize(possible_parent)

    case parent_norm do
      "" ->
        true

      "/" ->
        String.starts_with?(file_norm, "/")

      _ ->
        parent_prefix =
          if String.ends_with?(parent_norm, "/"), do: parent_norm, else: parent_norm <> "/"

        parent_exact = String.trim_trailing(parent_norm, "/")
        file_exact = String.trim_trailing(file_norm, "/")

        file_exact == parent_exact or String.starts_with?(file_norm, parent_prefix)
    end
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
end
