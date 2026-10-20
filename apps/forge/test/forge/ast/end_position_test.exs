defmodule Forge.Ast.EndPositionTest do
  use ExUnit.Case, async: true

  alias Forge.Ast
  alias Forge.Ast.EndPosition

  @sources Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__))

  defp subterms(quoted) do
    {_, terms} =
      Macro.prewalk(quoted, [], fn
        {_, _, _} = node, acc -> {node, [node | acc]}
        {_, _} = pair, acc -> {pair, [pair | acc]}
        node, acc -> {node, acc}
      end)

    [quoted | terms]
  end

  test "ends every subterm where Sourceror does" do
    assert length(@sources) > 50

    checked =
      for path <- @sources, reduce: 0 do
        checked ->
          {:ok, quoted, _comments} = path |> File.read!() |> Ast.from()

          for term <- subterms(quoted),
              default <- [[line: -1, column: -1], [line: 1, column: 1]] do
            assert EndPosition.of(term, default) == Sourceror.get_end_position(term, default),
                   "#{path}: #{inspect(term, limit: 8)}"
          end

          checked + 1
      end

    assert checked == length(@sources)
  end

  test "ranges definitions where Sourceror does" do
    definitions =
      for path <- @sources,
          {:ok, quoted, _comments} = path |> File.read!() |> Ast.from(),
          {form, _, args} = term <- subterms(quoted),
          form in [:def, :defp, :defmacro, :defmacrop, :defmodule, :defprotocol, :defimpl],
          is_list(args),
          do: term

    assert length(definitions) > 1000

    for term <- definitions do
      expected =
        case Sourceror.get_range(term) do
          %{start: [line: sl, column: sc], end: [line: el, column: ec]} -> {{sl, sc}, {el, ec}}
          nil -> nil
        end

      assert Forge.Ast.Range.positions(term) == expected, inspect(term, limit: 8)
    end
  end
end
