defmodule Engine.Search.Indexer.StructureTest do
  use Engine.Test.ExtractorCase

  alias Forge.Search.Indexer.Entry

  def index(source) do
    case do_index(source, fn entry -> entry.type != :metadata end) do
      {:ok, results, _doc} -> {:ok, results}
      error -> error
    end
  end

  describe "blocks are correctly popped " do
    test "when multiple blocks end at once" do
      {:ok, results} =
        ~q[
          defmodule Parent do
            def function_1 do
              case something() do
                :ok -> :yep
                _ -> :nope
              end
            end

            defp function_2 do
            end
          end
        ]
        |> index()

      [module, public_function, private_function] =
        Enum.filter(results, fn entry ->
          entry.subtype == :definition
        end)

      assert public_function.block_id == module.id
      assert private_function.block_id == module.id
    end

    test "when an expression occurs after a block" do
      {:ok, [first_call, _, last_call]} =
        ~q[
          first_call()
          case something() do
            :ok -> :yep
            _ -> :nope
          end
          call()
        ]
        |> index()

      assert first_call.block_id == :root
      assert last_call.block_id == :root
    end
  end

  describe "callers are correctly identified" do
    setup do
      {:ok, file_path: Forge.Document.new("/foo/bar/baz.ex", "", 0).path}
    end

    test "when inside a function" do
      {:ok, results} =
        ~q[
        defmodule Orders do
          def checkout(cart) do
            Payments.charge(cart)

            if cart.valid? do
              Payments.charge(cart)
            end
          end

          def retry(cart) do
            Payments.charge(cart)
          end

          Payments.charge(:example)
        end
        ]
        |> index()

      refs =
        Enum.filter(results, fn %Entry{} = entry ->
          entry.subject == "Payments.charge/1" and entry.subtype == :reference
        end)

      assert Enum.map(refs, & &1.caller) == [
               "Orders.checkout/1",
               "Orders.checkout/1",
               "Orders.retry/1",
               "Orders"
             ]
    end

    test "file callers are restored before, between, and after modules", %{file_path: file_path} do
      {:ok, results} =
        ~q[
        Target.before_modules()

        defmodule Outer do
          Target.outer()

          defmodule Inner do
            Target.inner()
          end

          Target.outer_again()
        end

        Target.between_modules()

        defmodule Sibling do
          Target.sibling()
        end

        Target.after_modules()
        ]
        |> index()

      assert callers(results) == [
               {"Target.before_modules/0", file_path},
               {"Target.outer/0", "Outer"},
               {"Target.inner/0", "Outer.Inner"},
               {"Target.outer_again/0", "Outer"},
               {"Target.between_modules/0", file_path},
               {"Target.sibling/0", "Sibling"},
               {"Target.after_modules/0", file_path}
             ]

      modules = Enum.filter(results, &(&1.type == :module and &1.subtype == :definition))
      assert Enum.map(modules, & &1.subject) == [Outer, Outer.Inner, Sibling]
    end

    test "scripts without modules use the document path through nested blocks" do
      source = ~q"""
      Target.before_block()

      if true do
        Enum.each([], fn item -> Target.item(item) end)
      end

      Target.after_block()
      """

      document = Forge.Document.new("/project/build.exs", source, 0)
      assert {:ok, results} = Engine.Search.Indexer.Source.index(document.path, source)

      assert callers(results) == [
               {"Target.before_block/0", document.path},
               {"Enum.each/2", document.path},
               {"Target.item/1", document.path},
               {"Target.after_block/0", document.path}
             ]
    end

    test "keyword-do modules restore the parent and file callers on the same line", %{
      file_path: file_path
    } do
      {:ok, results} =
        ~q[
        defmodule Outer do
          defmodule Inner, do: Target.inner(); Target.outer()
        end

        defmodule Sibling, do: Target.sibling(); Target.file()
        ]
        |> index()

      assert callers(results) == [
               {"Target.inner/0", "Outer.Inner"},
               {"Target.outer/0", "Outer"},
               {"Target.sibling/0", "Sibling"},
               {"Target.file/0", file_path}
             ]
    end

    test "private functions and macros own calls while ordinary blocks inherit callers" do
      {:ok, results} =
        ~q[
        defmodule Owner do
          if true do
            Target.module_block()
          end

          defp private_call(), do: Target.private_call()

          defmacro public_macro do
            fn -> Target.macro_block() end
          end

          defmacrop private_macro(), do: Target.private_macro()

          Target.module_body()
        end
        ]
        |> index()

      assert callers(results) == [
               {"Target.module_block/0", "Owner"},
               {"Target.private_call/0", "Owner.private_call/0"},
               {"Target.macro_block/0", "Owner.public_macro/0"},
               {"Target.private_macro/0", "Owner.private_macro/0"},
               {"Target.module_body/0", "Owner"}
             ]
    end

    test "bodyless default headers own defaults without indexing the head as a call" do
      {:ok, results} =
        ~q[
        defmodule Owner do
          def run(value \\ Target.default())

          Target.after_header()

          def run(value) when is_binary(value), do: Target.run(value)

          Target.after_function()
        end
        ]
        |> index()

      assert callers(results) == [
               {"Target.default/0", "Owner.run/1"},
               {"Target.after_header/0", "Owner"},
               {"Kernel.is_binary/1", "Owner.run/1"},
               {"Target.run/1", "Owner.run/1"},
               {"Target.after_function/0", "Owner"}
             ]

      definitions = Enum.filter(results, &(&1.type == {:function, :public}))
      assert Enum.map(definitions, & &1.subject) == ["Owner.run/0", "Owner.run/1", "Owner.run/1"]
    end

    test "defaults in function and macro bodies use the full callable arity" do
      {:ok, results} =
        ~q[
        defmodule Owner do
          def run(value \\ Target.default()), do: Target.run(value)

          defmacro build(value \\ Target.macro_default()) do
            Target.build(value)
          end

          Target.module_body()
        end
        ]
        |> index()

      assert callers(results) == [
               {"Target.default/0", "Owner.run/1"},
               {"Target.run/1", "Owner.run/1"},
               {"Target.macro_default/0", "Owner.build/1"},
               {"Target.build/1", "Owner.build/1"},
               {"Target.module_body/0", "Owner"}
             ]
    end

    test "delegates retain their explicit caller without changing the module caller", %{
      file_path: file_path
    } do
      {:ok, results} =
        ~q[
        defmodule Owner do
          Target.before_delegate()

          defdelegate trim(value), to: String

          Target.after_delegate()
        end

        Target.file()
        ]
        |> index()

      assert callers(results) == [
               {"Target.before_delegate/0", "Owner"},
               {"String.trim/1", "Owner.trim/1"},
               {"Target.after_delegate/0", "Owner"},
               {"Target.file/0", file_path}
             ]
    end

    test "protocol and implementation bodies use their actual owning module", %{
      file_path: file_path
    } do
      {:ok, results} =
        ~q[
        defprotocol Action do
          Target.protocol_body()

          def run(value)

          Target.after_header()
        end

        Target.between_declarations()

        defimpl Action, for: Atom do
          Target.implementation_body()

          def run(value), do: Target.run(value)

          Target.after_function()
        end

        Target.file()
        ]
        |> index()

      assert callers(results) == [
               {"Target.protocol_body/0", "Action"},
               {"Target.after_header/0", "Action"},
               {"Target.between_declarations/0", file_path},
               {"Target.implementation_body/0", "Action.Atom"},
               {"Target.run/1", "Action.Atom.run/1"},
               {"Target.after_function/0", "Action.Atom"},
               {"Target.file/0", file_path}
             ]

      assert Enum.any?(results, &(&1.type == :module and &1.subject == Action.Atom))
    end

    test "keyword-do protocol boundaries restore file callers", %{file_path: file_path} do
      {:ok, results} =
        ~q[
        defprotocol Action, do: Target.protocol_body(); Target.after_protocol()
        ]
        |> index()

      assert callers(results) == [
               {"Target.protocol_body/0", "Action"},
               {"Target.after_protocol/0", file_path}
             ]
    end

    test "keyword-do implementations own their calls and restore the file caller on the same line",
         %{
           file_path: file_path
         } do
      {:ok, results} =
        ~q[
        Target.before_implementation()

        defimpl Action, for: Atom, do: Target.implementation(); Target.after_implementation()
        ]
        |> index()

      assert callers(results) == [
               {"Target.before_implementation/0", file_path},
               {"Target.implementation/0", "Action.Atom"},
               {"Target.after_implementation/0", file_path}
             ]
    end

    test "keyword-do implementations resolve aliases and restore the enclosing module caller", %{
      file_path: file_path
    } do
      {:ok, results} =
        ~q[
        defmodule Outer do
          alias Example.Action
          alias Example.Record

          defimpl Action, for: Record, do: (
            Target.implementation()
            def run(value), do: Target.run(value)
            Target.after_function()
          )

          Target.outer()
        end

        Target.file()
        ]
        |> index()

      assert callers(results) == [
               {"Target.implementation/0", "Example.Action.Example.Record"},
               {"Target.run/1", "Example.Action.Example.Record.run/1"},
               {"Target.after_function/0", "Example.Action.Example.Record"},
               {"Target.outer/0", "Outer"},
               {"Target.file/0", file_path}
             ]

      assert Enum.any?(
               results,
               &(&1.type == :module and &1.subject == Example.Action.Example.Record)
             )
    end
  end

  defp callers(results) do
    results
    |> Enum.filter(&(&1.type == {:function, :usage} and &1.subtype == :reference))
    |> Enum.map(&{&1.subject, &1.caller})
  end
end
