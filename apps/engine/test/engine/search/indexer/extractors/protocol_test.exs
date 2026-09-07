defmodule Engine.Search.Indexer.Extractors.ProtocolTest do
  use Engine.Test.ExtractorCase

  def index(source) do
    do_index(source, &match?({:protocol, _}, &1.type))
  end

  describe "indexing protocol definitions" do
    test "works" do
      {:ok, [protocol], doc} =
        ~q[
          defprotocol Something do
            def activate(thing, environment)
          end
        ]
        |> index()

      assert protocol.type == {:protocol, :definition}
      assert protocol.subtype == :definition
      assert protocol.subject == Something

      expected_block = ~q[
      «defprotocol Something do
        def activate(thing, environment)
      end»
      ]t

      assert decorate(doc, protocol.range) == "defprotocol «Something» do"
      assert decorate(doc, protocol.block_range) == expected_block
    end
  end

  describe "indexing protocol implementations" do
    test "keyword-do implementations have declaration and block ranges without the following expression" do
      source = ~q[
      defimpl Action, for: Atom, do: Target.run(); Target.after_implementation()
      ]

      assert {:ok, entries, document} = index_everything(source)
      definitions = Enum.filter(entries, &(&1.subtype == :definition))
      assert [implementation, module] = definitions
      assert implementation.type == {:protocol, :implementation}
      assert implementation.subject == Action
      assert module.type == :module
      assert module.subject == Action.Atom
      assert extract(document, implementation.range) == "defimpl Action, for: Atom, do:"

      assert extract(document, implementation.block_range) ==
               "defimpl Action, for: Atom, do: Target.run()"

      assert module.range == implementation.range
      assert module.block_range == implementation.block_range
    end

    test "works" do
      {:ok, [protocol], doc} =
        ~q[
          defimpl Something, for: Atom do
            def my_impl(atom, _opts) do
              to_string(atom)
            end
          end
        ]
        |> index()

      assert protocol.type == {:protocol, :implementation}
      assert protocol.subtype == :definition
      assert protocol.subject == Something

      expected_block =
        ~q[
        «defimpl Something, for: Atom do
          def my_impl(atom, _opts) do
            to_string(atom)
          end
        end»
        ]t
        |> String.trim_trailing()

      assert decorate(doc, protocol.range) == "«defimpl Something, for: Atom do»"
      assert decorate(doc, protocol.block_range) == expected_block
    end
  end

  test "__MODULE__ is correct in implementations" do
    {:ok, [protocol], doc} =
      ~q[
       defimpl Something, for: Atom do
         def something(atom) do
           __MODULE__
         end
       end
      ]
      |> index()

    assert protocol.type == {:protocol, :implementation}
    assert protocol.subtype == :definition
    assert protocol.subject == Something

    expected_block = ~q[
      «defimpl Something, for: Atom do
        def something(atom) do
          __MODULE__
        end
      end»
      ]t

    assert decorate(doc, protocol.range) == "«defimpl Something, for: Atom do»"
    assert decorate(doc, protocol.block_range) == expected_block
  end

  test "indexes all parts of a protocol" do
    {:ok, extracted, doc} =
      ~q[
       defimpl Protocol, for: Target do
         def function(arg) do
            __MODULE__
         end
       end
      ]
      |> index_everything()

    [
      protocol_impl_def,
      module_def,
      protocol_ref,
      target_ref,
      function_def,
      proto_module_ref
    ] = extracted

    expected_block = ~q[
     «defimpl Protocol, for: Target do
       def function(arg) do
          __MODULE__
       end
     end»
    ]t

    assert protocol_impl_def.type == {:protocol, :implementation}
    assert protocol_impl_def.subtype == :definition
    assert protocol_impl_def.subject == Protocol
    assert decorate(doc, protocol_impl_def.range) =~ "«defimpl Protocol, for: Target do»"
    assert decorate(doc, protocol_impl_def.block_range) =~ expected_block

    assert module_def.type == :module
    assert module_def.subtype == :definition
    assert module_def.subject == Protocol.Target
    assert decorate(doc, module_def.range) =~ "«defimpl Protocol, for: Target do»"
    assert decorate(doc, module_def.block_range) =~ expected_block

    assert protocol_ref.type == :module
    assert protocol_ref.subtype == :reference
    assert protocol_ref.subject == Protocol
    assert decorate(doc, protocol_ref.range) =~ "defimpl «Protocol», "

    assert target_ref.type == :module
    assert target_ref.subtype == :reference
    assert target_ref.subject == Target
    assert decorate(doc, target_ref.range) =~ "defimpl Protocol, for: «Target» do"

    assert function_def.type == {:function, :public}

    assert proto_module_ref.type == :module
    assert proto_module_ref.subject == Protocol.Target
  end
end
