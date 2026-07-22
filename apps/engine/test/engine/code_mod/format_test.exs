# credo:disable-for-this-file Credo.Check.Readability.RedundantBlankLines
defmodule Engine.CodeMod.FormatTest do
  use Forge.Test.CodeMod.Case, enable_ast_conversion: false
  use Patch

  alias Engine.Build
  alias Engine.CodeMod.Format
  alias Forge.Document
  alias Forge.Project

  defmodule ProjectConfigFormatter do
    @behaviour Mix.Tasks.Format

    @impl Mix.Tasks.Format
    def features(_opts) do
      [extensions: [".ex"], sigils: []]
    end

    @impl Mix.Tasks.Format
    def format(contents, _opts) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, :plugin_called)
      end

      formatted = Code.format_string!(contents)
      IO.iodata_to_binary([formatted, ?\n])
    end
  end

  def apply_code_mod(text, _ast, opts) do
    project = Keyword.get(opts, :project)

    file_uri =
      opts
      |> Keyword.get(:file_path, file_path(project))
      |> maybe_uri()

    with {:ok, document_edits} <- Format.edits(document(file_uri, text)) do
      {:ok, document_edits.edits}
    end
  end

  def maybe_uri(path_or_uri) when is_binary(path_or_uri), do: Document.Path.to_uri(path_or_uri)
  def maybe_uri(not_binary), do: not_binary

  def document(file_uri, text) do
    Document.new(file_uri, text, 1)
  end

  def file_path(project) do
    Path.join([Project.root_path(project), "lib", "format.ex"])
  end

  def unformatted do
    ~q[
    defmodule Unformatted do
      def something(  a,     b  ) do
    end
    end
    ]t
  end

  def formatted do
    ~q[
    defmodule Unformatted do
      def something(a, b) do
      end
    end
    ]t
  end

  def with_patched_build(_) do
    patch(Build, :compile_document, fn _, _ -> :ok end)
    :ok
  end

  def write_formatter_plugin_project!(tmp_dir) do
    root = Path.join(tmp_dir, "format_project")
    lib_dir = Path.join(root, "lib")

    File.mkdir_p!(lib_dir)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule FormatProject.MixProject do
      use Mix.Project

      def project do
        [
          app: :format_project,
          version: "0.1.0",
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(root, ".formatter.exs"), """
    [
      inputs: ["lib/**/*.{ex,exs}"],
      plugins: [#{inspect(ProjectConfigFormatter)}]
    ]
    """)

    File.write!(Path.join(lib_dir, "format.ex"), unformatted())

    root
    |> Document.Path.to_uri()
    |> Project.new()
  end

  # The dependency is fetched but never compiled, and its .formatter.exs derives
  # config from Mix.Project.config/0.
  def write_import_deps_project!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    app = :"import_deps_project_#{suffix}"
    root = Path.join(tmp_dir, Atom.to_string(app))
    lib_dir = Path.join(root, "lib")
    dep_dir = Path.join([root, "deps", "my_dep"])
    project_module = Module.concat([:"ImportDepsProject#{suffix}", MixProject])

    File.mkdir_p!(lib_dir)
    File.mkdir_p!(dep_dir)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule #{inspect(project_module)} do
      use Mix.Project

      def project do
        [
          app: #{inspect(app)},
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: [{:my_dep, path: "deps/my_dep"}]
        ]
      end
    end
    """)

    File.write!(Path.join(root, ".formatter.exs"), """
    [import_deps: [:my_dep], inputs: ["lib/**/*.{ex,exs}"]]
    """)

    File.write!(Path.join(dep_dir, ".formatter.exs"), """
    locals_without_parens = [my_dsl: 1]

    [minor | _] = Regex.run(~r/([\\d\\.]+)/, Mix.Project.config()[:elixir])

    [
      locals_without_parens: locals_without_parens,
      export: [locals_without_parens: locals_without_parens],
      minimum_elixir: minor
    ]
    """)

    File.write!(Path.join(lib_dir, "format.ex"), "my_dsl :foo\n")

    project = Project.new(Document.Path.to_uri(root))

    Mix.Project.in_project(app, root, fn module ->
      Project.set_project_module(project, module)
    end)
  end

  setup do
    project = project()
    Engine.set_project(project)
    start_supervised!({Format.Cache, project: project})
    {:ok, project: project}
  end

  describe "format/2" do
    setup [:with_patched_build]

    test "it should be able to format a file in the project", %{project: project} do
      {:ok, result} = modify(unformatted(), project: project)

      assert result == formatted()
    end

    @tag :tmp_dir
    test "formatter plugins are called during formatting", %{tmp_dir: tmp_dir} do
      project = write_formatter_plugin_project!(tmp_dir)
      Engine.set_project(project)

      :persistent_term.put({ProjectConfigFormatter, :test_pid}, self())
      on_exit(fn -> :persistent_term.erase({ProjectConfigFormatter, :test_pid}) end)

      assert {:ok, _result} =
               Mix.ProjectStack.on_clean_slate(fn ->
                 modify(unformatted(), project: project)
               end)

      assert_received :plugin_called
    end

    @tag :tmp_dir
    test "keeps locals_without_parens imported from an uncompiled dependency",
         %{tmp_dir: tmp_dir} do
      project = write_import_deps_project!(tmp_dir)
      Engine.set_project(project)

      file_path = Path.join([Project.root_path(project), "lib", "format.ex"])

      # The engine node formats with an empty Mix stack, where the dependency's
      # .formatter.exs would otherwise read an empty config.
      assert {:ok, result} =
               Mix.ProjectStack.on_clean_slate(fn ->
                 # Dependency paths are recorded while the project is loaded, as
                 # a build does.
                 Engine.Mix.in_project(project, fn _ -> Engine.Mix.record_deps(project) end)
                 modify("my_dsl :foo\n", file_path: file_path, project: project)
               end)

      assert result == "my_dsl :foo"
    end

    @tag :tmp_dir
    test "captures imports from newly matched formatter subdirectories", %{tmp_dir: tmp_dir} do
      project = write_import_deps_project!(tmp_dir)
      Engine.set_project(project)
      root = Project.root_path(project)
      child = Path.join([root, "apps", "child"])
      file_path = Path.join([child, "lib", "format.ex"])

      File.write!(
        Path.join(root, ".formatter.exs"),
        ~s([subdirectories: ["apps/*"], inputs: ["lib/**/*.{ex,exs}"]]\n)
      )

      Mix.ProjectStack.on_clean_slate(fn ->
        assert {:ok, :ok} =
                 Engine.Mix.in_project(project, fn _ -> Engine.Mix.record_deps(project) end)

        File.mkdir_p!(Path.dirname(file_path))

        File.write!(
          Path.join(child, ".formatter.exs"),
          ~s([import_deps: [:my_dep], inputs: ["lib/**/*.{ex,exs}"]]\n)
        )

        assert {:ok, :ok} =
                 Engine.Mix.in_project(project, fn _ -> Engine.Mix.record_deps(project) end)

        assert {:ok, "my_dsl :foo"} =
                 modify("my_dsl :foo\n", file_path: file_path, project: project)
      end)
    end

    @tag :tmp_dir
    test "formats while a build holds the project on the Mix stack",
         %{tmp_dir: tmp_dir} do
      project = write_import_deps_project!(tmp_dir)
      Engine.set_project(project)

      file_path = Path.join([Project.root_path(project), "lib", "format.ex"])
      parent = self()

      Mix.ProjectStack.on_clean_slate(fn ->
        build =
          Task.async(fn ->
            Engine.Mix.in_project(project, fn _ ->
              Engine.Mix.record_deps(project)
              send(parent, :build_project_pushed)

              receive do
                :finish_build -> :ok
              end
            end)
          end)

        assert_receive :build_project_pushed

        patch(Engine, :with_lock, fn lock, fun ->
          send(parent, {:lock_acquired, self(), lock})
          real(Engine).with_lock(lock, fun)
        end)

        formatter =
          Task.async(fn ->
            modify("my_dsl :foo\n", file_path: file_path, project: project)
          end)

        formatter_pid = formatter.pid
        assert {:ok, "my_dsl :foo"} = Task.await(formatter, 250)
        refute_received {:lock_acquired, ^formatter_pid, _lock}

        send(build.pid, :finish_build)
        assert {:ok, :ok} = Task.await(build)
      end)
    end

    test "it will fail to format a file not in the project", %{project: project} do
      file_path = "/tmp/foo.ex"
      expected_path = file_path |> Document.Path.to_uri() |> Document.Path.from_uri()

      assert {:error, reason} = modify(unformatted(), file_path: file_path, project: project)
      assert reason =~ "Cannot format file #{expected_path}"
      assert reason =~ "It is not in the project at"
    end

    @tag :tmp_dir
    test "it formats a file path inside the project root", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, "elixir")
      file_path = Path.join(project_path, "lsp_elixir_test.exs")
      project = %Project{root_uri: Document.Path.to_uri(project_path), kind: :bare}

      File.mkdir_p!(project_path)
      Engine.set_project(project)

      patch(Mix.Tasks.Future.Format, :formatter_for_file, fn _file_path, _opts ->
        formatter = fn source ->
          source
          |> Code.format_string!()
          |> IO.iodata_to_binary()
          |> Kernel.<>("\n")
        end

        {formatter, []}
      end)

      assert {:ok, result} = modify(unformatted(), file_path: file_path, project: project)
      assert result == formatted()
    end

    test "it should provide an error for a syntax error", %{project: project} do
      assert {:error, %SyntaxError{}} = ~q[
      def foo(a, ) do
        true
      end
      ] |> modify(project: project)
    end

    test "it should provide an error for a missing token", %{project: project} do
      assert {:error, %TokenMissingError{}} = ~q[
      defmodule TokenMissing do
       :bad
      ] |> modify(project: project)
    end

    test "it correctly handles unicode", %{project: project} do
      assert {:ok, result} = ~q[
        {"🎸",    "o"}
      ] |> modify(project: project)

      assert ~q[
        {"🎸", "o"}
      ]t == result
    end

    test "it handles extra lines", %{project: project} do
      assert {:ok, result} = ~q[
        defmodule  Unformatted do
          def something(    a        ,   b) do



          end
      end
      ] |> modify(project: project)

      assert result == formatted()
    end

    test "it handles special characters", %{project: project} do
      assert {:ok, result} =
               ~q"""
               [
                 {"Karolína Plíšková","Kristýna Plíšková"}
               ]
               """
               |> modify(project: project)

      assert result ==
               """
               [
                 {"Karolína Plíšková", "Kristýna Plíšková"}
               ]
               """
               |> String.trim()
    end
  end
end
