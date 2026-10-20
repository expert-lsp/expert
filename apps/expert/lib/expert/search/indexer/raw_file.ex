defmodule Expert.Search.Indexer.RawFile do
  @moduledoc """
  File reads and stats for indexing.

  `File` functions are served by the single `:file_server` process, which
  serializes the many concurrent indexing workers. Raw operations run in the
  calling process instead.
  """

  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: :file.read_file(path, [:raw])

  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path) do
    case :file.read_file_info(path, [:raw, {:time, :universal}]) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, _} = error -> error
    end
  end
end
