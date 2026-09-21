defmodule Expert.Search.Indexer.Extractors.ExUnitTest do
  use Expert.Test.ExtractorCase
  use Patch

  import Forge.Test.RangeSupport

  alias Expert.Search.Indexer.Extractors
  alias Expert.Search.Indexer.Source.Reducer

  @test_types [
    :ex_unit_setup,
    :ex_unit_setup_all,
    :ex_unit_test,
    :ex_unit_describe
  ]

  def index_definitions(source) do
    do_index(source, fn entry -> entry.type in @test_types and entry.subtype == :definition end, [
      Extractors.ExUnit
    ])
  end

  def index_with_structure(source) do
    do_index(source, fn entry -> entry.type != :metadata end, [
      Extractors.ExUnit,
      Extractors.Module
    ])
  end

  describe "finds setup" do
    test "in blocks without an argument" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup do
            :ok
          end
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup
      assert setup.subject == "SomeTest.setup/1"
      assert decorate(doc, setup.range) =~ "  «setup do»"
      assert decorate(doc, setup.block_range) =~ "  «setup do\n    :ok\n  end»"
    end

    test "in blocks with an argument" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup arg do
            :ok
          end
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup
      assert setup.subject == "SomeTest.setup/2"
      assert decorate(doc, setup.range) =~ "  «setup arg do»"
      assert decorate(doc, setup.block_range) =~ "  «setup arg do\n    :ok\n  end»"
    end

    test "as an atom" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup :other_function
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup
      assert setup.subject == "SomeTest.setup/1"
      refute setup.block_range
      assert decorate(doc, setup.range) =~ "  «setup :other_function»"
    end

    test "as a list of atoms" do
      {:ok, [setup], doc} =
        ~q{
        defmodule SomeTest do
          use ExUnit.Case
          setup [:other_function, :second_function]
        end
        }
        |> index_definitions()

      assert setup.type == :ex_unit_setup
      assert setup.subject == "SomeTest.setup/1"
      refute setup.block_range
      assert decorate(doc, setup.range) =~ "  «setup [:other_function, :second_function]»"
    end

    test "as a MF tuple" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup {OtherModule, :setup}
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup
      assert setup.subject == "SomeTest.setup/1"
      refute setup.block_range
      assert decorate(doc, setup.range) =~ "  «setup {OtherModule, :setup}»"
    end

    test "unless setup is a variable" do
      {:ok, [test], _doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          test "something" do
            setup = 3
            setup
          end
        end
        ]
        |> index_definitions()

      assert test.type == :ex_unit_test
    end
  end

  describe "finds setup_all" do
    test "as a block without an argument" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup_all do
            :ok
          end
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup_all
      assert setup.subject == "SomeTest.setup_all/1"
      assert decorate(doc, setup.range) =~ "  «setup_all do»"
      assert decorate(doc, setup.block_range) =~ "  «setup_all do\n    :ok\n  end"
    end

    test "as a block with an argument" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup_all arg do
            :ok
          end
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup_all
      assert setup.subject == "SomeTest.setup_all/2"
      assert decorate(doc, setup.range) =~ "  «setup_all arg do»"
      assert decorate(doc, setup.block_range) =~ "  «setup_all arg do\n    :ok\n  end"
    end

    test "as an atom" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup_all :other_function
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup_all
      assert setup.subject == "SomeTest.setup_all/1"
      refute setup.block_range

      assert decorate(doc, setup.range) =~ "  «setup_all :other_function»"
    end

    test "as a list of atoms" do
      {:ok, [setup], doc} =
        ~q{
        defmodule SomeTest do
          use ExUnit.Case
          setup_all [:other_function, :second_function]
        end
        }
        |> index_definitions()

      assert setup.type == :ex_unit_setup_all
      assert setup.subject == "SomeTest.setup_all/1"
      refute setup.block_range

      assert decorate(doc, setup.range) =~ "  «setup_all [:other_function, :second_function]»"
    end

    test "as a MF tuple" do
      {:ok, [setup], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          setup_all {OtherModule, :setup}
        end
        ]
        |> index_definitions()

      assert setup.type == :ex_unit_setup_all
      assert setup.subject == "SomeTest.setup_all/1"
      refute setup.block_range

      assert decorate(doc, setup.range) =~ "  «setup_all {OtherModule, :setup}»"
    end
  end

  describe "finds describe blocks" do
    test "with an empty block" do
      {:ok, [describe], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          describe "something" do
          end
        end
        ]
        |> index_definitions()

      assert describe.type == :ex_unit_describe
      assert describe.subtype == :definition
      assert decorate(doc, describe.range) =~ "  «describe \"something\" do»"
      assert decorate(doc, describe.block_range) =~ "  «describe \"something\" do\n  end»"
    end

    test "with tests" do
      {:ok, [describe, _test], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          describe "something" do
            test "something"
          end
        end
        ]
        |> index_definitions()

      assert describe.type == :ex_unit_describe
      assert describe.subtype == :definition

      assert decorate(doc, describe.range) =~ "  «describe \"something\" do»"

      assert decorate(doc, describe.block_range) =~
               ~s(  «describe "something" do\n    test "something"\n  end»)
    end
  end

  describe "finds tests" do
    test "when pending" do
      {:ok, [test], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          test "my test"
        end
        ]
        |> index_definitions()

      assert test.type == :ex_unit_test
      assert test.subject == "SomeTest.[\"my test\"]/1"
      refute test.block_range

      assert decorate(doc, test.range) =~ ~s[  «test "my test"»]
    end

    test "when they only have a block" do
      {:ok, [test], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          test "my test" do
          end
        end
        ]
        |> index_definitions()

      assert test.type == :ex_unit_test
      assert test.subject == "SomeTest.[\"my test\"]/2"

      assert decorate(doc, test.range) =~ ~s[  «test "my test" do»]
      assert decorate(doc, test.block_range) =~ ~s[  «test "my test" do\n  end»]
    end

    test "when they have a block and a context" do
      {:ok, [test], doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case
          test "my test", context do
          end
        end
        ]
        |> index_definitions()

      assert test.type == :ex_unit_test
      assert test.subject =~ "SomeTest.[\"my test\"]/3"

      expected_detail = "  «test \"my test\", context do»"
      assert decorate(doc, test.range) =~ expected_detail

      expected_block = "  «test \"my test\", context do\n  end»"
      assert decorate(doc, test.block_range) =~ expected_block
    end
  end

  describe "block structure" do
    test "describe contains tests" do
      {:ok, all_entries, _} =
        ~q[
         defmodule SomeTexst do
           use ExUnit.Case
           describe "outer" do
             test "my test", context do
             end
           end
         end
        ]
        |> index_with_structure()

      [module, describe, test] = Enum.filter(all_entries, &(&1.subtype == :definition))

      assert module.type == :module
      assert module.block_id == :root

      assert describe.type == :ex_unit_describe
      assert describe.block_id == module.id

      assert test.type == :ex_unit_test
      assert test.block_id == describe.id
    end
  end

  describe "things that it will miss" do
    test "quoted test cases" do
      {:ok, [], _} =
        ~q[
        quote do
         test unquote(test_name) do
         end
        end
        ]
        |> in_a_module()
        |> index_definitions()
    end
  end

  describe "recovers from invalid code" do
    test "with syntax errors" do
      assert {:ok, [], _doc} =
               ~q[
               defmodule SomeTest do
                 use ExUnit.Case
                 test "my test" do
                   assert true
               end
               ]
               |> index_definitions()
    end
  end

  describe "when ExUnit.Case is in scope" do
    test "indexes test/describe/setup" do
      {:ok, entries, _doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.Case

          setup do
            :ok
          end

          describe "some group" do
            test "my test" do
              :ok
            end
          end
        end
        ]
        |> index_definitions()

      types = Enum.map(entries, & &1.type)
      assert :ex_unit_setup in types
      assert :ex_unit_describe in types
      assert :ex_unit_test in types
    end
  end

  describe "when ExUnit.CaseTemplate is in scope" do
    defmodule MyCase do
      use ExUnit.CaseTemplate
    end

    test "indexes test/describe/setup when directly used" do
      {:ok, entries, _doc} =
        ~q[
        defmodule SomeTest do
          use ExUnit.CaseTemplate

          setup do
            :ok
          end

          describe "some group" do
            test "my test" do
              :ok
            end
          end
        end
        ]
        |> index_definitions()

      types = Enum.map(entries, & &1.type)
      assert :ex_unit_setup in types
      assert :ex_unit_describe in types
      assert :ex_unit_test in types
    end

    test "indexes test/describe/setup through a case template" do
      patch(Reducer, :exunit_module?, fn _reducer, module -> module == MyCase end)

      {:ok, entries, _doc} =
        ~q[
        defmodule SomeTest do
          use Expert.Search.Indexer.Extractors.ExUnitTest.MyCase

          setup do
            :ok
          end

          describe "some group" do
            test "my test" do
              :ok
            end
          end
        end
        ]
        |> index_definitions()

      types = Enum.map(entries, & &1.type)
      assert :ex_unit_setup in types
      assert :ex_unit_describe in types
      assert :ex_unit_test in types
    end
  end

  describe "when ExUnit.Case is not in scope" do
    test "does not index" do
      {:ok, entries, _doc} =
        ~q[
        defmodule NotATest do
          def setup(arg), do: arg

          def describe(name) do
            name
          end

          def test(name, _context) do
            name
          end
        end
        ]
        |> index_definitions()

      assert entries == []
    end
  end
end
