defmodule Expert.ToolchainTest do
  use ExUnit.Case, async: false

  import Forge.Test.Fixtures

  alias Expert.Toolchain
  alias Forge.Search.Indexer.Entry

  setup do
    {:ok, project: project()}
  end

  test "lists Elixir and Erlang modules by name prefix", %{project: project} do
    assert "GenServer" in Toolchain.modules_with_prefix(project, "GenServ")
    assert ":lists" in Toolchain.modules_with_prefix(project, ":lis")
    refute "Enum" in Toolchain.modules_with_prefix(project, "GenServ")
  end

  test "reads a module's BEAM and exports", %{project: project} do
    assert {:ok, %{application: "elixir", exports: exports}} =
             Toolchain.module(project, "GenServer")

    assert {"behaviour_info", 1} in exports
    assert :error = Toolchain.module(project, "NotAToolchainModule")
  end

  test "reads a module's definitions with their argument names", %{project: project} do
    assert %Entry{metadata: %{arguments: ["enumerable", "fun"]}} =
             project |> Toolchain.definitions("Enum") |> Enum.find(&(&1.subject == "Enum.map/2"))
  end
end
