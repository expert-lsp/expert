defmodule ExpertHEExTest do
  use ExUnit.Case, async: true

  import ExpertExtensions.Test.Request, only: [range: 2]

  alias ExpertExtensions.Test.Request

  describe "HEEx documents" do
    test "keeps interpolations at their template position and blanks everything else" do
      request = request("<div class={cl|}>{@name}</div>")

      assert %{delegate: %{source: "            cl;  @name;      "}} =
               ExpertHEEx.complete(request)
    end

    test "counts each codepoint as one column" do
      request = request("<p>é😀 {cl|}</p>")
      assert %{delegate: %{source: source}} = ExpertHEEx.complete(request)
      assert source == "       cl;    "

      assert ExpertHEEx.complete(request("<p>é</p><%= Enum.ma| %>")) ==
               ExpertHEEx.complete(request("<p>e</p><%= Enum.ma| %>"))
    end

    test "ends an interpolation at its brace after non-ASCII text" do
      assert %{delegate: %{source: source}} =
               ExpertHEEx.complete(request(~S'<p>{"é" <> na|}</p>'))

      assert String.trim(source) == ~S|"é" <> na;|
    end

    test "keeps EEx tags and interpolations inside them" do
      request = request("<%= for x <- @xs do %><b>{x.na|}</b><% end %>")

      assert %{delegate: %{source: source}} = ExpertHEEx.complete(request)
      assert source == "    for x <- @xs do ;     x.na;       end ; "
      assert {:ok, _quoted} = Code.string_to_quoted(source)
    end

    test "reads nested braces and strings as part of the interpolation" do
      request = request(~S'<p>{f(%{a: "}"}, b|)}</p>')

      assert %{delegate: %{source: source}} = ExpertHEEx.complete(request)
      assert String.trim(source) == ~S|f(%{a: "}"}, b);|
    end

    test "reads braces in sigils as part of the interpolation" do
      request = request(~S'<p>{~s(foo}bar) <> Str|}</p>')

      assert %{delegate: %{source: source}} = ExpertHEEx.complete(request)
      assert String.trim(source) == "~s(foo}bar) <> Str;"
    end

    test "treats braces as text in quoted attributes, comments, and raw text tags" do
      source =
        ~S'<p title="{a}"><!-- {b} --></p><script>{c}</scriptx>{d}</script><style>{e}</style>{f|}'

      assert %{delegate: %{source: masked}} = ExpertHEEx.complete(request(source))
      assert String.trim(masked) == "f;"
    end

    test "completes inside an unclosed interpolation" do
      assert %{delegate: %{source: "    fo;"}} = ExpertHEEx.complete(request("<p>{fo|"))
    end

    test "returns no completions in HTML" do
      assert %{mode: :override, items: [], incomplete?: false} =
               ExpertHEEx.complete(request("<div cla|ss={@x}></div>"))
    end
  end

  describe "~H sigils" do
    @module """
    defmodule Page do
      def render(assigns) do
        ~H\"\"\"
        <p>{na|}</p>
        \"\"\"
      end
    end
    """

    test "masks the sigil and keeps the surrounding code" do
      request = sigil_request(@module)

      assert %{delegate: %{source: source}} = ExpertHEEx.complete(request)

      assert source ==
               Enum.join(
                 [
                   "defmodule Page do",
                   "  def render(assigns) do",
                   "         ",
                   "        na;    ",
                   "       ",
                   "  end",
                   "end",
                   ""
                 ],
                 "\n"
               )
    end

    test "handles sigils on one line" do
      request = sigil_request(~S'def render(assigns), do: ~H"<p>{na|}</p>"')

      assert %{delegate: %{source: masked}} = ExpertHEEx.complete(request)
      assert masked == "def render(assigns), do:        na;     "
    end

    test "returns no completions in the HTML of a sigil" do
      request = @module |> String.replace("<p>{na|}", "<p|>{na}") |> sigil_request()

      assert %{mode: :override, items: []} = ExpertHEEx.complete(request)
    end
  end

  describe "function components" do
    alias ExpertHEEx.Test.Components
    alias ExpertHEEx.Test.Layouts

    @scope [
      imports: [
        {Components, :button, 1},
        {Components, :input, 1},
        {Components, :helper, 1},
        {Components, :table, 1},
        {Layouts, :pair, 2},
        {Kernel, :hd, 1}
      ],
      aliases: %{[:Layouts] => Layouts}
    ]

    test "completes the imported functions of arity 1, other than those of Kernel, after `<.`" do
      assert %{mode: :override, items: items} = complete("<div><.bu|")
      assert labels(items) == ["button", "helper", "input", "table"]

      assert %{
               kind: :function,
               insert_text: "button",
               detail: "ExpertHEEx.Test.Components.button/1",
               documentation: "Renders a button.",
               range: %{start: %{line: 2, character: 8}, end: %{line: 2, character: 10}}
             } = Enum.find(items, &(&1.label == "button"))
    end

    test "completes the public functions of arity 1 of an aliased module" do
      assert %{items: items} = complete("<Layouts.|")
      assert labels(items) == ["app", "title"]
    end

    test "completes the functions of arity 1 of the current module, private ones included" do
      assert %{items: items} = page_request(~S'~H"<.ca|"') |> ExpertHEEx.complete()

      assert labels(items) == ["card", "header", "page"]
      assert %{detail: "ExpertHEEx.Test.Page.card/1"} = Enum.find(items, &(&1.label == "card"))
    end

    test "does not create atoms for unknown module names" do
      suffix = System.unique_integer([:positive])
      current = "Unknown#{suffix}"
      remote = "Unknown#{suffix}.Components"

      refute existing_atom?("Elixir." <> current)
      refute existing_atom?("Elixir." <> remote)

      assert %{items: []} =
               ~S'~H"<.ca|"'
               |> sigil_request(module: current)
               |> ExpertHEEx.complete()

      assert %{items: []} = complete("<#{remote}.|")

      refute existing_atom?("Elixir." <> current)
      refute existing_atom?("Elixir." <> remote)
    end

    test "completes the assigns of the component around the cursor after `@`" do
      assert %{mode: :override, items: items} =
               ~S'~H"<p>{@li|}</p>"' |> page_request() |> ExpertHEEx.complete()

      assert [
               %{label: "live_action", kind: :variable, detail: "attr :atom (required)"},
               %{label: "title", detail: "attr :string", documentation: "The title."},
               %{label: "inner_block", detail: "slot"}
             ] = items
    end

    test "completes the attributes of a private component of the current module" do
      assert %{items: [%{label: "live_action"}, %{label: "title"}]} =
               ~S'~H"<.header |"' |> page_request() |> ExpertHEEx.complete()
    end

    test "completes the slots of the enclosing component after `<:`" do
      assert %{items: [%{label: "col", kind: :property, detail: "slot (required)"} = col]} =
               complete("<.table rows={[]}>\n  <div>\n    <:c|")

      assert col.documentation == "A column."
      assert col.range == range({4, 7}, {4, 8})
    end

    test "completes the attributes of a slot" do
      assert %{items: [%{label: "label", snippet: ~S(label="$1"), documentation: "The header."}]} =
               complete("<.table rows={[]}><:col |")
    end

    test "returns no slots outside of a component" do
      assert %{items: []} = complete("<.table rows={[]}></.table><:|")
    end

    test "counts a bare attribute as present" do
      assert %{items: [%{label: "type"}]} = complete("<.button variant |")
    end

    test "reads the attributes of a tag that spans lines" do
      assert %{items: [%{label: "type"}]} = complete("<.button\n  variant={:primary}\n |")
    end

    test "completes a tag name in the middle of the name" do
      assert %{items: items} = complete("<.bu|tton></.button>")
      assert %{range: range} = Enum.find(items, &(&1.label == "button"))
      assert range == range({2, 3}, {2, 5})
    end

    test "delegates module names to Elixir completion" do
      assert %{delegate: %{source: "     \n Lay\n   "}} = complete("<Lay|")
    end

    test "completes attributes, required ones first" do
      assert %{items: [variant, type]} = complete("<.button |")
      assert %{label: "variant", snippet: "variant={$1}", detail: ":atom (required)"} = variant

      assert %{
               label: "type",
               snippet: ~S(type="$1"),
               detail: ":string",
               documentation: "The button type."
             } = type
    end

    test "skips attributes that the tag already has" do
      assert %{items: [%{label: "variant", range: range}]} =
               complete(~S(<.button type="submit" va|))

      assert range == range({2, 24}, {2, 26})
    end

    test "completes components in a ~H sigil" do
      request = sigil_request(~S'def render(assigns), do: ~H"<.bu|"', @scope)

      assert %{items: items} = ExpertHEEx.complete(request)
      assert labels(items) == ["button", "helper", "input", "table"]
    end

    test "returns no completions for HTML elements and closing tags" do
      assert %{mode: :override, items: []} = complete("<di|")
      assert %{mode: :override, items: []} = complete("<.button></.but|")
    end

    test "completes components after non-ASCII text in a sigil on one line" do
      request = sigil_request(~S'def render(assigns), do: ~H"<p>é</p><.bu|"', @scope)

      assert %{items: items} = ExpertHEEx.complete(request)
      assert %{range: range} = Enum.find(items, &(&1.label == "button"))
      assert range == range({1, 39}, {1, 41})
    end

    defp complete(source), do: source |> template_request(@scope) |> ExpertHEEx.complete()

    defp page_request(sigil),
      do: sigil_request("def page(assigns), do: #{sigil}", module: "ExpertHEEx.Test.Page")

    defp labels(items), do: items |> Enum.map(& &1.label) |> Enum.sort()

    defp existing_atom?(name) do
      String.to_existing_atom(name)
      true
    rescue
      ArgumentError -> false
    end
  end

  describe "hover" do
    alias ExpertHEEx.Test.Components

    @scope [
      imports: [{Components, :button, 1}, {Components, :table, 1}],
      aliases: %{}
    ]

    test "describes a component with its docs" do
      assert %{contents: contents, range: range} = hover("<.butt|on type=\"submit\" />")
      assert contents == "`ExpertHEEx.Test.Components.button/1`\n\nRenders a button."
      assert range == range({2, 2}, {2, 9})
    end

    test "describes the component of a closing tag" do
      assert %{range: range} = hover("<.button></.butt|on>")
      assert range == range({2, 12}, {2, 19})
    end

    test "lists the declarations of a component without docs" do
      request = page_request(~S'~H"<.head|er />"')

      assert %{contents: contents} = ExpertHEEx.hover(request)

      assert contents ==
               Enum.join(
                 [
                   "`ExpertHEEx.Test.Page.header/1`",
                   "**Attributes**\n\n* `title` `:string`\n* `live_action` `:atom` (required)"
                 ],
                 "\n\n"
               )
    end

    test "describes a slot with its attributes" do
      assert %{contents: contents} = hover("<.table rows={[]}><:co|l label=\"Name\">")

      assert contents ==
               Enum.join(
                 [
                   "`:col` slot (required)",
                   "A column.",
                   "**Attributes**\n\n* `label` `:string` (required) - The header."
                 ],
                 "\n\n"
               )
    end

    test "describes an attribute" do
      assert %{contents: "`variant` `:atom` (required)", range: range} =
               hover("<.button vari|ant={:primary} />")

      assert range == range({2, 10}, {2, 17})
    end

    test "describes an attribute of a slot" do
      assert %{contents: "`label` `:string` (required)\n\nThe header."} =
               hover("<.table rows={[]}><:col lab|el=\"Name\">")
    end

    test "returns nil for HTML elements and code" do
      assert nil == hover("<di|v></div>")
      assert nil == hover("<p>{@na|me}</p>")
    end

    defp hover(source), do: source |> template_request(@scope) |> ExpertHEEx.hover()
  end

  describe "definition" do
    alias ExpertHEEx.Test.Components

    @scope [
      imports: [{Components, :button, 1}, {Components, :helper, 1}, {Components, :table, 1}],
      aliases: %{}
    ]

    test "locates the declaration of a component" do
      assert [%{path: path, range: range}] = definition("<.butt|on />")
      assert String.ends_with?(path, "test/support/components.ex")
      line = Components.__components__().button.line
      assert range == range({line, 1}, {line, 1})
    end

    test "locates the docs of a function without a declaration" do
      assert [%{range: %{start: %{line: line}}}] = definition("<.help|er />")
      assert line == line_of(Components, "def helper(")
    end

    test "locates the declarations of slots and attributes" do
      %{table: table, button: button} = Components.__components__()
      [%{line: col, attrs: [%{line: label}]} | _slots] = table.slots
      variant = Enum.find(button.attrs, &(&1.name == :variant)).line

      assert [%{range: %{start: %{line: ^col}}}] = definition("<.table rows={[]}><:co|l>")
      assert [%{range: %{start: %{line: ^label}}}] = definition("<.table rows={[]}><:col lab|el>")
      assert [%{range: %{start: %{line: ^variant}}}] = definition("<.button vari|ant />")
    end

    test "returns no locations for HTML elements" do
      assert [] = definition("<di|v></div>")
    end

    defp definition(source),
      do: source |> template_request(@scope) |> ExpertHEEx.definition()

    defp line_of(module, text) do
      module.module_info(:compile)[:source]
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_index(&String.contains?(&1, text))
      |> Kernel.+(1)
    end
  end

  describe "resolve" do
    test "delegates the Elixir code under the cursor to the masked source" do
      assert %{delegate: %{source: "    format(@date);    "}} =
               ExpertHEEx.resolve(request("<p>{forma|t(@date)}</p>"))

      assert %{delegate: %{source: masked}} =
               ~S'def render(assigns), do: ~H"<p>{forma|t(@date)}</p>"'
               |> sigil_request()
               |> ExpertHEEx.resolve()

      assert masked == "def render(assigns), do:        format(@date);     "
    end

    test "returns nil in the HTML" do
      assert nil == ExpertHEEx.resolve(request("<p cla|ss={@x}></p>"))
    end
  end

  test "publishes semantic metadata for HEEx documents and ~H sigils" do
    assert [{:elixir_semantic_metadata, [{:elixir_semantic_metadata_v1, metadata}]}] =
             ExpertHEEx.module_info(:attributes)
             |> Keyword.take([:elixir_semantic_metadata])

    assert %{contexts: contexts, scopes: %{heex: scope}} = metadata
    assert %{language_id: "phoenix-heex", scope: :heex} in contexts
    assert %{language_id: "heex", scope: :heex} in contexts
    assert %{sigil: "H", scope: :heex} in contexts

    assert scope.data == [
             expert: %{
               facets: %{
                 completion: [{ExpertHEEx, :complete, 1}],
                 hover: [{ExpertHEEx, :hover, 1}],
                 definition: [{ExpertHEEx, :definition, 1}],
                 resolve: [{ExpertHEEx, :resolve, 1}]
               }
             }
           ]
  end

  defp request(source),
    do: Request.build(source, language_id: "phoenix-heex", scope: :heex)

  defp sigil_request(source, opts \\ []),
    do: Request.build(source, [sigil: "H", scope: :heex] ++ opts)

  defp template_request(template, opts),
    do: sigil_request(~s(~H"""\n) <> template <> ~s(\n"""), opts)
end
