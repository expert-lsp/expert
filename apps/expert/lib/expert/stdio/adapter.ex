defmodule Expert.Stdio.Adapter do
  @moduledoc """
  Carries the LSP protocol over `Expert.Stdio.User` rather than over an I/O device.
  """

  @behaviour GenLSP.Communication.Adapter

  alias Expert.Stdio.User

  @separator "\r\n\r\n"

  @impl true
  def init(_args) do
    :ok = User.claim()

    {:ok, %{}}
  end

  @impl true
  def listen(state) do
    :ok = User.subscribe()

    {:ok, state}
  end

  @impl true
  def write(body, _state), do: User.write(frame(body))

  @doc false
  @spec frame(iodata()) :: iodata()
  def frame(body) do
    length = body |> IO.iodata_length() |> Integer.to_string()
    ["Content-Length: ", length, @separator, body]
  end

  @impl true
  def read(state, buffered) do
    case take_packet(buffered) do
      {:ok, body, rest} ->
        {:ok, body, rest}

      :incomplete ->
        receive do
          {:lsp_stdin, bytes} -> read(state, buffered <> bytes)
          :lsp_stdin_eof -> :eof
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take_packet(buffered) do
    with [headers, rest] <- :binary.split(buffered, @separator),
         {:ok, length} <- content_length(headers) do
      case rest do
        <<body::binary-size(^length), remainder::binary>> -> {:ok, body, remainder}
        _too_short -> :incomplete
      end
    else
      [_unterminated] -> :incomplete
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_length(headers) do
    headers
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value({:error, :missing_content_length}, fn header ->
      with ["Content-Length", value] <- :binary.split(header, ":"),
           {length, ""} <- value |> String.trim() |> Integer.parse() do
        {:ok, length}
      else
        _ -> nil
      end
    end)
  end
end
