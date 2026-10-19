defmodule Expert.CodeIntelligence.Completion.Translations.BitstringOptionsTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind

  describe "bitstring options" do
    test "offers completions after ::", %{project: project} do
      assert {:ok, completions} =
               project
               |> complete("<<x::|")
               |> fetch_completion(CompletionItemKind.unit())

      for completion <- completions,
          completed = apply_completion(completion) do
        assert String.ends_with?(completed, completion.filter_text)
      end
    end

    test "offers completions after :: in an existing context", %{project: project} do
      assert {:ok, completions} =
               project
               |> complete("<<foo::u32, x::|")
               |> fetch_completion(CompletionItemKind.unit())

      for completion <- completions,
          completed = apply_completion(completion) do
        assert String.ends_with?(completed, completion.filter_text)
      end
    end

    test "supports integer", %{project: project} do
      assert {:ok, completion} =
               project
               |> complete("<<x::inte|")
               |> fetch_completion(CompletionItemKind.unit())

      assert apply_completion(completion) == "<<x::integer"
    end

    test "doesn't get confused if the completion is 'in'", %{project: project} do
      assert {:ok, completion} =
               project
               |> complete("<<x::in|")
               |> fetch_completion(CompletionItemKind.unit())

      assert apply_completion(completion) == "<<x::integer"
    end

    test "supports multiple options", %{project: project} do
      assert {:ok, [unit, utf8, utf16, utf32]} =
               project
               |> complete("<<foo::utf8, bar::ut|")
               |> fetch_completion(CompletionItemKind.unit())

      assert apply_completion(utf8) == "<<foo::utf8, bar::utf8"
      assert apply_completion(utf16) == "<<foo::utf8, bar::utf16"
      assert apply_completion(utf32) == "<<foo::utf8, bar::utf32"
      assert apply_completion(unit) == "<<foo::utf8, bar::unit"
    end

    test "supports dashed options", %{project: project} do
      assert {:ok, completion} =
               project
               |> complete("<<x::integer-siz|")
               |> fetch_completion(CompletionItemKind.unit())

      assert apply_completion(completion) == "<<x::integer-size"
    end

    @tag :skip
    # Note: looks like elixir sense needs a context character in order to complete
    # after a dash. Bummer.
    test "completes after a dash", %{project: project} do
      assert {:ok, completions} =
               project
               |> complete("<<x::big-integer-|")
               |> fetch_completion(CompletionItemKind.unit())

      for completion <- completions do
        assert String.starts_with?(completion, "-")
      end
    end

    test "supports concatenated dashed options", %{project: project} do
      assert {:ok, completion} =
               project
               |> complete("<<x::big-integer-siz|")
               |> fetch_completion(CompletionItemKind.unit())

      assert apply_completion(completion) == "<<x::big-integer-size"
    end

    test "supports utf options", %{project: project} do
      assert {:ok, [utf8, utf16, utf32]} =
               project
               |> complete("<<foo::utf|")
               |> fetch_completion(CompletionItemKind.unit())

      assert apply_completion(utf8) == "<<foo::utf8"
      assert apply_completion(utf16) == "<<foo::utf16"
      assert apply_completion(utf32) == "<<foo::utf32"
    end

    test "functions are not included", %{project: project} do
      code = ~q[
        def bin_fn() do
        end

        def other do
          <<foo::bin|
        end
      ]

      assert {:error, :not_found} =
               project
               |> complete(code)
               |> fetch_completion(kind: CompletionItemKind.function())
    end

    test "macros are not included", %{project: project} do
      code = ~q[
        def bin_fn() do
        end

        def other do
          <<foo::is_|
        end
      ]

      assert {:error, :not_found} =
               project
               |> complete(code)
               |> fetch_completion(kind: CompletionItemKind.function())
    end

    test "variables are included", %{project: project} do
      code = ~q[
        bin_length = 5
        <<foo::binary-size(bin_l|)
      ]

      assert {:ok, completion} =
               project
               |> complete(code)
               |> fetch_completion(kind: CompletionItemKind.variable())

      assert apply_completion(completion) == ~q[
        bin_length = 5
        <<foo::binary-size(bin_length)
      ]
    end
  end
end
