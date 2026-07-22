defmodule Engine.Build.Document.Compilers.QuotedTest do
  use ExUnit.Case, async: false

  import Forge.Test.CodeSigil

  alias Engine.Build.Document.Compilers.Quoted
  alias Forge.Document
  alias Forge.Project

  @compile {:no_warn_undefined, CurrentMixProject}
  @compile {:no_warn_undefined, TransactionHelper}

  def trace(_event, _env), do: :ok

  setup do
    start_supervised!({Task.Supervisor, name: Engine.TaskSupervisor})
    :ok
  end

  defp parse!(code) do
    Code.string_to_quoted!(code, columns: true, token_metadata: true)
  end

  defp project_version, do: CurrentMixProject.project()[:version]
  defp transaction_value, do: TransactionHelper.value()

  defp current_project(tmp_dir) do
    path = Path.join(tmp_dir, "mix.exs")
    env = Mix.env()
    target = Mix.target()
    compiler_options = Code.compiler_options()

    source = """
    defmodule TransactionHelper do
      def value, do: :original
    end

    defmodule CurrentMixProject do
      use Mix.Project
      def project, do: [app: :current_mix_project, version: "0.1.0"]
    end
    """

    File.write!(path, source)
    modules = Code.compile_file(path)

    project =
      tmp_dir
      |> Document.Path.to_uri()
      |> Project.new()
      |> Project.set_project_module(CurrentMixProject)

    Engine.Mix.accept_project(project, modules)

    on_exit(fn ->
      Code.compiler_options(compiler_options)
      Mix.env(env)
      Mix.target(target)
      Engine.Mix.clear_accepted_project()

      if Mix.Project.get() == CurrentMixProject do
        Mix.Project.pop()
      end

      for module <- [
            CurrentMixProject,
            TransactionHelper,
            ReplacementMixProject,
            Child.MixProject
          ] do
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end
    end)

    {project, path}
  end

  defp unaccepted_project(tmp_dir, source, filename) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, source)
    previous_project = Engine.get_project()

    project = %Project{
      Project.new(Document.Path.to_uri(tmp_dir))
      | kind: :bare,
        mix_exs_uri: Document.Path.to_uri(path)
    }

    Engine.Mix.clear_accepted_project()
    Engine.set_project(project)

    on_exit(fn ->
      Engine.Mix.discard_project_modules(path)

      case previous_project do
        %Project{} -> Engine.set_project(previous_project)
        nil -> :persistent_term.erase({Engine, :project})
      end
    end)

    path
  end

  describe "compile/3" do
    @tag :tmp_dir
    test "reports diagnostics for an unaccepted custom MIX_EXS path", %{tmp_dir: tmp_dir} do
      source = """
      defmodule UnacceptedCustomHelper do
      end

      defmodule UnacceptedCustomMixProject do
        use Mix.Project
        Enum.test()
        def project, do: [app: :unaccepted_custom]
      end
      """

      path = unaccepted_project(tmp_dir, source, "project.exs")
      document = Document.new(Document.Path.to_uri(path), source, 0)

      assert {:error, diagnostics} = Quoted.compile(document, parse!(source), "Elixir")
      assert Enum.any?(diagnostics, &String.contains?(&1.message, "Enum.test/0"))
      refute Code.ensure_loaded?(UnacceptedCustomHelper)
      refute Code.ensure_loaded?(UnacceptedCustomMixProject)
    end

    @tag :tmp_dir
    test "rolls back a valid mix.exs edit", %{tmp_dir: tmp_dir} do
      {_project, path} = current_project(tmp_dir)
      code_paths = :code.get_path()

      source = """
      defmodule ReplacementMixProject do
        use Mix.Project
        Code.prepend_path(#{inspect(tmp_dir)})
        def project, do: [app: :replacement]
      end
      """

      document = Document.new(Document.Path.to_uri(path), source, 0)

      assert {:ok, []} = Quoted.compile(document, parse!(source), "Elixir")
      assert :code.get_path() == code_paths
      assert Mix.Project.get() == CurrentMixProject
      assert project_version() == "0.1.0"
      refute Code.ensure_loaded?(ReplacementMixProject)
    end

    @tag :tmp_dir
    test "reports diagnostics without applying mix.exs edits", %{tmp_dir: tmp_dir} do
      {_project, path} = current_project(tmp_dir)
      code_paths = :code.get_path()

      source = """
      defmodule TransactionHelper do
        def value, do: :changed
      end

      defmodule CurrentMixProject do
        use Mix.Project
        Code.prepend_path(#{inspect(tmp_dir)})
        Enum.test()
        def project, do: [app: :current_mix_project, version: "0.2.0"]
      end
      """

      document = Document.new(Document.Path.to_uri(path), source, 0)

      assert {:error, diagnostics} = Quoted.compile(document, parse!(source), "Elixir")
      assert Enum.any?(diagnostics, &String.contains?(&1.message, "Enum.test/0"))
      assert Mix.Project.get() == CurrentMixProject
      assert project_version() == "0.1.0"
      assert transaction_value() == :original

      corrected = String.replace(source, "Enum.test()", ":ok")
      corrected_document = Document.new(Document.Path.to_uri(path), corrected, 1)

      assert {:ok, []} = Quoted.compile(corrected_document, parse!(corrected), "Elixir")
      assert Mix.Project.get() == CurrentMixProject
      assert project_version() == "0.1.0"
      assert transaction_value() == :original
      assert :code.get_path() == code_paths
    end

    @tag :tmp_dir
    test "restores compiler settings and modules when the compiler process is killed", %{
      tmp_dir: tmp_dir
    } do
      {_project, path} = current_project(tmp_dir)
      env = Mix.env()
      target = Mix.target()
      code_paths = :code.get_path()
      Code.put_compiler_option(:tracers, [__MODULE__])

      source = """
      defmodule TransactionHelper do
        def value, do: :changed
      end

      defmodule CurrentMixProject do
        use Mix.Project
        Mix.env(:prod)
        Mix.target(:rejected_target)
        Code.prepend_path(#{inspect(tmp_dir)})
        Process.exit(self(), :kill)
        def project, do: [app: :current_mix_project, version: "broken"]
      end
      """

      document = Document.new(Document.Path.to_uri(path), source, 0)

      assert {:error, diagnostics} = Engine.Build.Document.compile(document)
      assert Enum.any?(diagnostics, &String.contains?(&1.message, "exited: :killed"))
      assert Code.compiler_options().tracers == [__MODULE__]
      assert Mix.env() == env
      assert Mix.target() == target
      assert :code.get_path() == code_paths
      assert project_version() == "0.1.0"
      assert transaction_value() == :original
    end

    @tag :tmp_dir
    test "does not use the root project transaction for a nested mix.exs", %{tmp_dir: tmp_dir} do
      current_project(tmp_dir)

      source = """
      defmodule Child.MixProject do
        use Mix.Project
        Enum.test()
        def project, do: [app: :child]
      end
      """

      nested_path = Path.join([tmp_dir, "apps", "child", "mix.exs"])
      document = Document.new(Document.Path.to_uri(nested_path), source, 0)

      assert {:ok, []} = Quoted.compile(document, parse!(source), "Elixir")
      assert Mix.Project.get() == CurrentMixProject
      assert project_version() == "0.1.0"
      refute Code.ensure_loaded?(Child.MixProject)
    end
  end

  describe "wrap_top_level_forms/1" do
    test "chunks and wraps unsafe top-level forms" do
      quoted =
        ~q[
          foo = 1
          bar = foo + 1

          import Something

          defmodule MyModule do
            :ok
          end

          baz = bar + foo
        ]
        |> parse!()

      assert quoted |> Quoted.wrap_top_level_forms() |> Macro.to_string() == """
             defmodule :expert_wrapper_0 do
               def __expert_wrapper__([]) do
                 foo = 1
                 _ = foo + 1
               end
             end

             import Something

             defmodule MyModule do
               :ok
             end

             defmodule :expert_wrapper_2 do
               def __expert_wrapper__([foo, bar]) do
                 _ = bar + foo
               end
             end\
             """
    end
  end

  describe "suppress_and_extract_vars/1" do
    test "suppresses and extracts unused vars" do
      quoted =
        ~q[
          foo = 1
          bar = 2
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}, {:bar, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             _ = 1
             _ = 2\
             """
    end

    test "suppresses and extracts unused vars in nested assignments" do
      quoted =
        ~q[
          foo = bar = 1
          baz = qux = 2
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}, {:bar, _, nil}, {:baz, _, nil}, {:qux, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             _ = _ = 1
             _ = _ = 2\
             """
    end

    test "suppresses vars only referenced in RHS" do
      quoted = ~q[foo = foo + 1] |> parse!()

      assert {suppressed, [{:foo, _, nil}]} = Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == "_ = foo + 1"
    end

    test "suppresses deeply nested vars" do
      quoted = ~q[{foo, {bar, %{baz: baz}}} = call()] |> parse!()

      assert {suppressed, [{:baz, _, nil}, {:bar, _, nil}, {:foo, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == "{_, {_, %{baz: _}}} = call()"
    end

    test "does not suppress vars referenced in a later expression" do
      quoted =
        ~q[
          foo = 1
          bar = foo + 1
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}, {:bar, _, nil}]} =
               Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             foo = 1
             _ = foo + 1\
             """
    end

    test "does not suppress vars referenced with pin operator in a later assignment" do
      quoted =
        ~q[
          foo = 1
          %{^foo => 2} = call()
        ]
        |> parse!()

      assert {suppressed, [{:foo, _, nil}]} = Quoted.suppress_and_extract_vars(quoted)

      assert Macro.to_string(suppressed) == """
             foo = 1
             %{^foo => 2} = call()\
             """
    end
  end
end
