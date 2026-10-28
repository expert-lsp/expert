defmodule Forge.Path do
  @moduledoc """
  Path utilities with cross-platform compatibility fixes.

  This module provides path handling functions that work consistently
  across Windows, macOS, and Linux, particularly for glob patterns
  which have platform-specific quirks.
  """

  def glob(path_segments, opts \\ []) when is_list(path_segments) and is_list(opts) do
    case Keyword.get(opts, :exclude) do
      nil ->
        do_glob(path_segments)

      [] ->
        do_glob(path_segments)

      excluded when is_list(excluded) ->
        glob_with_excluded(path_segments, excluded)
    end
  end

  defp do_glob(path_segments) do
    path_segments
    |> Path.join()
    |> normalize()
    |> Path.wildcard()
    |> native_paths()
  end

  defp glob_with_excluded(path_segments, excluded) do
    root = path_segments |> hd() |> normalize()

    norm_excluded =
      excluded
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn p ->
        norm = normalize(p)

        expanded =
          if Path.type(norm) == :relative and Path.type(root) == :absolute do
            Path.expand(norm, root)
          else
            norm
          end

        String.trim_trailing(expanded, "/")
      end)

    exact_set = MapSet.new(norm_excluded)
    prefix_list = Enum.map(norm_excluded, &(&1 <> "/"))

    pattern =
      path_segments
      |> Path.join()
      |> normalize()
      |> String.to_charlist()

    Process.put(:forge_wildcard_excluded, {exact_set, prefix_list})

    try do
      pattern
      |> :filelib.wildcard(Forge.Path.Wildcard)
      |> Enum.map(&:unicode.characters_to_binary/1)
      |> native_paths()
    after
      Process.delete(:forge_wildcard_excluded)
    end
  end

  def normalize(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> normalize_drive_letter()
  end

  defp normalize_drive_letter(<<drive, ":", rest::binary>>) when drive in ?A..?Z do
    <<drive + 32, ":", rest::binary>>
  end

  defp normalize_drive_letter(path), do: path

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

defmodule Forge.Path.Wildcard do
  @moduledoc false

  def read_link_info(file), do: :file.read_link_info(file)
  def read_file_info(file), do: :file.read_file_info(file)

  def list_dir(dir) do
    str_dir =
      dir
      |> :unicode.characters_to_binary()
      |> Forge.Path.normalize()
      |> String.trim_trailing("/")

    {exact_set, prefix_list} = Process.get(:forge_wildcard_excluded, {MapSet.new(), []})

    if MapSet.member?(exact_set, str_dir) or String.starts_with?(str_dir, prefix_list) do
      {:error, :enoent}
    else
      case :file.list_dir(dir) do
        {:ok, files} ->
          filtered =
            Enum.filter(files, fn file ->
              file != ~c"" and hd(file) != ?. and
                not (
                  entry_str = :unicode.characters_to_binary(file)
                  entry_path = str_dir <> "/" <> entry_str

                  MapSet.member?(exact_set, entry_path) or
                    String.starts_with?(entry_path, prefix_list)
                )
            end)

          {:ok, filtered}

        other ->
          other
      end
    end
  end
end
