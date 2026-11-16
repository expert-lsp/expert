defmodule Expert.Search.Indexer.Extractors.HeexTest do
  use Expert.Test.ExtractorCase

  def index_functions(source) do
    do_index(source, fn entry ->
      entry.type == {:function, :usage} and entry.subtype == :reference and
        entry.subject != "Parent.sigil_H/2"
    end)
  end

  def index_type(source, type) do
    do_index(source, fn entry -> entry.type == type and entry.subtype == :reference end)
  end

  describe "embedded code" do
    test "calls in interpolations are references" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          <p class={classes(@kind)}>
            {Other.format(@value, %{a: 1})}
          </p>
          """
        end
      end
      ]

      {:ok, [classes, format], doc} = index_functions(code)

      assert classes.subject == "Parent.classes/1"
      assert "classes(@kind)" = extract(doc, classes.range)

      assert format.subject == "Other.format/2"
      assert "Other.format(@value, %{a: 1})" = extract(doc, format.range)
    end

    test "calls in EEx blocks are references" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          <%= for item <- items(@list) do %>
            <%= if visible?(item) do %>
              {label(item)}
            <% else %>
              {fallback()}
            <% end %>
          <% end %>
          """
        end
      end
      ]

      {:ok, references, doc} = index_functions(code)

      assert [
               {"Parent.items/1", "items(@list)"},
               {"Parent.visible?/1", "visible?(item)"},
               {"Parent.label/1", "label(item)"},
               {"Parent.fallback/0", "fallback()"}
             ] = Enum.map(references, &{&1.subject, extract(doc, &1.range)})
    end

    test "multi-line code keeps its document positions" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          {Enum.map(
            @items,
            &render_item/1
          )}
          """
        end
      end
      ]

      {:ok, references, doc} = index_functions(code)

      assert [map, capture] = references
      assert map.subject == "Enum.map/2"
      assert map.range.start.line == 4
      assert map.range.end.line == 7
      assert capture.subject == "Parent.render_item/1"
      assert "render_item/1" = extract(doc, capture.range)
    end

    test "assigns aren't module attribute references" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          <p>{@title}</p>
          """
        end
      end
      ]

      assert {:ok, [], _doc} = index_type(code, :module_attribute)
    end

    test "structs in templates are references" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          <div data-form={%My.Form{}}></div>
          """
        end
      end
      ]

      {:ok, [reference], doc} = index_type(code, :struct)
      assert reference.subject == My.Form
      assert "%My.Form{}" = extract(doc, reference.range)
    end

    test "code that parses is indexed when other code in the template doesn't" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          <p>{label(@title)}</p>
          <p>{broken(}</p>
          """
        end
      end
      ]

      {:ok, [reference], doc} = index_functions(code)
      assert reference.subject == "Parent.label/1"
      assert "label(@title)" = extract(doc, reference.range)
    end

    test "code in broken templates isn't indexed" do
      code = ~q[
      defmodule Parent do
        def render(assigns) do
          ~H"""
          <%= foo(
          """
        end
      end
      ]

      assert {:ok, [], _doc} = index_functions(code)
    end
  end
end
