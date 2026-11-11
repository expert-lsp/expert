defmodule ExpertHEEx.Test.Declarations do
  @moduledoc false

  def component(attrs, slots, opts \\ []),
    do: Map.merge(%{kind: :def, attrs: attrs, slots: slots, line: 1}, Map.new(opts))

  def attr(name, type, opts \\ []) do
    Map.merge(
      %{name: name, type: type, opts: [], required: false, doc: nil, line: 1, slot: nil},
      Map.new(opts)
    )
  end

  def slot(name, opts \\ []) do
    Map.merge(
      %{
        name: name,
        opts: [],
        required: false,
        doc: nil,
        line: 1,
        attrs: [],
        validate_attrs: true
      },
      Map.new(opts)
    )
  end
end

defmodule ExpertHEEx.Test.Components do
  @moduledoc false

  import ExpertHEEx.Test.Declarations

  def __components__ do
    %{
      button:
        component(
          [
            attr(:type, :string, doc: "The button type.", line: 30),
            attr(:variant, :atom, required: true, line: 31),
            attr(:rest, :global)
          ],
          [slot(:inner_block)],
          line: 38
        ),
      input: component([attr(:field, :any, required: true)], []),
      table:
        component(
          [attr(:rows, :list, required: true)],
          [
            slot(:col,
              required: true,
              doc: "A column.",
              line: 40,
              attrs: [attr(:label, :string, required: true, doc: "The header.", line: 41)]
            ),
            slot(:inner_block)
          ]
        )
    }
  end

  @doc "Renders a button."
  def button(assigns), do: assigns

  @doc "Renders an input."
  def input(assigns), do: assigns

  @doc "Renders a table."
  def table(assigns), do: assigns

  def helper(value), do: value
end

defmodule ExpertHEEx.Test.Layouts do
  @moduledoc false

  def __components__, do: %{app: ExpertHEEx.Test.Declarations.component([], [])}

  def app(assigns), do: assigns

  def title(assigns), do: assigns

  def pair(left, right), do: {left, right}
end

defmodule ExpertHEEx.Test.Page do
  @moduledoc false

  import ExpertHEEx.Test.Declarations

  def __components__ do
    %{
      page:
        component(
          [
            attr(:live_action, :atom, required: true),
            attr(:title, :string, doc: "The title.")
          ],
          [slot(:inner_block)]
        ),
      header:
        component(
          [attr(:title, :string), attr(:live_action, :atom, required: true)],
          []
        )
    }
  end

  def page(assigns), do: assigns |> header() |> card() |> pair(:ok)

  defp header(assigns), do: assigns

  defp card(assigns), do: assigns

  defp pair(left, right), do: {left, right}
end
