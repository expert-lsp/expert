defmodule Engine.CodeIntelligence.EntityTest do
  use ExUnit.Case
  use Patch

  import ExUnit.CaptureIO
  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures
  import Forge.Test.RangeSupport

  alias Engine.CodeIntelligence.Entity
  alias FooWeb.AdminLive.Agreements.AgreementController
  alias Forge.Document

  describe "module resolve/2" do
    test "succeeds with trailing period" do
      code = ~q[
        Some.Modul|e.
      ]

      assert {:ok, {:module, Some.Module}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«Some.Module».]
    end

    test "succeeds immediately following the module" do
      code = ~q[
        Beyond.The.End|
      ]

      assert {:ok, {:module, Beyond.The.End}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«Beyond.The.End»]
    end

    test "fails with an extra space following the module" do
      code = ~q[
        Beyond.The.End |
      ]

      assert {:error, :not_found} = resolve(code)
    end

    test "fails immediately preceding the module" do
      code = ~q[
        | Before.The.Beginning
      ]

      assert {:error, :not_found} = resolve(code)
    end

    test "resolves module segments at and before the cursor" do
      code = ~q[
        In.|The.Middle
      ]

      assert {:ok, {:module, In.The}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«In.The».Middle]
    end

    test "excludes trailing module segments with the cursor is on a period" do
      code = ~q[
        AAA.BBB.CCC.DDD|.EEE
      ]

      assert {:ok, {:module, AAA.BBB.CCC.DDD}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«AAA.BBB.CCC.DDD».EEE]
    end

    test "succeeds for modules within a multi-line node" do
      code = ~q[
        foo =
          On.Another.Lin|e
      ]

      assert {:ok, {:module, On.Another.Line}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «On.Another.Line»]
    end

    test "resolves the entire module for multi-line modules" do
      code = ~q[
        On.
          |Multiple.
          Lines
      ]

      assert {:ok, {:module, On.Multiple.Lines}, resolved_range} = resolve(code)

      assert resolved_range =~ """
             «On.
               Multiple.
               Lines»\
             """
    end

    test "succeeds in single line calls" do
      code = ~q[
        |Enum.map(1..10, & &1 + 1)
      ]

      assert {:ok, {:module, Enum}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«Enum».map(1..10, & &1 + 1)]
    end

    test "succeeds in multi-line calls" do
      code = ~q[
        |Enum.map(1..10, fn i ->
          i + 1
        end)
      ]

      assert {:ok, {:module, Enum}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«Enum».map(1..10, fn i ->]
    end

    test "expands top-level aliases" do
      code = ~q[
        defmodule Example do
          alias Long.Aliased.Module
          Modul|e
        end
      ]

      assert {:ok, {:module, Long.Aliased.Module}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «Module»]
    end

    test "ignores top-level aliases made after the cursor" do
      code = ~q[
        defmodule Example do
          Modul|e
          alias Long.Aliased.Module
        end
      ]

      assert {:ok, {:module, Module}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «Module»]
    end

    test "resolves implicit aliases" do
      code = ~q[
        defmodule Example do
          defmodule Inner do
          end

          Inne|r
        end
      ]

      assert {:ok, {:module, Example.Inner}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «Inner»]
    end

    test "expands current module" do
      code = ~q[
        defmodule Example do
          |__MODULE__
        end
      ]

      assert {:ok, {:module, Example}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «__MODULE__»]
    end

    test "expands current module used in alias" do
      code = ~q[
        defmodule Example do
          |__MODULE__.Nested
        end
      ]

      assert {:ok, {:module, Example}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «__MODULE__».Nested]
    end

    test "expands alias following current module" do
      code = ~q[
        defmodule Example do
          __MODULE__.|Nested
        end
      ]

      assert {:ok, {:module, Example.Nested}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «__MODULE__.Nested»]
    end

    test "works for erlang modules" do
      code = ~q[:code|]

      assert {:ok, {:module, :code}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[:code]
    end

    test "fails for plain old atoms" do
      code = ~q[:not_a_module|]
      assert {:error, {:unsupported, {:unquoted_atom, ~c"not_a_module"}}} = resolve(code)
    end

    test "handles inline embeds_one" do
      code = ~q[
      defmodule MyEcto do
        use Ecto.Schema

        schema "user" do
          embeds_one :address, Address| do
            field :street, :string
          end
        end
      end
      ]
      assert {:ok, {:module, MyEcto.Address}, resolved_range} = resolve(code)
      assert resolved_range =~ ~s[Address]
    end

    test "handles inline embeds_many" do
      code = ~q[
      defmodule MyEcto do
        use Ecto.Schema

        schema "user" do
          embeds_many :addresses, Address| do
            field :street, :string
          end
        end
      end
      ]
      assert {:ok, {:module, MyEcto.Address}, resolved_range} = resolve(code)
      assert resolved_range =~ ~s[Address]
    end
  end

  describe "controller module resolve/2 in the phoenix router" do
    setup do
      patch(Entity, :function_exists?, fn
        FooWeb.FooController, :call, 2 -> true
        FooWeb.FooController, :action, 2 -> true
      end)

      :ok
    end

    test "succeeds in the `get` block" do
      code = ~q[
        scope "/foo", FooWeb do
          get "/foo", |FooController, :index
        end
      ]

      assert {:ok, {:module, FooWeb.FooController}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[get "/foo", «FooController», :index]
    end

    test "succeeds in the `post` block" do
      code = ~q[
        scope "/foo", FooWeb do
          post "/foo", |FooController, :create
        end
      ]

      assert {:ok, {:module, FooWeb.FooController}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[post "/foo", «FooController», :create]
    end

    test "succeeds even the scope module has multiple dots" do
      patch(Entity, :function_exists?, fn
        FooWeb.Bar.FooController, :call, 2 -> true
        FooWeb.Bar.FooController, :action, 2 -> true
      end)

      code = ~q[
        scope "/foo", FooWeb.Bar do
          get "/foo", |FooController, :index
        end
      ]

      assert {:ok, {:module, FooWeb.Bar.FooController}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[get "/foo", «FooController», :index]
    end

    test "succeeds in the nested scopes" do
      patch(Entity, :function_exists?, fn
        FooWeb.Bar.FooController, :call, 2 -> true
        FooWeb.Bar.FooController, :action, 2 -> true
      end)

      code = ~q[
        scope "/", FooWeb do
          scope "/bar", Bar do
            get "/foo", |FooController, :index
          end
        end
      ]

      assert {:ok, {:module, FooWeb.Bar.FooController}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[get "/foo", «FooController», :index]
    end

    # Regression test for https://github.com/elixir-lang/expert/issues/360
    # Sibling scope aliases were being concatenated into the module path,
    # causing resolution to fail (or crash with :system_limit for many siblings).
    test "does not include sibling scope aliases" do
      patch(Entity, :function_exists?, fn
        FooWeb.ARLive.Quickbooks, :call, 2 -> true
        FooWeb.ARLive.Quickbooks, :action, 2 -> true
      end)

      code = ~q[
        scope "/", FooWeb do
          scope "/admin", AdminLive do
            get "/types", TypeController, :index
          end

          scope "/ar", ARLive do
            get "/quickbooks", |Quickbooks, :index
          end
        end
      ]

      assert {:ok, {:module, FooWeb.ARLive.Quickbooks}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[get "/quickbooks", «Quickbooks», :index]
    end

    test "does not include sibling scope aliases in nested scopes" do
      patch(Entity, :function_exists?, fn
        AgreementController, :call, 2 -> true
        AgreementController, :action, 2 -> true
      end)

      code = ~q[
        scope "/", FooWeb do
          scope "/admin", AdminLive do
            scope "/types", AffiliationTypes do
              get "/", TypeController, :index
            end

            scope "/agreements", Agreements do
              get "/", |AgreementController, :index
            end
          end
        end
      ]

      assert {:ok, {:module, AgreementController}, resolved_range} =
               resolve(code)

      assert resolved_range =~ ~S[get "/", «AgreementController», :index]
    end
  end

  describe "liveview module resolve in the router" do
    test "succeeds in the `live` block" do
      patch(Entity, :function_exists?, fn
        FooWeb.FooLive, :mount, 2 -> true
        FooWeb.FooLive, :render, 1 -> true
      end)

      code = ~q[
        scope "/foo", FooWeb do
          live "/foo", |FooLive
        end
      ]

      assert {:ok, {:module, FooLive}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[live "/foo", «FooLive»]
    end
  end

  describe "struct resolve/2" do
    test "succeeds when the cursor is on the %" do
      code = ~q[
        |%MyStruct{}
      ]

      assert {:ok, {:struct, MyStruct}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[%«MyStruct»{}]
    end

    test "succeeds when the cursor is in an alias" do
      code = ~q[
        %My|Struct{}
      ]

      assert {:ok, {:struct, MyStruct}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[%«MyStruct»{}]
    end

    test "succeeds when the cursor is on the opening bracket" do
      code = ~q[
        %MyStruct|{}
      ]

      assert {:ok, {:struct, MyStruct}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[%«MyStruct»{}]
    end

    test "succeeds when the struct fields span multiple lines" do
      code = ~q[
        %MyStruct.|Nested{
          foo: 1,
          bar: 2
        }
      ]

      assert {:ok, {:struct, MyStruct.Nested}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[%«MyStruct.Nested»{]
    end

    test "succeeds when the struct spans multiple lines" do
      code = ~q[
        %On.
          |Multiple.
          Lines{}
      ]

      assert {:ok, {:module, On.Multiple.Lines}, resolved_range} = resolve(code)

      assert resolved_range =~ """
             %«On.
               Multiple.
               Lines»{}\
             """
    end

    test "shouldn't include trailing module segments" do
      code = ~q[
        %My|Struct.Nested{}
      ]

      assert {:ok, {:module, MyStruct}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[%«MyStruct».Nested{}]
    end

    test "expands current module" do
      code = ~q[
        defmodule Example do
          %|__MODULE__{}
        end
      ]

      assert {:ok, {:struct, Example}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  %«__MODULE__»{}]
    end

    test "succeeds for implicitly aliased module" do
      code = ~q<
        defmodule Example do
          defmodule Inner do
            defstruct []
          end

         def make do
           %|Inner{}
         end
        end
      >

      assert {:ok, {:struct, Example.Inner}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  %«Inner»{}]
    end

    test "succeeds for explicitly aliased module" do
      code = ~q[
        defmodule Example do
          alias Something.Example
          %Example.|Inner{}
        end
      ]

      assert {:ok, {:struct, Something.Example.Inner}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  %«Example.Inner»{}]
    end

    test "succeeds for module nested inside current module" do
      code = ~q[
        defmodule Example do
          %__MODULE__.|Inner{}
        end
      ]

      assert {:ok, {:struct, Example.Inner}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  %«__MODULE__.Inner»{}]
    end
  end

  describe "call resolve/2" do
    test "qualified call" do
      code = ~q[
        def example do
          MyModule.|some_function(1, 2, 3)
        end
      ]

      assert {:ok, {:call, MyModule, :some_function, 3}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«MyModule.some_function»(1, 2, 3)]
    end

    test "qualified call without parens" do
      code = ~q[
        MyModule.|some_function 1, 2, 3
      ]

      assert {:ok, {:call, MyModule, :some_function, 3}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«MyModule.some_function» 1, 2, 3]
    end

    test "qualified call with nested alias" do
      code = ~q[
        MyModule.Nested.|some_function(1, 2, 3)
      ]

      assert {:ok, {:call, MyModule.Nested, :some_function, 3}, resolved_range} = resolve(code)

      assert resolved_range =~ ~S[«MyModule.Nested.some_function»(1, 2, 3)]
    end

    test "multi-line qualified call" do
      code = ~q[
        MyModule.|some_function(
          1, 2, 3
        )
      ]

      assert {:ok, {:call, MyModule, :some_function, 3}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«MyModule.some_function»(]
    end

    test "qualified call at start of pipe" do
      code = ~q[
        1
        |> MyModule.|some_function(2, 3)
        |> other()
        |> other()
      ]

      assert {:ok, {:call, MyModule, :some_function, 3}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[|> «MyModule.some_function»(2, 3)]
    end

    test "qualified call at end of pipe" do
      code = ~q[
        1
        |> other()
        |> other()
        |> MyModule.|some_function(2, 3)
      ]

      assert {:ok, {:call, MyModule, :some_function, 3}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[|> «MyModule.some_function»(2, 3)]
    end

    test "qualified call nested in a pipe" do
      code = ~q[
        1
        |> other()
        |> MyModule.|some_function(2, 3)
        |> other()
      ]

      assert {:ok, {:call, MyModule, :some_function, 3}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[|> «MyModule.some_function»(2, 3)]
    end

    test "qualified call inside another call" do
      code = ~q[
        foo(1, 2, MyModule.|some_function(3))
      ]

      assert {:ok, {:call, MyModule, :some_function, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[foo(1, 2, «MyModule.some_function»(3))]
    end

    test "qualified call on same line as a string with newlines" do
      code = ~q[
        Enum.map_join(list, "\n\n---\n\n", &String.tri|m(&1)) <> "\n"
      ]

      assert {:ok, {:call, String, :trim, 1}, _} = resolve(code)
    end

    test "qualified call within a block" do
      code = ~q/
        if true do
          MyModule.some_|function(bar)
          :ok
        end
      /

      assert {:ok, {:call, MyModule, :some_function, 1}, _} = resolve(code)
    end

    test "qualified call on left of type operator" do
      code = ~q[
        my_dsl do
          MyModule.|my_fun() :: MyModule.t()
        end
      ]

      assert {:ok, {:call, MyModule, :my_fun, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  «MyModule.my_fun»() :: MyModule.t()]
    end

    test "qualified call for an erlang function" do
      code = ~q[
        :code.which|()
      ]
      assert {:ok, {:call, :code, :which, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ "«:code.which»()"
    end

    test "captured calls with arity" do
      code = ~q[
        &MyModule.|my_fun/2
      ]
      assert {:ok, {:call, MyModule, :my_fun, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ "«MyModule.my_fun»/2"
    end

    test "captured calls with args" do
      code = ~q[
        &MyModule.|my_fun(:foo, &1)
      ]
      assert {:ok, {:call, MyModule, :my_fun, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ "&«MyModule.my_fun»(:foo, &1)"
    end

    test "defstruct call" do
      code = ~q[
      defmodule MyModule do
        defstruct| foo: nil
      end
      ]
      assert {:ok, {:call, Kernel, :defstruct, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ "  «defstruct» foo: nil"
    end

    test "comments are ignored" do
      code = ~q[
        defmodule Scratch do
          def many_such_pipes() do
            "pipe"
            |> a_humble_pipe()
            # |> another_|humble_pipe()
            |> a_humble_pipe()
          end
        end
      ]

      assert {:error, :not_found} = resolve(code)
    end
  end

  describe "local call" do
    test "in function definition" do
      code = ~q[
        defmodule Parent do

          def my_call|(a, b)
        end
      ]
      assert {:ok, {:call, Parent, :my_call, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[def «my_call»(a, b)]
    end

    test "in zero arg function definition" do
      code = ~q[
      defmodule Parent do
        def zero_ar|g do
        end
      end
      ]

      assert {:ok, {:call, Parent, :zero_arg, 0}, resolved_range} = resolve(code, evaluate: true)
      assert resolved_range =~ "  def «zero_arg» do"
    end

    @tag skip: Version.match?(System.version(), "< 1.15.0")
    test "in zero arg function call" do
      code = ~q[
      defmodule Parent do
        def zero_arg do
          zero_ar|g
        end
      end
      ]

      assert {:ok, {:call, Parent, :zero_arg, 0}, resolved_range} = resolve(code, evaluate: true)
      assert resolved_range =~ "  «zero_arg»"
    end

    test "in private function definition" do
      code = ~q[
        defmodule Parent do

          defp my_call|(a, b)
        end
      ]
      assert {:ok, {:call, Parent, :my_call, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[defp «my_call»(a, b)]
    end

    test "in function definition without parens" do
      code = ~q[
        defmodule Parent do

          def |my_call
        end
      ]
      assert {:ok, {:call, Parent, :my_call, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[def «my_call»]
    end

    test "in private function definition without parens" do
      code = ~q[
        defmodule Parent do

          defp |my_call
        end
      ]
      assert {:ok, {:call, Parent, :my_call, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[defp «my_call»]
    end

    test "in function body with arity 0" do
      code = ~q[
        defmodule Parent do
          def function do
            local_fn|()
          end
        end
      ]
      assert {:ok, {:call, Parent, :local_fn, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    «local_fn»()]
    end

    test "in function body with arity 2" do
      code = ~q[
        defmodule Parent do
          def function do
            local_fn|(a, b)
          end
        end
      ]
      assert {:ok, {:call, Parent, :local_fn, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    «local_fn»(a, b)]
    end

    test "in a function capture" do
      code = ~q[
        defmodule Parent do
          def function do
            &local_fn|/1
          end
        end
      ]

      assert {:ok, {:call, Parent, :local_fn, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    &«local_fn»/1]
    end

    test "failed at the position of the molecule" do
      code = ~q[
        defmodule Parent do
          def function do
            a = 1
            a|/1
          end
        end
      ]

      assert {:error, :not_found} = resolve(code)
    end

    test "failed at the position of the denominator" do
      code = ~q[
        defmodule Parent do
          def function do
            a = 1
            a/|1
          end
        end
      ]

      assert {:error, :not_found} = resolve(code)
    end

    test "in a function capture and the cursor is at `ampersand`" do
      code = ~q[
        defmodule Parent do
          def function do
            &|local_fn/1
          end
        end
      ]

      assert {:ok, {:call, Parent, :local_fn, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    &«local_fn»/1]
    end

    test "in a function capture with arity 2" do
      code = ~q[
        defmodule Parent do
          def function do
            &|local_fn/2
          end
        end
      ]

      assert {:ok, {:call, Parent, :local_fn, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    &«local_fn»/2]
    end

    test "in a function capture with params" do
      code = ~q[
        defmodule Parent do
          def function do
            &local_fn|(&1, 1)
          end
        end
      ]
      assert {:ok, {:call, Parent, :local_fn, 2}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    &«local_fn»(&1, 1)]
    end

    test "in a another call" do
      code = ~q[
        defmodule Parent do
          def function do
            Module.remote(local_call|(3))
          end
        end
      ]
      assert {:ok, {:call, Parent, :local_call, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[    Module.remote(«local_call»(3))]
    end

    test "in a pipe" do
      code = ~q[
        defmodule Parent do
          def function do
            something
            |> Module.a()
            |> local_call|()
          end
        end
      ]
      assert {:ok, {:call, Parent, :local_call, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[   |> «local_call»()]
    end

    test "returns a nil module when outside of a module" do
      code = ~q[
        local_call|()
      ]
      assert {:ok, {:call, nil, :local_call, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«local_call»()]
    end
  end

  describe "imported call" do
    test "imported in module scope" do
      code = ~q[
        defmodule Parent do
          import Forge.Ast

          def parse(doc), do: |from(doc)
        end
      ]

      assert {:ok, {:call, Forge.Ast, :from, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«from»(doc)]
    end

    test "imported in function scope" do
      code = ~q[
        defmodule Parent do
          def parse(doc) do
            import Forge.Ast
            |from(doc)
          end
        end
      ]

      assert {:ok, {:call, Forge.Ast, :from, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«from»(doc)]
    end

    test "imports in a different scope don't clobber local calls" do
      code = ~q[
        defmodule Parent do
          def parse(doc) do
            import Forge.Ast
            from(doc)
          end

          def parse2(doc) do
            |from(doc)
          end
        end
      ]

      assert {:ok, {:call, Parent, :from, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[«from»(doc)]
    end

    test "imported from unloaded module (local_call)" do
      code = ~q[
        defmodule MyProject.B do
          def foo(), do: 1
        end

        defmodule MyProject do
          import MyProject.B

          def test() do
            |foo()
          end
        end
      ]

      assert {:ok, {:call, MyProject.B, :foo, 0}, _} = resolve(code)
    end

    test "imported from unloaded module (local_or_var)" do
      code = ~q[
        defmodule MyProject.B do
          def foo(), do: 1
        end

        defmodule MyProject do
          import MyProject.B

          def test() do
            |foo
          end
        end
      ]

      assert {:ok, {:call, MyProject.B, :foo, 0}, _} = resolve(code)
    end

    test "imported from unloaded module (module-level call)" do
      code = ~q[
        defmodule MyProject.B do
          def foo(), do: 1
        end

        defmodule MyProject do
          import MyProject.B

          |foo()
        end
      ]

      assert {:ok, {:call, MyProject.B, :foo, 0}, _} = resolve(code)
    end

    test "imported from unloaded module (capture)" do
      code = ~q[
        defmodule MyProject.B do
          def foo(), do: 1
        end

        defmodule MyProject do
          import MyProject.B

          def test() do
            &foo|/0
          end
        end
      ]

      assert {:ok, {:call, MyProject.B, :foo, 0}, _} = resolve(code)
    end

    test "imported function in a capture" do
      code = ~q[
        defmodule Parent do
          import Forge.Ast

          def function do
            &from|/1
          end
        end
      ]

      assert {:ok, {:call, Forge.Ast, :from, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[&«from»/1]
    end

    test "imported function in a capture (cursor before name)" do
      code = ~q[
        defmodule Parent do
          import Forge.Ast

          def function do
            &|from/1
          end
        end
      ]

      assert {:ok, {:call, Forge.Ast, :from, 1}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[&«from»/1]
    end
  end

  describe "type resolve/2" do
    test "qualified types in @type" do
      code = ~q[
        @type my_type :: MyModule.|t()
      ]

      assert {:ok, {:type, MyModule, :t, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[@type my_type :: «MyModule.t»()]
    end

    test "qualified types in @spec" do
      code = ~q[
        @spec my_fun() :: MyModule.|t()
      ]

      assert {:ok, {:type, MyModule, :t, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[@spec my_fun() :: «MyModule.t»()]
    end

    test "qualified types in DSL" do
      code = ~q[
        my_dsl do
          my_fun() :: MyModule.|t()
        end
      ]

      assert {:ok, {:type, MyModule, :t, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[  my_fun() :: «MyModule.t»()]
    end

    test "qualified types in nested structure" do
      code = ~q[
        @type my_type :: %{foo: MyModule.|t()}
      ]

      assert {:ok, {:type, MyModule, :t, 0}, resolved_range} = resolve(code)
      assert resolved_range =~ ~S[@type my_type :: %{foo: «MyModule.t»()}]
    end
  end

  describe "module attribute resolve" do
    test "in a scalar definition" do
      code = ~q[
       defmodule Parent do
         @attribut|e 3
       end
      ]

      assert {:ok, {:module_attribute, Parent, :attribute}, resolved_range} = resolve(code)
      assert resolved_range =~ "«@attribute» 3"
    end

    test "in a nested reference" do
      code = ~q[
      defmodule Parent do
        @foo 3
        @ba|r @foo + 1
      end
      ]

      assert {:ok, {:module_attribute, Parent, :bar}, resolved_range} = resolve(code)
      assert resolved_range =~ "«@bar» @foo + 1"
    end

    test "in a function definition" do
      code = ~q[
      defmodule Parent do

        def my_fun(@fo|o), do: 3
      end
      ]

      assert {:ok, {:module_attribute, Parent, :foo}, resolved_range} = resolve(code)
      assert resolved_range =~ "def my_fun(«@foo»), do: 3"
    end

    test "in map keys" do
      code = ~q[
      defmodule Parent do

        def my_fun(_), do: %{@fo|o => 3}
      end
      ]

      assert {:ok, {:module_attribute, Parent, :foo}, resolved_range} = resolve(code)
      assert resolved_range =~ "%{«@foo» => 3}"
    end

    test "in map values" do
      code = ~q[
      defmodule Parent do

        def my_fun(_), do: %{foo: @fo|o}
      end
      ]

      assert {:ok, {:module_attribute, Parent, :foo}, resolved_range} = resolve(code)
      assert resolved_range =~ "%{foo: «@foo»}"
    end

    test "returns nil module you're not in a module context" do
      code = ~q[
       @fo|o 3
      ]

      assert {:ok, {:module_attribute, nil, :foo}, resolved_range} = resolve(code)
      assert resolved_range =~ "«@foo» 3"
    end
  end

  describe "resolve/2 within ~H sigil" do
    setup do
      patch(Engine.CodeIntelligence.Heex, :phoenix_component_available?, true)
      :ok
    end

    test "resolves shorthand component with correct arity" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.but|ton>Click</.button>
            """
          end

          def button(assigns), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :button, 1}, _} = resolve(code)
    end

    test "resolves shorthand component without closing tag with correct arity" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.but|ton label="Click" />
            """
          end

          def button(assigns), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :button, 1}, _} = resolve(code)
    end

    test "resolves shorthand component with curly braces with correct arity" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.but|ton label={label} />
            """
          end

          def button(assigns), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :button, 1}, _} = resolve(code)
    end

    test "resolves shorthand component with curly braces on the first line of sigil with correct arity" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"<.butto|n label={label} />"
          end

          def button(assigns), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :button, 1}, _} = resolve(code)
    end

    test "resolves function called inside shorthand component with curly braces with correct arity" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.button label={LabelGenerator.for_bu|tton("label", in_live_view: true, language: :en)} />
            """
          end

          def button(assigns), do: nil
        end
      ]

      assert {:ok, {:call, LabelGenerator, :for_button, 2}, _} = resolve(code)
    end

    test "resolves EEx expression with arity 1" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <%= my_he|lper(assigns) %>
            """
          end

          def my_helper(assigns), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :my_helper, 1}, _} = resolve(code)
    end

    test "resolves EEx expression with arity 2" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <%= forma|t_value(assigns.value, "prefix") %>
            """
          end

          def format_value(value, prefix), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :format_value, 2}, _} = resolve(code)
    end

    test "resolves EEx expression with arity 3" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <%= build_l|ink(assigns, "/path", "label") %>
            """
          end

          def build_link(assigns, path, label), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :build_link, 3}, _} = resolve(code)
    end

    test "resolves curly brace expression with correct arity" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <div class={get_cl|ass(assigns, "default")}>Content</div>
            """
          end

          def get_class(assigns, default), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :get_class, 2}, _} = resolve(code)
    end

    test "resolves zero-arity function call" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <%= get_ti|me() %>
            """
          end

          def get_time(), do: nil
        end
      ]

      assert {:ok, {:call, MyLiveView, :get_time, 0}, _} = resolve(code)
    end

    test "resolves function in pipe expression inside curly braces" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <div :for={item <- @items}>
              {item.value |> to_stri|ng() |> String.upcase()}
            </div>
            """
          end
        end
      ]

      assert {:ok, {:call, Kernel, :to_string, 1}, _} = resolve(code)
    end
  end

  describe "resolve/2 inside a string" do
    test "does not resolve an ident inside a plain string (not interpolation)" do
      code = ~q[
        defmodule MyModule do
          def my_fun do
            "hello {wor|ld}"
          end
        end
      ]

      assert {:error, :in_string} = resolve(code)
    end

    test "resolves an ident inside string interpolation" do
      code = ~S[
        defmodule MyModule do
          def my_fun(world) do
            "hello #{wor|ld}"
          end
        end
      ]

      assert {:ok, {:variable, :world}, _} = resolve(code)
    end
  end

  describe "resolve/2 within ~H sigil when phoenix_live_view is NOT available" do
    setup do
      patch(Engine.CodeIntelligence.Heex, :phoenix_component_available?, false)
      :ok
    end

    test "shorthand component notation does not resolve" do
      code = ~q[
        defmodule MyLiveView do
          use Phoenix.Component

          def render(assigns) do
            ~H"""
            <.but|ton>Click</.button>
            """
          end

          def button(assigns), do: nil
        end
      ]

      assert {:error, :not_found} = resolve(code)
    end
  end

  defp subject_module_uri do
    project()
    |> file_path(Path.join("lib", "my_module.ex"))
    |> Document.Path.ensure_uri()
  end

  defp subject_module(content) do
    uri = subject_module_uri()
    Document.new(uri, content, 1)
  end

  defp resolve(code, opts \\ []) do
    evaluate? = Keyword.get(opts, :evaluate, false)

    with {position, code} <- pop_cursor(code),
         :ok <- maybe_evaluate(code, evaluate?),
         document = subject_module(code),
         analysis = Forge.Ast.analyze(document),
         {:ok, resolved, range} <- Entity.resolve(analysis, position) do
      {:ok, resolved, decorate(document, range)}
    end
  end

  defp maybe_evaluate(_code, false), do: :ok

  defp maybe_evaluate(code, true) do
    capture_io(:stderr, fn ->
      Code.compile_string(code)
    end)

    :ok
  end
end
