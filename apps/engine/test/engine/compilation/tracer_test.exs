defmodule Engine.Compilation.TracerTest do
  use ExUnit.Case, async: false
  use Patch

  import Forge.EngineApi.Messages

  alias Engine.Compilation.Tracer

  defmodule Fixture do
    defstruct [:field]

    def visible(argument), do: argument
    defmacro generated, do: :ok
  end

  setup do
    test_pid = self()

    patch(Engine, :broadcast, fn message ->
      send(test_pid, message)
      :ok
    end)

    :ok
  end

  test "broadcasts metadata for a compiled module" do
    env = %{__ENV__ | file: "fixture.ex", module: Fixture, lexical_tracker: self()}

    Tracer.document_compile(fn ->
      assert :ok = Tracer.trace({:on_module, <<>>, "fixture.ex"}, env)
    end)

    assert_receive module_updated(
                     file: "fixture.ex",
                     functions: functions,
                     macros: macros,
                     name: Fixture,
                     struct: struct
                   )

    assert {:visible, 1} in functions
    assert {:generated, 0} in macros
    assert %{field: :field, required?: false} in struct
  end

  test "returns a document compile's imported calls with their positions" do
    env = %{__ENV__ | file: "fixture.ex", module: Fixture, lexical_tracker: self()}

    assert {:ok, [{Fixture, imported_calls}]} =
             Tracer.document_compile(fn ->
               assert :ok =
                        Tracer.trace(
                          {:imported_function, [line: 3, column: 5], Enum, :map, 2},
                          env
                        )

               assert :ok =
                        Tracer.trace({:imported_macro, [line: 4, column: 7], Kernel, :if, 2}, env)

               assert :ok = Tracer.trace({:imported_function, [line: 5], Enum, :sum, 1}, env)
               assert :ok = Tracer.trace({:on_module, <<>>, "fixture.ex"}, env)
               assert :ok = Tracer.trace(:stop, %{env | module: nil})
               :ok
             end)

    assert Enum.sort(imported_calls) == [
             {3, 5, "Elixir.Enum", "map", 2},
             {4, 7, "Elixir.Kernel", "if", 2}
           ]
  end

  test "drops the imported calls of a module the file never defined" do
    env = %{__ENV__ | file: "fixture.ex", module: Fixture, lexical_tracker: self()}

    assert {:error, []} =
             Tracer.document_compile(fn ->
               assert :ok =
                        Tracer.trace(
                          {:imported_function, [line: 3, column: 5], Enum, :map, 2},
                          env
                        )

               assert :ok = Tracer.trace(:stop, %{env | module: nil})
               :error
             end)

    assert {:ok, [{Fixture, []}]} =
             Tracer.document_compile(fn ->
               assert :ok = Tracer.trace({:on_module, <<>>, "fixture.ex"}, env)
               assert :ok = Tracer.trace(:stop, %{env | module: nil})
               :ok
             end)
  end

  @tag :tmp_dir
  test "writes a project build's imported calls next to its beams", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule TracerTest.MixProject do
      use Mix.Project
      def project, do: [app: :tracer_test, version: "0.1.0"]
    end
    """)

    compiler_options = Code.compiler_options()
    on_exit(fn -> Code.compiler_options(compiler_options) end)
    Code.compiler_options(tracers: [Tracer], parser_options: [columns: true])

    compile_path =
      Mix.Project.in_project(
        :tracer_test,
        tmp_dir,
        [build_path: Path.join(tmp_dir, "_build")],
        fn _ ->
          File.mkdir_p!(Mix.Project.compile_path())
          Code.compile_string(user_source(TracerTest.Build), "traced.ex")
          Mix.Project.compile_path()
        end
      )

    assert {"traced.ex", calls} =
             compile_path
             |> Path.join("Elixir.TracerTest.Build.User.imported_calls")
             |> File.read!()
             |> :erlang.binary_to_term()

    assert {14, 5, "Elixir.TracerTest.Build.Helpers", "helper", 1} in calls
    assert {15, 5, "Elixir.TracerTest.Build.Helpers", "helper_macro", 1} in calls
  end

  @tag :tmp_dir
  test "compiles in an umbrella project without writing files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule TracerTest.UmbrellaProject do
      use Mix.Project
      def project, do: [apps_path: "apps"]
    end
    """)

    compiler_options = Code.compiler_options()
    on_exit(fn -> Code.compiler_options(compiler_options) end)
    Code.compiler_options(tracers: [Tracer], parser_options: [columns: true])

    Mix.Project.in_project(:tracer_umbrella, tmp_dir, fn _ ->
      Code.compile_string(user_source(TracerTest.Umbrella), "traced.ex")
    end)

    assert File.ls!(tmp_dir) == ["mix.exs"]
  end

  test "returns a document compile's imported calls without writing files" do
    compiler_options = Code.compiler_options()
    on_exit(fn -> Code.compiler_options(compiler_options) end)
    Code.compiler_options(tracers: [Tracer], parser_options: [columns: true])

    {_compiled, modules} =
      Tracer.document_compile(fn ->
        Code.compile_string(user_source(TracerTest.Document), "traced.ex")
      end)

    assert {TracerTest.Document.User, calls} = List.keyfind(modules, TracerTest.Document.User, 0)
    assert {14, 5, "Elixir.TracerTest.Document.Helpers", "helper", 1} in calls
    assert {15, 5, "Elixir.TracerTest.Document.Helpers", "helper_macro", 1} in calls
  end

  @tag :tmp_dir
  test "removes the imported calls of modules that no longer have a beam", %{tmp_dir: tmp_dir} do
    ebin = Path.join(tmp_dir, "lib/app/ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "Elixir.Kept.beam"), "")
    File.write!(Path.join(ebin, "Elixir.Kept.imported_calls"), "")
    File.write!(Path.join(ebin, "Elixir.Gone.imported_calls"), "")

    assert :ok = Tracer.prune_imported_calls(tmp_dir)

    assert Enum.sort(File.ls!(ebin)) == ["Elixir.Kept.beam", "Elixir.Kept.imported_calls"]
  end

  defp user_source(namespace) do
    namespace = inspect(namespace)

    """
    defmodule #{namespace}.Helpers do
      def helper(value), do: value
      defmacro helper_macro(value), do: value
    end

    defmodule #{namespace}.Using do
      defmacro __using__(_), do: quote(do: import(#{namespace}.Helpers))
    end

    defmodule #{namespace}.User do
      use #{namespace}.Using

      def run(value) do
        helper(value)
        helper_macro(value)
      end
    end
    """
  end
end
