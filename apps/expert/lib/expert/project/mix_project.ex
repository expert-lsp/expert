defmodule Expert.Project.MixProject do
  @moduledoc false

  alias Forge.Project

  def configuration(%Project{kind: :mix} = project), do: run(project, [])
  def runtime_versions(%Project{} = project), do: run(project, ["--runtime-only"])

  defp run(project, args) do
    script = Path.join(:code.priv_dir(:expert), "read_mix_configuration.exs")

    case Expert.Port.open_elixir(project, args: [script | args]) do
      port when is_port(port) -> read_result(port, [])
      error -> error
    end
  end

  defp read_result(port, output) do
    receive do
      {^port, {:data, data}} ->
        read_result(port, [data | output])

      {^port, {:exit_status, status}} ->
        output = output |> Enum.reverse() |> IO.iodata_to_binary()
        decode_result(output, status)
    end
  end

  defp decode_result(output, 0) do
    encoded = output |> String.trim() |> String.split("\n") |> List.last()

    with {:ok, binary} <- Base.decode64(encoded) do
      :erlang.binary_to_term(binary)
    end
  end

  defp decode_result(output, status), do: {:error, {:mix_configuration, status, output}}
end
