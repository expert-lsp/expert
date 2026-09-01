defmodule Forge.InternetTest do
  use ExUnit.Case, async: false
  use Patch

  alias Forge.Internet

  test "returns true when the OS resolver finds hex.pm within five seconds" do
    patch(:inet, :gethostbyname, fn host, family, timeout ->
      assert host == ~c"hex.pm"
      assert family == :inet
      assert timeout == 5_000

      {:ok, :hostent}
    end)

    assert Internet.connected_to_internet?()
  end

  test "returns false when OS resolution fails" do
    patch(:inet, :gethostbyname, fn host, family, timeout ->
      assert host == ~c"hex.pm"
      assert family == :inet
      assert timeout == 5_000

      {:error, :timeout}
    end)

    refute Internet.connected_to_internet?()
  end
end
