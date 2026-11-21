# Adapted from gp-pereira/refactorex.
# Copyright (c) 2024 Gabriel Pereira. MIT licensed; see THIRD_PARTY_NOTICES.md.

defmodule Expert.Refactor.Function do
  import Sourceror.Identifier

  alias Expert.Refactor.Module
  alias Expert.Refactor.NameCache
  alias Sourceror.Zipper

  def definition?(node)
  def definition?({_, _, nil}), do: false
  def definition?({:def, _, _}), do: true
  def definition?({:defp, _, _}), do: true
  def definition?(_node), do: false

  def anonymous?(node)
  def anonymous?({_, _, nil}), do: false
  def anonymous?({:&, _, [i]}) when is_number(i), do: false
  def anonymous?({:&, _, _}), do: true
  def anonymous?({:fn, _, _}), do: true
  def anonymous?(_), do: false

  def call?(node)
  def call?({:/, _, [_, {:__block__, _, [_]}]}), do: true
  def call?({_, meta, _} = node), do: !!meta[:closing] and is_call(node)
  def call?(_), do: false

  def find_definitions(%{node: {:/, _, _}} = zipper),
    do: find_definitions(Zipper.down(zipper))

  def find_definitions(%{node: {name, _, args} = node} = zipper) do
    num_args =
      case Zipper.up(zipper) do
        %{node: {:/, _, [_, {:__block__, _, [num_args]}]}} ->
          num_args

        %{node: {:|>, _, [_, ^node]}} ->
          length(args) + 1

        _ ->
          if args, do: length(args), else: 0
      end

    zipper
    |> Module.find_in_scope(fn
      node ->
        cond do
          not definition?(node) ->
            false

          not match?({^name, _, _}, actual_header(node)) ->
            false

          true ->
            {min, max} = range_of_args(node)
            min <= num_args and num_args <= max
        end
    end)
  end

  def actual_header({_, _, [{:when, _, [header, _]} | _]}), do: header
  def actual_header({_, _, [header | _]}), do: header

  def range_of_args(definition) do
    case actual_header(definition) do
      {_, _, nil} ->
        {0, 0}

      {_, _, args} ->
        {
          Enum.count(args, &(not match?({:\\, _, _}, &1))),
          length(args)
        }
    end
  end

  def new_private_function(zipper, name, args, body) do
    private_function =
      {:defp, [do: [], end: []],
       [
         case unpin_args(args) do
           [{:when, _, [args, guard]} | other_args] ->
             {:when, [], [{name, [], [args | other_args]}, guard]}

           {:when, _, [{_, _, args}, guard]} ->
             {:when, [], [{name, [], args}, guard]}

           args ->
             {name, [], args}
         end,
         [{{:__block__, [], [:do]}, body}]
       ]}

    Module.place_node(zipper, private_function, &length/1)
  end

  def next_available_function_name(zipper, base_name) do
    NameCache.consume_name_or(fn ->
      Module.next_available_name(
        zipper,
        base_name,
        &definition?/1,
        fn definition ->
          {name, _, _} = actual_header(definition)
          name
        end
      )
    end)
  end

  def go_to_block(zipper) do
    zipper
    |> Zipper.down()
    |> Zipper.right()
    |> Zipper.down()
  end

  defp unpin_args(args) do
    args
    |> Zipper.zip()
    |> Zipper.traverse(fn
      %{node: {:^, _, [arg]}} = zipper ->
        Zipper.update(zipper, fn _ -> arg end)

      zipper ->
        zipper
    end)
    |> Zipper.node()
  end
end
