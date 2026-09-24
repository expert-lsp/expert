defmodule Expert.Search.Indexer.Extractors.ProtocolTest do
  use Expert.Test.ExtractorCase

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
