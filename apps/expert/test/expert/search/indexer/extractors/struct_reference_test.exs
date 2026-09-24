defmodule Expert.Search.Indexer.Extractors.StructReferenceTest do
  use Expert.Test.ExtractorCase

  import ExUnit.CaptureLog

  alias Expert.Search.Indexer.Extractors.StructReference
  alias Forge.Search.Subject

  def index(source) do
    do_index(source, fn entry ->
      entry.type == :struct and entry.subtype == :reference
    end)
  end

  describe "recognizing structs" do
    test "in a naked reference" do
      {:ok, [struct], doc} =
        ~q[%MyStruct{}]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == "«%MyStruct{}»"
    end

    test "in a naked reference with fields" do
      {:ok, [struct], doc} =
        ~q[
        %MyStruct{name: "stinky", height: 184}
      ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S(«%MyStruct{name: "stinky", height: 184}»)
    end

    test "in a struct on the left side of a match" do
      {:ok, [struct], doc} =
        ~q[%MyStruct{} = variable]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == "«%MyStruct{}» = variable"
    end

    test "in a struct on the right side of a match" do
      {:ok, [struct], doc} =
        ~q[variable = %MyStruct{}]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == "variable = «%MyStruct{}»"
    end

    test "in an any-struct pattern" do
      Logger.put_module_level(StructReference, :error)
      on_exit(fn -> Logger.put_module_level(StructReference, Logger.level()) end)

      assert {{:ok, [], _}, ""} = with_log(fn -> ~q[%_{}] |> index() end)
    end

    test "in an any-struct pattern with binding" do
      Logger.put_module_level(StructReference, :error)
      on_exit(fn -> Logger.put_module_level(StructReference, Logger.level()) end)

      assert {{:ok, [], _}, ""} = with_log(fn -> ~q[%str_name{}] |> index() end)
    end

    test "in an any-struct match on the left side and struct on the right" do
      {:ok, [struct], doc} = ~q[%_{} = %MyStruct{}] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == "%_{} = «%MyStruct{}»"
    end

    test "in an any-struct match with binding on the left side and struct on the right" do
      {:ok, [struct], doc} = ~q[%str_name{} = %MyStruct{}] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == "%str_name{} = «%MyStruct{}»"
    end

    test "in a struct reference in params" do
      {:ok, [struct], doc} =
        ~q[
        def my_fn(%MyStruct{} = first) do
        end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[def my_fn(«%MyStruct{}» = first) do]
    end

    test "in an any-struct pattern in params" do
      assert {:ok, [], _doc} =
               ~q[
        def my_fn(%_{} = first) do
        end
        ]
               |> index()
    end

    test "in an any-struct pattern with binding in params" do
      assert {:ok, [], _doc} =
               ~q[
        def my_fn(%struct_name{} = first) do
        end
        ]
               |> index()
    end

    test "in nested struct references" do
      {:ok, [outer, inner], doc} =
        ~q[
        %OuterStruct{inner: %InnerStruct{}}
        ]
        |> index()

      assert outer.type == :struct
      assert outer.subtype == :reference
      assert outer.subject == Subject.module(OuterStruct)
      assert decorate(doc, outer.range) == ~S[«%OuterStruct{inner: %InnerStruct{}}»]

      assert inner.type == :struct
      assert inner.subtype == :reference
      assert inner.subject == Subject.module(InnerStruct)
      assert decorate(doc, inner.range) == ~S[%OuterStruct{inner: «%InnerStruct{}»}]
    end

    test "in map keys" do
      {:ok, [struct], doc} =
        ~q[%{%MyStruct{} => 3}]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[%{«%MyStruct{}» => 3}]
    end

    test "in map values" do
      {:ok, [struct], doc} =
        ~q[%{cool_struct: %MyStruct{}}]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[%{cool_struct: «%MyStruct{}»}]
    end

    test "in list elements" do
      {:ok, [struct], doc} =
        ~q([1, 2, %MyStruct{}])
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S([1, 2, «%MyStruct{}»])
    end

    test "in a imported call to struct/1 with an alias" do
      {:ok, [struct], doc} = ~q[
        defmodule Parent do
          struct = struct(MyStruct)
        end
      ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[  struct = «struct(MyStruct)»]
    end

    test "in a imported call to struct/1 with __MODULE__" do
      {:ok, [struct], doc} = ~q[
        defmodule Parent do
          struct = struct(__MODULE__)
        end
      ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct(__MODULE__)»]
    end

    test "in a imported call to struct!/1 with __MODULE__" do
      {:ok, [struct], doc} = ~q[
        defmodule Parent do
          struct = struct!(__MODULE__)
        end
      ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct!(__MODULE__)»]
    end

    test "in a imported call to struct/2 with an alias" do
      {:ok, [struct], doc} = ~q[
        defmodule Parent do
          struct = struct(MyStruct, foo: 3)
        end
      ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[  struct = «struct(MyStruct, foo: 3)»]
    end

    test "in a imported call to struct!/2 with an alias" do
      {:ok, [struct], doc} = ~q[
        defmodule Parent do
          struct = struct!(MyStruct, foo: 3)
        end
      ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[  struct = «struct!(MyStruct, foo: 3)»]
    end

    test "in a imported call to struct/2 with __MODULE__" do
      {:ok, [struct], doc} = ~q[
        defmodule Parent do
          struct = struct(__MODULE__, foo: 3)
        end
      ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct(__MODULE__, foo: 3)»]
    end

    test "is ignored if struct isn't imported" do
      assert {:ok, _, _} =
               ~q{
        defmodule Parent do

          import Kernel, except: [struct: 1]
          struct = struct(MyStruct)
               end
       }
               |> index()
    end

    test "in a fully qualified call to Kernel.struct/1" do
      {:ok, [struct], doc} = ~q[struct = Kernel.struct(MyStruct)] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[struct = «Kernel.struct(MyStruct)»]
    end

    test "in a fully qualified call to Kernel.struct/2" do
      {:ok, [struct], doc} = ~q[struct = Kernel.struct(MyStruct, foo: 3)] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyStruct)
      assert decorate(doc, struct.range) == ~S[struct = «Kernel.struct(MyStruct, foo: 3)»]
    end

    test "other functions named struct are not counted" do
      {:ok, [], _} = ~q[struct = Macro.struct(MyStruct)] |> index()
    end
  end

  describe "handling __MODULE__" do
    test "in a module attribute" do
      {:ok, [struct], doc} =
        ~q[
          defmodule MyModule do
            @attr %__MODULE__{}
          end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyModule)
      assert decorate(doc, struct.range) == ~S(  @attr «%__MODULE__{}»)
    end

    test "in handling a submodule" do
      {:ok, [struct], doc} =
        ~q[
          defmodule MyModule do
            @attr %__MODULE__.Submodule{}
          end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyModule.Submodule)
      assert decorate(doc, struct.range) == ~S(  @attr «%__MODULE__.Submodule{}»)
    end

    test "in a function definition" do
      {:ok, [struct], doc} =
        ~q[
          defmodule MyModule do
            def my_fn(%__MODULE__{}), do: :ok
          end
        ]
        |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(MyModule)
      assert decorate(doc, struct.range) == ~S[  def my_fn(«%__MODULE__{}»), do: :ok]
    end

    test "in a call to Kernel.struct/1" do
      {:ok, [struct], doc} = ~q[
         defmodule Parent do
           struct = struct(__MODULE__)
         end
        ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct(__MODULE__)»]
    end

    test "in a call to Kernel.struct!/1" do
      {:ok, [struct], doc} = ~q[
         defmodule Parent do
           struct = struct!(__MODULE__)
         end
        ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct!(__MODULE__)»]
    end

    test "in a call to Kernel.struct/2" do
      {:ok, [struct], doc} = ~q[
         defmodule Parent do
           struct = struct(__MODULE__, foo: 3)
         end
        ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct(__MODULE__, foo: 3)»]
    end

    test "in a call to Kernel.struct!/2" do
      {:ok, [struct], doc} = ~q[
         defmodule Parent do
           struct = struct!(__MODULE__, foo: 3)
         end
        ] |> index()

      assert struct.type == :struct
      assert struct.subtype == :reference
      assert struct.subject == Subject.module(Parent)
      assert decorate(doc, struct.range) == ~S[  struct = «struct!(__MODULE__, foo: 3)»]
    end
  end

  describe "when aliases can't be expanded" do
    test "a fully qualified call to Kernel.struct/1 is ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = Kernel.struct(unquote(__MODULE__))
         end
        ] |> index()
    end

    test "a fully qualified call to Kernel.struct/2 is ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = Kernel.struct(unquote(__MODULE__), foo: 3)
         end
        ] |> index()
    end

    test "a call to struct!/2 is ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = struct!(unquote(__MODULE__), foo: 3)
         end
        ] |> index()
    end

    test "a call to struct!/1 is ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = struct!(unquote(__MODULE__))
         end
        ] |> index()
    end

    test "a call to struct/1 is ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = struct(unquote(__MODULE__))
         end
        ] |> index()
    end

    test "a call to struct/2 is ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = struct(unquote(__MODULE__), foo: 3)
         end
        ] |> index()
    end

    test "a reference ignored" do
      assert {:ok, [], _} = ~q[
         defmodule Parent do
           struct = %unquote(__MODULE__){}
         end
        ] |> index()
    end
  end
end
