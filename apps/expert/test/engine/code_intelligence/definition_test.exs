defmodule Expert.Engine.CodeIntelligence.DefinitionTest do
  use ExUnit.Case, async: false

  import Forge.EngineApi.Messages
  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.RangeSupport

  alias Expert.EngineApi
  alias Expert.EngineNode
  alias Expert.EngineSupervisor
  alias Expert.Project.Indexer
  alias Expert.Search
  alias Expert.Search.Indexer.Beams
  alias Expert.Search.Store
  alias Expert.Search.Store.Backends.Sqlite
  alias Forge.Document

  @project_compile_timeout :timer.seconds(15)
  @project_index_timeout :timer.seconds(30)

  defp with_referenced_file(%{project: project}) do
    uri =
      project
      |> file_path(Path.join("lib", "my_definition.ex"))
      |> Document.Path.ensure_uri()

    {:ok, _document} = Document.Store.open_temporary(uri)

    on_exit(fn ->
      :ok = Document.Store.close(uri)
    end)

    %{uri: uri}
  end

  defp with_multi_arity_file(%{project: project}) do
    uri =
      project
      |> file_path(Path.join("lib", "multi_arity.ex"))
      |> Document.Path.ensure_uri()

    {:ok, _document} = Document.Store.open_temporary(uri)

    on_exit(fn ->
      :ok = Document.Store.close(uri)
    end)

    %{multi_arity_uri: uri}
  end

  defp subject_module_uri(project) do
    project
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp subject_module(project, content) do
    uri = subject_module_uri(project)

    with :ok <- Document.Store.open(uri, content, 1) do
      Document.Store.fetch(uri)
    end
  end

  setup_all do
    {:ok, _} =
      start_supervised({DynamicSupervisor, Expert.EngineBuild.DynamicSupervisor.options()})

    {:ok, _} = start_supervised(Expert.EngineBuilds)
    {:ok, _} = start_supervised({Forge.NodePortMapper, []})
    project = project(:navigations)
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    {:ok, _} = start_supervised({EngineSupervisor, project})
    {:ok, _, _} = EngineNode.start(project)
    start_supervised!({Sqlite, project})

    start_supervised!({Store, [project, Sqlite]})
    start_supervised!({Task.Supervisor, name: Indexer.task_supervisor_name(project)})
    start_supervised!({Indexer, project})

    EngineApi.register_listener(project, self(), [:all])
    EngineApi.schedule_compile(project, true)

    elixir_src = EngineApi.call(project, Engine.CodeIntelligence.ElixirSource, :detect, [])
    assert is_binary(elixir_src)

    :ok =
      EngineApi.call(project, Application, :put_env, [:language_server, :elixir_src, elixir_src])

    assert_receive project_compiled(), @project_compile_timeout
    assert_receive project_index_ready(project: ^project), @project_index_timeout

    %{project: project}
  end

  setup %{project: project} do
    start_supervised!(Engine.ApplicationCache)

    uri = subject_module_uri(project)

    # NOTE: We need to make sure every tests start with fresh caller content file
    on_exit(fn ->
      :ok = Document.Store.close(uri)
    end)

    %{subject_uri: uri}
  end

  describe "definition/2 when making remote call by alias" do
    setup [:with_referenced_file]

    test "find the definition of a remote function call", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MyDefinition

          def uses_greet() do
            MyDefinition.gree|t("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «greet(name)» do]
    end

    test "find the definition of the module", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MyDefinition

          def uses_greet() do
            MyDefinitio|n.greet("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[defmodule «MyDefinition» do]
    end

    test "find the definition of a struct", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteStruct do
          alias MyDefinition

          def uses_struct() do
            %|MyDefinition{}
          end
      end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == "  «defstruct [:field, another_field: nil]»"
    end

    test "find the macro definition", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          require MyDefinition

          def uses_macro() do
            MyDefinition.print_hel|lo()
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  defmacro «print_hello» do]
    end

    test "find the right arity function definition", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MultiArity

          def uses_multiple_arity_fun() do
            MultiArity.su|m(1, 2, 3)
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «sum»(a, b, c) do]
      assert referenced_uri =~ "navigations/lib/multi_arity.ex"
    end
  end

  describe "definition/2 when remote call exact arity is missing" do
    setup [:with_multi_arity_file]

    test "falls back to other arities of the same function", %{
      project: project,
      multi_arity_uri: multi_arity_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MultiArity

          def uses_sum() do
            MultiArity.su|m(1, 2, 3, 4)
          end
        end
      ]

      assert {:ok, definitions} = definition(project, subject_module, multi_arity_uri)

      assert definitions == [
               {multi_arity_uri, ~S[  def «sum(a, b)» do]},
               {multi_arity_uri, ~S[  def «sum(a, b, c)» do]}
             ]
    end

    test "prefers exact arity definitions when present", %{
      project: project,
      multi_arity_uri: multi_arity_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MultiArity

          def uses_sum() do
            MultiArity.su|m(1, 2, 3)
          end
        end
      ]

      assert {:ok, ^multi_arity_uri, definition_line} =
               definition(project, subject_module, multi_arity_uri)

      assert definition_line == ~S[  def «sum(a, b, c)» do]
    end

    test "falls back to other arities with ElixirSense", %{
      project: project,
      multi_arity_uri: multi_arity_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          alias MultiArity

          def uses_sum() do
            MultiArity.su|m(1, 2, 3, 4)
          end
        end
      ]

      assert {:ok, definitions} = definition(project, subject_module, [])

      assert definitions == [
               {multi_arity_uri, ~S[  def «sum»(a, b) do]},
               {multi_arity_uri, ~S[  def «sum»(a, b, c) do]}
             ]
    end
  end

  describe "definition/2 when making remote call by import" do
    setup [:with_referenced_file]

    test "find the definition of a remote function call", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          import MyDefinition

          def uses_greet() do
            gree|t("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «greet(name)» do]
    end

    test "find the definition of a remote macro call",
         %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          import MyDefinition

          def uses_macro() do
            print_hell|o()
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  defmacro «print_hello» do]
    end
  end

  describe "definition/2 when making remote call by use to import definition" do
    setup [:with_referenced_file]

    test "find the function definition", %{project: project, uri: referenced_uri} do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          use MyDefinition

          def uses_greet() do
            gree|t("World")
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[  def «greet»(name) do]
    end

    test "find the correct definition when func defined in the quote block", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesRemoteFunction do
          use MyDefinition

          def uses_hello_defined_in_using_quote() do
            hello_func_in_usin|g()
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[      def «hello_func_in_using»() do]
    end

    test "find the quoted definition injected into another module", %{
      project: project,
      uri: referenced_uri
    } do
      subject_module = ~q[
        defmodule UsesInjectedDefinition do
          def allowed?(user) do
            MyDefinition.Capability.allowe|d?(user, :some_capability)
          end
        end
      ]

      assert {:ok, ^referenced_uri, definition_line} =
               definition(project, subject_module, referenced_uri)

      assert definition_line == ~S[      def «allowed?(_user, _capability)», do: true]
    end
  end

  describe "definition/2 when making local call" do
    test "find multiple locations when the module is defined in multiple places", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyModule do # line 1
        end

        defmodule MyModule do # line 4
        end

        defmodule UsesMyModule do
          |MyModule
        end
      ]

      {:ok, [{_, definition_line1}, {_, definition_line4}]} =
        definition(project, subject_module, subject_uri)

      assert definition_line1 == ~S[defmodule «MyModule» do # line 1]
      assert definition_line4 == ~S[defmodule «MyModule» do # line 4]
    end

    test "find the function definition", %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet do
          end

          def uses_greet do
            gree|t()
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line == ~S[  def «greet» do]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the function definition when the function has `when` clause", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet(name) when is_binary(name) do
          end

          def uses_greet do
            gree|t("World")
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line == ~S[  def «greet(name) when is_binary(name)» do]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find only one function when there are multiple same arity functions", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet(name) when is_atom(name) do
            IO.inspect(name)
          end

          def greet(name) do
            name
          end

          def uses_greet do
            gree|t("World")
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)
      assert definition_line == ~S[  def «greet(name) when is_atom(name)» do]
      assert referenced_uri == subject_uri
    end

    test "find the function definition when referenced via __MODULE__", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesOwnFunction do
          def greet do
          end

          def uses_greet do
            __MODULE__.gree|t()
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line == ~S[  def «greet» do]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the function definition when alias __MODULE__ is used", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyApp.UsesOwnFunction do
          alias __MODULE__

          def greet do
          end

          def uses_greet do
            UsesOwnFunction.gree|t()
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line == ~S[  def «greet» do]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the attribute", %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        defmodule UsesAttribute do
          @b 2

          def use_attribute do
            @|b
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[«@b» 2]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the variable", %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        defmodule UsesVariable do
          def use_variable do
            a = 1

            if true do
              |a
            end
          end
        end
      ]

      {:ok, referenced_uri, definition_line} = definition(project, subject_module, subject_uri)

      assert definition_line =~ ~S[«a» = 1]
      assert referenced_uri =~ "navigations/lib/my_module.ex"
    end

    test "find the definition when calling a Elixir std module function",
         %{project: project, subject_uri: subject_uri} do
      subject_module = ~q[
        String.to_intege|r("1")
      ]

      {:ok, uri, definition_line} = definition(project, subject_module, subject_uri)

      assert uri =~ "lib/elixir/lib/string.ex"
      assert definition_line =~ ~S[  def «to_integer»(string) when is_binary(string) do]
    end

    test "find the definition when calling a erlang module", %{
      project: project,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        :erlang.binary_to_ato|m("1")
      ]

      {:ok, uri, definition_line} = definition(project, subject_module, subject_uri)

      assert uri =~ "/src/erlang.erl"
      assert definition_line =~ ~S[«binary_to_atom»(Binary)]
    end
  end

  describe "definition/2 when making local call to a delegated function" do
    setup [:with_referenced_file]

    test "find the definition of the delegated function", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule UsesDelegatedFunction do
          defdelegate greet(name), to: MyDefinition

          def uses_greet do
            gree|t("World")
          end
        end
      ]

      {:ok, [location1, location2]} = definition(project, subject_module, [uri, subject_uri])

      {referenced_uri, definition_line} = location1
      assert definition_line =~ ~S[  def «greet(name)» do]
      assert referenced_uri == uri

      {referenced_uri, definition_line} = location2
      assert definition_line == ~S[  defdelegate «greet(name)», to: MyDefinition]
      assert referenced_uri == subject_uri
    end
  end

  describe "definition/2 within LiveView's ~H sigil" do
    setup [:with_referenced_file]

    test "find the definition when full module specified", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <MyDefinition.but|ton navigate="/home">Home</MyDefinition.button>
            """
          end
        end
      ]

      assert {:ok, ^uri, definition} = definition(project, subject_module, [uri, subject_uri])
      assert definition == "  def «button(_assigns)» do"
    end

    test "find the definition when shorthand notation for function from same module", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.but|ton navigate="/home">Home</.button>
            """
          end

          def button(_assigns), do: nil
        end
      ]

      assert {:ok, ^subject_uri, fragment} =
               definition(project, subject_module, [uri, subject_uri])

      assert fragment == "  def «button(_assigns)», do: nil"
    end

    test "find the definition when shorthand notation used and imported function", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          use Phoenix.Component
          import MyDefinition

          def render(assigns) do
            ~H"""
            <.but|ton navigate="/home">Home</.button>
            """
          end
        end
      ]

      assert {:ok, ^uri, fragment} = definition(project, subject_module, [uri, subject_uri])
      assert fragment == "  def «button(_assigns)» do"
    end

    test "find the definition when shorthand notation used on closing tag", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          use Phoenix.Component
          import MyDefinition

          def render(assigns) do
            ~H"""
            <.button navigate="/home">Home</.but|ton>
            """
          end
        end
      ]

      assert {:ok, ^uri, fragment} = definition(project, subject_module, [uri, subject_uri])
      assert fragment == "  def «button(_assigns)» do"
    end

    test "find the definition when shorthand notation used on self-closing tag", %{
      project: project,
      uri: uri,
      subject_uri: subject_uri
    } do
      subject_module = ~q[
        defmodule MyLiveView do
          use Phoenix.Component
          import MyDefinition

          def render(assigns) do
            ~H"""
            <.but|ton />
            """
          end
        end
      ]

      assert {:ok, ^uri, fragment} = definition(project, subject_module, [uri, subject_uri])
      assert fragment == "  def «button(_assigns)» do"
    end
  end

  describe "edge cases" do
    setup [:with_referenced_file]

    test "doesn't crash with structs defined with DSLs", %{project: project, uri: uri} do
      subject_module = ~q[
      defmodule MyTest do
        def my_test(%TypedStructs.MacroBased|Struct{}) do
        end
      end
      ]

      assert {:ok, _file, _definition} = definition(project, subject_module, [uri])
    end
  end

  defp definition(project, code, referenced_uri) do
    with {position, code} <- pop_cursor(code),
         {:ok, document} <- subject_module(project, code),
         :ok <- index(project, referenced_uri),
         {:ok, location} <-
           EngineApi.definition(project, document, position) do
      if is_list(location) do
        {:ok, Enum.map(location, &{&1.document.uri, decorate(&1.document, &1.range)})}
      else
        {:ok, location.document.uri, decorate(location.document, location.range)}
      end
    end
  end

  defp index(project, referenced_uris) when is_list(referenced_uris) do
    entries =
      Enum.flat_map(referenced_uris, fn referenced_uri ->
        source_entries = do_index(referenced_uri)
        source_entries ++ compiler_use_entries(project, referenced_uri, source_entries)
      end)

    Store.replace(project, entries)
  end

  defp index(project, referenced_uri) do
    index(project, [referenced_uri])
  end

  defp do_index(referenced_uri) do
    with {:ok, document} <- Document.Store.fetch(referenced_uri),
         {:ok, entries} <-
           Search.Indexer.Source.index(document.path, Document.to_string(document)) do
      entries
    end
  end

  defp compiler_use_entries(project, referenced_uri, source_entries) do
    source_path = Document.Path.ensure_path(referenced_uri)

    beam_paths_by_name =
      project
      |> file_path(Path.join([".expert", "build", "**", "ebin", "*.beam"]))
      |> Path.wildcard()
      |> Enum.group_by(&Path.basename/1)

    source_entries
    |> Enum.filter(&(&1.type == :module and is_atom(&1.subject)))
    |> Enum.flat_map(fn entry ->
      beam_paths_by_name
      |> Map.get("#{entry.subject}.beam", [])
      |> Enum.flat_map(fn beam_path ->
        with {:ok, binary} <- File.read(beam_path),
             {:ok, entries} <- Beams.extract_definitions_from_binary(binary, source_path) do
          Enum.filter(entries, &match?(%{metadata: %{via: :use}}, &1))
        else
          _ -> []
        end
      end)
    end)
    |> Enum.uniq_by(&{&1.subject, &1.type})
  end
end
