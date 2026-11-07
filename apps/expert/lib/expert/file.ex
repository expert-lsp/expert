defmodule Expert.File do
  # Reading through the file server queues every caller on one process, which
  # the raw option skips where the runtime has it.
  if function_exported?(File, :read, 2) do
    def read(path), do: File.read(path, [:raw])
  else
    def read(path), do: File.read(path)
  end

  def stat(path) do
    case :file.read_file_info(path, [:raw, time: :universal]) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, _} = error -> error
    end
  end
end
