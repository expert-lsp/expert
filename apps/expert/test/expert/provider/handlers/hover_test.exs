defmodule Expert.Provider.Handlers.HoverTest do
  use ExUnit.Case, async: false

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.RangeSupport

  alias Engine.Search
  alias Expert.Document.Context
  alias Expert.EngineApi
  alias Expert.Protocol.Convert
  alias Expert.Provider.Handlers
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.EngineApi.Messages
  alias Forge.Test.Fixtures
  alias GenLSP.Requests
  alias GenLSP.Structures

  require Messages

  setup_all do
    project = Fixtures.project()

    start_supervised!({Forge.NodePortMapper, []})
    start_supervised!(Expert.Application.document_store_child_spec())
    start_supervised!({Expert.Project.Store, []})
    start_supervised!({DynamicSupervisor, Expert.Project.DynamicSupervisor.options()})
    start_supervised!({Expert.Project.Supervisor, project})

    Expert.Configuration.new() |> Expert.Configuration.set()

    :ok =
      EngineApi.register_listener(project, self(), [
        Messages.project_compiled(),
        Messages.project_index_ready()
      ])

    assert_receive Messages.project_compiled(), 5000
    assert_receive Messages.project_index_ready(), 5000

    {:ok, project: project}
  end

  setup do
    start_supervised!(Engine.ApplicationCache)
    :persistent_term.erase(Expert.Configuration)
    :ok
  end

  # compiles and writes beam files in the given project
  defp with_compiled_in(project, code, fun) do
    tmp_dir = Fixtures.file_path(project, "lib/tmp")

    tmp_path =
      tmp_dir
      |> Path.join("tmp_#{rand_hex(10)}.ex")

    File.mkdir_p!(tmp_dir)

    with_tmp_file(tmp_path, code, fn ->
      {:ok, compile_path} =
        Engine.Mix.in_project(project, fn _ ->
          Mix.Project.compile_path()
        end)

      {:ok, modules, _} =
        EngineApi.call(project, Kernel.ParallelCompiler, :compile_to_path, [
          [tmp_path],
          compile_path
        ])

      try do
        fun.()
      after
        for module <- modules do
          path = EngineApi.call(project, :code, :which, [module])
          EngineApi.call(project, :code, :delete, [module])
          File.rm!(path)
        end
      end
    end)
  end

  defp rand_hex(n_bytes) do
    n_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.hex_encode32()
  end

  defp with_tmp_file(file, content, fun) do
    File.write!(file, content)
    fun.()
  after
    File.rm_rf!(file)
  end

  describe "module hover" do
    test "with @moduledoc", %{project: project} do
      code = ~q[
        defmodule HoverWithDoc do
          @moduledoc """
          This module has a moduledoc.
          """
        end
      ]

      hovered = "|HoverWithDoc"

      expected = """
      ```elixir
      HoverWithDoc
      ```

      This module has a moduledoc.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«HoverWithDoc»" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "with @moduledoc false", %{project: project} do
      code = ~q[
        defmodule HoverPrivate do
          @moduledoc false
        end
      ]

      hovered = "|HoverPrivate"

      with_compiled_in(project, code, fn ->
        assert {:ok, nil} = hover(project, hovered)
      end)
    end

    test "without @moduledoc", %{project: project} do
      code = ~q[
        defmodule HoverNoDocs do
        end
      ]

      hovered = "|HoverNoDocs"

      with_compiled_in(project, code, fn ->
        assert {:ok, nil} = hover(project, hovered)
      end)
    end

    test "behaviour callbacks", %{project: project} do
      code = ~q[
        defmodule HoverBehaviour do
          @moduledoc "This is a custom behaviour."

          @type custom_type :: term()

          @callback foo(integer(), float()) :: custom_type
          @callback bar(term()) :: {:ok, custom_type}
        end
      ]

      hovered = "|HoverBehaviour"

      expected = """
      ```elixir
      HoverBehaviour
      ```

      This is a custom behaviour.

      ## Callbacks

      ```elixir
      @callback bar(term()) :: {:ok, custom_type()}
      ```

      ```elixir
      @callback foo(integer(), float()) :: custom_type()
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«HoverBehaviour»" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "behaviour callbacks with docs", %{project: project} do
      code = ~q[
        defmodule HoverBehaviour do
          @moduledoc "This is a custom behaviour."

          @type custom_type :: term()

          @doc """
          This is the doc for `foo/2`.
          """
          @callback foo(integer(), float()) :: custom_type

          @doc """
          This is the doc for `bar/1`.
          """
          @callback bar(term()) :: {:ok, custom_type}

          @callback baz(term()) :: :ok
        end
      ]

      hovered = "|HoverBehaviour"

      expected = """
      ```elixir
      HoverBehaviour
      ```

      This is a custom behaviour.

      ## Callbacks

      ```elixir
      @callback bar(term()) :: {:ok, custom_type()}
      ```

      This is the doc for `bar/1`.

      ```elixir
      @callback baz(term()) :: :ok
      ```

      ```elixir
      @callback foo(integer(), float()) :: custom_type()
      ```

      This is the doc for `foo/2`.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«HoverBehaviour»" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "struct with @moduledoc includes t/0 type", %{project: project} do
      code = ~q[
        defmodule StructWithDoc do
          @moduledoc """
          This module has a moduledoc.
          """

          defstruct foo: nil, bar: nil, baz: nil
          @type t :: %__MODULE__{
                  foo: String.t(),
                  bar: integer(),
                  baz: {boolean(), reference()}
                }
        end
      ]

      hovered = "%|StructWithDoc{}"

      expected = """
      ```elixir
      %StructWithDoc{}

      @type t() :: %StructWithDoc{
              bar: integer(),
              baz: {boolean(), reference()},
              foo: String.t()
            }
      ```

      This module has a moduledoc.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "%«StructWithDoc»{}" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "struct with @moduledoc includes all t types", %{project: project} do
      code = ~q[
        defmodule StructWithDoc do
          @moduledoc """
          This module has a moduledoc.
          """

          defstruct foo: nil
          @type t :: %__MODULE__{foo: String.t()}
          @type t(kind) :: %__MODULE__{foo: kind}
          @type t(kind1, kind2) :: %__MODULE__{foo: {kind1, kind2}}
        end
      ]

      hovered = "%|StructWithDoc{}"

      expected = """
      ```elixir
      %StructWithDoc{}

      @type t() :: %StructWithDoc{foo: String.t()}

      @type t(kind) :: %StructWithDoc{foo: kind}

      @type t(kind1, kind2) :: %StructWithDoc{foo: {kind1, kind2}}
      ```

      This module has a moduledoc.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "%«StructWithDoc»{}" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "struct with @moduledoc without type", %{project: project} do
      code = ~q[
        defmodule StructWithDoc do
          @moduledoc """
          This module has a moduledoc.
          """

          defstruct foo: nil
        end
      ]

      hovered = "%|StructWithDoc{}"

      expected = """
      ```elixir
      %StructWithDoc{}
      ```

      This module has a moduledoc.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "%«StructWithDoc»{}" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end
  end

  describe "call hover" do
    test "public function with @doc and @spec", %{project: project} do
      code = ~q[
        defmodule CallHover do
          @doc """
          This function has docs.
          """
          @spec my_fun(integer(), integer()) :: integer()
          def my_fun(x, y), do: x + y
        end
      ]

      hovered = "CallHover.|my_fun(1, 2)"

      expected = """
      ```elixir
      CallHover.my_fun(x, y)

      @spec my_fun(integer(), integer()) :: integer()
      ```

      This function has docs.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«CallHover.my_fun»(1, 2)" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "public function with multiple @spec", %{project: project} do
      code = ~q[
        defmodule CallHover do
          @spec my_fun(integer(), integer()) :: integer()
          @spec my_fun(float(), float()) :: float()
          def my_fun(x, y), do: x + y
        end
      ]

      hovered = "CallHover.|my_fun(1, 2)"

      expected = """
      ```elixir
      CallHover.my_fun(x, y)

      @spec my_fun(integer(), integer()) :: integer()
      @spec my_fun(float(), float()) :: float()
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«CallHover.my_fun»(1, 2)" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "public function with multiple arities and @spec", %{project: project} do
      code = ~q[
        defmodule CallHover do
          @spec my_fun(integer()) :: integer()
          def my_fun(x), do: x + 1

          @spec my_fun(integer(), integer()) :: integer()
          def my_fun(x, y), do: x + y

          @spec my_fun(integer(), integer(), integer()) :: integer()
          def my_fun(x, y, z), do: x + y + z
        end
      ]

      hovered = "CallHover.|my_fun(1, 2)"

      expected = """
      ```elixir
      CallHover.my_fun(x, y)

      @spec my_fun(integer(), integer()) :: integer()
      ```

      ---

      ```elixir
      CallHover.my_fun(x, y, z)

      @spec my_fun(integer(), integer(), integer()) :: integer()
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«CallHover.my_fun»(1, 2)" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "hovering a public function without parens", %{project: project} do
      code = ~q[
        defmodule CallHover do
          @doc "Function doc"
          def my_fun(x), do: x + 1
        end
      ]

      hovered = "CallHover.|my_fun"

      expected = """
      ```elixir
      CallHover.my_fun(x)
      ```

      Function doc
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«CallHover.my_fun»" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "private function", %{project: project} do
      code = ~q[
        defmodule CallHover do
          @spec my_fun(integer()) :: integer()
          defp my_fun(x), do: x + 1

          def my_other_fun(x, y), do: my_fun(x) + my_fun(y)
        end
      ]

      hovered = "CallHover.|my_fun(1)"

      expected = """
      ```elixir
      CallHover.my_fun(arg1)

      @spec my_fun(integer()) :: integer()
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
      end)
    end

    test "private function with public function of same name", %{project: project} do
      code = ~q[
        defmodule CallHover do
          @spec my_fun(integer()) :: integer()
          defp my_fun(x), do: x + 1

          def my_fun(x, y), do: my_fun(x) + my_fun(y)
        end
      ]

      hovered = "CallHover.|my_fun(1)"

      expected = """
      ```elixir
      CallHover.my_fun(x, y)
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«CallHover.my_fun»(1)" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "public macro with @doc", %{project: project} do
      code = ~q[
        defmodule MacroHover do
          @doc "This is a macro."
          defmacro my_macro(expr) do
            {:ok, expr}
          end
        end
      ]

      hovered = "MacroHover.|my_macro(:foo)"

      expected = """
      ```elixir
      (macro) MacroHover.my_macro(expr)
      ```

      This is a macro.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
        assert "«MacroHover.my_macro»(:foo)" = hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "splits to two lines if the signature is too long", %{project: project} do
      code = ~q[
        defmodule VeryVeryVeryLongModuleName.CallHover do
          def very_very_very_long_fun(_with, _many, _args) do
          end
        end
      ]

      hovered = ~q[
        alias VeryVeryVeryLongModuleName.CallHover
        CallHover.|very_very_very_long_fun(1, 2, 3)
      ]

      expected = """
      ```elixir
      CallHover.very_very_very_long_fun(with, many, args)
      VeryVeryVeryLongModuleName.CallHover
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
      end)
    end

    test "delegated function shows docs from original module", %{project: project} do
      code = ~q[
        defmodule DelegateHover.MyDefinition do
          @doc "Greets the given name."
          def greet(name), do: "Hello, \#{name}!"
        end

        defmodule DelegateHover.UsesDelegation do
          defdelegate greet(name), to: DelegateHover.MyDefinition
        end
      ]

      hovered = "DelegateHover.UsesDelegation.|greet(\"world\")"

      expected = """
      ```elixir
      DelegateHover.MyDefinition.greet(name)
      ```

      Greets the given name.
      """

      with_compiled_and_indexed(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
      end)
    end

    test "delegated function to unloaded module does not crash", %{project: project} do
      code = ~q[
        defmodule ModA do
          def test do
            ModB.func1()
          end
        end

        defmodule ModB do
          defdelegate func1, to: ModC
        end

        defmodule ModC do
          @doc """
          This is the original implementation
          """
          def func1, do: :ok
        end
      ]

      hovered = "ModB.|func1()"

      expected = """
      ```elixir
      ModC.func1()
      ```

      This is the original implementation
      """

      with_compiled_and_indexed(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
      end)
    end
  end

  describe "type hover" do
    test "with @typedoc", %{project: project} do
      code = ~q[
        defmodule TypeHover do
          @typedoc """
          This type has docs.
          """
          @type my_type() :: integer()
        end
      ]

      hovered = "@type foo :: TypeHover.|my_type()"

      expected = """
      ```elixir
      TypeHover.my_type/0

      @type my_type() :: integer()
      ```

      This type has docs.
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected

        assert "@type foo :: «TypeHover.my_type»()" =
                 hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "without @typedoc", %{project: project} do
      code = ~q[
        defmodule TypeHover do
          @type my_type() :: integer()
        end
      ]

      hovered = "@type foo :: TypeHover.|my_type()"

      expected = """
      ```elixir
      TypeHover.my_type/0

      @type my_type() :: integer()
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected

        assert "@type foo :: «TypeHover.my_type»()" =
                 hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "with var", %{project: project} do
      code = ~q[
        defmodule TypeHover do
          @type my_type(var) :: {integer(), var}
        end
      ]

      hovered = "@type foo :: TypeHover.|my_type(:foo)"

      expected = """
      ```elixir
      TypeHover.my_type/1

      @type my_type(var) :: {integer(), var}
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected

        assert "@type foo :: «TypeHover.my_type»(:foo)" =
                 hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "opaque with var", %{project: project} do
      code = ~q[
        defmodule TypeHover do
          @opaque my_type(var) :: {integer(), var}
        end
      ]

      hovered = "@type foo :: TypeHover.|my_type(:foo)"

      expected = """
      ```elixir
      TypeHover.my_type/1

      @opaque my_type(var)
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected

        assert "@type foo :: «TypeHover.my_type»(:foo)" =
                 hovered |> strip_cursor() |> decorate(result.range)
      end)
    end

    test "private type", %{project: project} do
      code = ~q[
        defmodule TypeHover do
          @typep my_type() :: integer()
          @type other() :: my_type()
        end
      ]

      hovered = "@type foo :: TypeHover.|my_type()"

      with_compiled_in(project, code, fn ->
        assert {:ok, nil} = hover(project, hovered)
      end)
    end

    test "splits to two lines if the signature is too long", %{project: project} do
      code = ~q[
        defmodule VeryVeryVeryLongModuleName.TypeHover do
          @opaque very_very_very_long_type(var) :: {integer(), var}
        end
      ]

      hovered =
        "@type foo :: VeryVeryVeryLongModuleName.TypeHover.|very_very_very_long_type(:foo)"

      expected = """
      ```elixir
      TypeHover.very_very_very_long_type/1
      VeryVeryVeryLongModuleName.TypeHover

      @opaque very_very_very_long_type(var)
      ```
      """

      with_compiled_in(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert result.contents.value == expected
      end)
    end
  end

  describe "module attribute hover" do
    test "shows attribute definition", %{project: project} do
      code = ~q[
        defmodule AttrHover do
          @my_attr "hello"

          def foo, do: @my_attr
        end
      ]

      hovered = ~q[
        defmodule AttrHover do
          @my_attr "hello"

          def foo, do: |@my_attr
        end
      ]

      with_indexed(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert String.contains?(result.contents.value, "@my_attr")
        assert String.contains?(result.contents.value, ~s[@my_attr "hello"])
      end)
    end

    test "shows multiline attribute definition", %{project: project} do
      code = """
      defmodule AttrHover do
        @config [
          name: "test",
          value: 42
        ]

        def get_config, do: @config
      end
      """

      hovered = """
      defmodule AttrHover do
        @config [
          name: "test",
          value: 42
        ]

        def get_config, do: |@config
      end
      """

      with_indexed(project, code, fn ->
        assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
        assert result.contents.kind == "markdown"
        assert String.contains?(result.contents.value, "@config")
        assert String.contains?(result.contents.value, "name:")
      end)
    end

    test "shows fallback when no definition found", %{project: project} do
      hovered = ~q[
        defmodule AttrHoverFallback do
          def foo, do: |@unknown_attr
        end
      ]

      assert {:ok, %Structures.Hover{} = result} = hover(project, hovered)
      assert result.contents.kind == "markdown"
      assert String.contains?(result.contents.value, "@unknown_attr")
    end
  end

  describe "hover inside strings" do
    test "returns nil inside a plain string (not interpolation)", %{project: project} do
      hovered = ~q[
        defmodule StringHover do
          def foo do
            "hello {Str|ing}"
          end
        end
      ]

      assert {:ok, nil} = hover(project, hovered)
    end

    test "returns a result inside string interpolation", %{project: project} do
      hovered = ~S[
        defmodule StringHover do
          def foo do
            "hello #{Str|ing}"
          end
        end
      ]

      assert {:ok, %Structures.Hover{}} = hover(project, hovered)
    end
  end

  defp with_indexed(project, code, fun) do
    tmp_dir = Fixtures.file_path(project, "lib/tmp")

    tmp_path =
      tmp_dir
      |> Path.join("tmp_indexed_#{rand_hex(10)}.ex")

    File.mkdir_p!(tmp_dir)

    with_tmp_file(tmp_path, code, fn ->
      uri = Document.Path.ensure_uri(tmp_path)
      {:ok, _document} = Document.Store.open_temporary(uri)

      {:ok, entries} = Search.Indexer.Source.index(tmp_path, code)
      :ok = EngineApi.call(project, Search.Store, :replace, [entries])

      try do
        fun.()
      after
        Document.Store.close(uri)
      end
    end)
  end

  # combine compilation (for docs) and indexing (for delegate detection)
  defp with_compiled_and_indexed(project, code, fun) do
    tmp_dir = Fixtures.file_path(project, "lib/tmp")

    tmp_path =
      tmp_dir
      |> Path.join("tmp_#{rand_hex(10)}.ex")

    File.mkdir_p!(tmp_dir)

    with_tmp_file(tmp_path, code, fn ->
      # compile the code so docs are available
      {:ok, compile_path} =
        Engine.Mix.in_project(project, fn _ ->
          Mix.Project.compile_path()
        end)

      {:ok, modules, _} =
        EngineApi.call(project, Kernel.ParallelCompiler, :compile_to_path, [
          [tmp_path],
          compile_path
        ])

      # index the code so delegate metadata is available
      {:ok, entries} = Search.Indexer.Source.index(tmp_path, code)
      :ok = EngineApi.call(project, Search.Store, :replace, [entries])

      try do
        fun.()
      after
        for module <- modules do
          path = EngineApi.call(project, :code, :which, [module])
          EngineApi.call(project, :code, :delete, [module])
          # only delete the .beam file, not the source file (which with_tmp_file handles)
          if is_binary(path), do: File.rm(path)
        end
      end
    end)
  end

  defp hover(project, hovered) do
    Expert.Project.Store.add_projects([project])

    with {position, hovered} <- pop_cursor(hovered),
         {:ok, document} <- document_with_content(project, hovered),
         {:ok, request} <- hover_request(document.uri, position) do
      context = Context.new(document.uri, document, project)
      Handlers.Hover.handle(request, context)
    end
  end

  defp document_with_content(project, content) do
    uri =
      project
      |> Fixtures.file_path(Path.join("lib", "my_doc.ex"))
      |> Document.Path.ensure_uri()

    case Document.Store.open(uri, content, 1) do
      :ok ->
        Document.Store.fetch(uri)

      {:error, :already_open} ->
        Document.Store.close(uri)
        document_with_content(project, content)

      error ->
        error
    end
  end

  defp hover_request(path, %Position{} = position) do
    hover_request(path, position.line, position.character)
  end

  defp hover_request(path, line, char) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri) do
      req = %Requests.TextDocumentHover{
        id: Expert.Protocol.Id.next(),
        params: %Structures.HoverParams{
          # convert line and char to zero-based
          position: %Structures.Position{line: line - 1, character: char - 1},
          text_document: %Structures.TextDocumentIdentifier{uri: uri}
        }
      }

      Convert.to_native(req)
    end
  end
end
