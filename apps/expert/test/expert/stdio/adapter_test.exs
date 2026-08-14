defmodule Expert.Stdio.AdapterTest do
  use ExUnit.Case, async: true

  alias Expert.Stdio.Adapter

  @body ~s({"jsonrpc":"2.0","id":1})

  defp packet(body), do: "Content-Length: #{byte_size(body)}\r\n\r\n" <> body

  describe "read/2" do
    test "returns a complete packet already sitting in the buffer" do
      assert {:ok, @body, ""} = Adapter.read(%{}, packet(@body))
    end

    test "keeps bytes belonging to the next packet" do
      assert {:ok, @body, "Content-Length: 2\r\n\r\n{}"} =
               Adapter.read(%{}, packet(@body) <> packet("{}"))
    end

    test "waits for the rest of a split packet" do
      <<head::binary-size(20), tail::binary>> = packet(@body)
      send(self(), {:lsp_stdin, tail})

      assert {:ok, @body, ""} = Adapter.read(%{}, head)
    end

    test "reassembles a packet delivered one byte at a time" do
      for <<byte <- packet(@body)>>, do: send(self(), {:lsp_stdin, <<byte>>})

      assert {:ok, @body, ""} = Adapter.read(%{}, "")
    end

    test "ignores headers other than Content-Length" do
      framed = "Content-Type: application/vscode-jsonrpc\r\nContent-Length: 2\r\n\r\n{}"

      assert {:ok, "{}", ""} = Adapter.read(%{}, framed)
    end

    test "reports a framed message with no Content-Length" do
      assert {:error, :missing_content_length} = Adapter.read(%{}, "Content-Type: x\r\n\r\n{}")
    end

    test "returns :eof when stdin closes" do
      send(self(), :lsp_stdin_eof)

      assert :eof = Adapter.read(%{}, "")
    end
  end

  describe "frame/1" do
    test "counts bytes rather than graphemes" do
      body = ~s({"a":"é"})

      assert IO.iodata_to_binary(Adapter.frame(body)) ==
               "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    end

    test "round-trips through read/2" do
      assert {:ok, @body, ""} =
               Adapter.read(%{}, IO.iodata_to_binary(Adapter.frame(@body)))
    end
  end
end
