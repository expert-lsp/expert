defmodule Forge.Ast.Detection.StringTest do
  use Forge.Test.DetectionCase,
    for: Forge.Ast.Detection.String,
    assertions: [[:strings, :*]],
    skip: [
      [:doc, :*],
      [:keyword, :single_line],
      # we skip other tests that have strings in them
      [:keyword, :multi_line],
      [:module_doc, :*]
    ],
    variations: [
      :function_arguments,
      :function_body,
      :function_call,
      :match,
      :module
    ]

  test "is detected if a string is keyword values" do
    assert_detected ~q/def func(string: "v«alue»", atom: :value2, int: 6, float: 2.0, list: [1, 2], tuple: {3, 4}) do/
  end

  test "detects string text before the closing quote, but not after it" do
    for source <- [
          ~S("value"),
          ~S(""),
          ~S("before #{value} after")
        ] do
      document = Forge.Document.new("file:///string.ex", source, 1)
      analysis = Forge.Ast.analyze(document)
      closing_column = String.length(source)

      before_quote = Forge.Document.Position.new(document, 1, closing_column)
      after_quote = Forge.Document.Position.new(document, 1, closing_column + 1)

      assert @context.detected?(analysis, before_quote)
      refute @context.detected?(analysis, after_quote)
    end
  end
end
