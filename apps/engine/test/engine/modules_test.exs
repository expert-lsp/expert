defmodule Engine.ModulesTest do
  use ExUnit.Case
  use Forge.Test.EventualAssertions

  alias Engine.Modules

  describe "beam_metadata/1" do
    test "returns generated definitions and exports from compiler output" do
      # Arrange
      module = Module.concat(__MODULE__, "Generated#{System.unique_integer([:positive])}")

      compiler_options = Code.compiler_options()

      [{^module, beam}] =
        try do
          Code.compiler_options(debug_info: true)

          Code.compile_string("""
          defmodule #{inspect(module)} do
            use GenServer
            def init(value), do: {:ok, value}
          end
          """)
        after
          Code.compiler_options(compiler_options)
        end

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

      # Act
      result = Modules.beam_metadata(beam)

      # Assert
      assert {:ok, ^module, exports, {:ok, %{module: ^module, definitions: definitions}}} = result
      assert {:child_spec, 1} in exports
      assert Enum.any?(definitions, &match?({{:child_spec, 1}, :def, _, _}, &1))
    end

    test "malformed object code is not a successful metadata result" do
      # Arrange
      beam = "not a BEAM file"
      # Act
      result = Modules.beam_metadata(beam)
      # Assert
      assert result == :error
    end
  end

  describe "simple prefixes" do
    test "specifying a prefix with a string" do
      found = Modules.with_prefix("En")

      for module <- found,
          string = module |> Module.split() |> Enum.join(".") do
        assert String.starts_with?(string, "En")
      end
    end

    test "specifying a prefix with a module" do
      found = Modules.with_prefix(Enum)

      for module <- found,
          string = module |> Module.split() |> Enum.join(".") do
        assert String.starts_with?(string, "Enum")
      end
    end

    test "new modules are added after expiry" do
      assert [] = Modules.with_prefix(DoesntExistYet)
      Module.create(DoesntExistYet, quote(do: nil), file: "foo.ex")
      assert_eventually [DoesntExistYet] = Modules.with_prefix(DoesntExistYet)
    end

    test "finds unloaded modules" do
      modules = "GenEvent" |> Modules.with_prefix() |> Enum.map(&to_string/1)
      assert "Elixir.GenEvent" in modules
      assert "Elixir.GenEvent.Stream" in modules

      # ensure it loads the module
      assert "GenEvent" |> List.wrap() |> Module.concat() |> Code.ensure_loaded?()
    end

    test "not finding anything" do
      assert [] = Modules.with_prefix("ExpertIsTheBest")
    end
  end

  describe "using predicate descriptors" do
    test "it places the module as the first argument" do
      assert [GenEvent] =
               Modules.with_prefix("GenEvent", {Kernel, :macro_exported?, [:__using__, 1]})
    end
  end

  describe "exports/1" do
    test "returns Elixir functions and macros" do
      assert {:ok, exports} = Modules.exports(Kernel)
      assert {:is_map, 1} in exports.functions
      assert {:def, 2} in exports.macros
    end

    test "returns an error for an unavailable module" do
      assert :error = Modules.exports(DoesNotExist)
    end
  end
end
