defmodule Expert.CodeIntelligence.Completion.Translations.FunctionTest do
  use Expert.Test.Expert.CompletionCase

  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Enumerations.InsertTextFormat

  describe "function completions" do
    test "deprecated functions are marked", %{project: project} do
      assert {:ok, completion} =
               project
               |> complete("Enum.filter_map|")
               |> fetch_completion("filter_map")

      assert completion.label
      expected_tag = GenLSP.Enumerations.CompletionItemTag.deprecated()
      assert [^expected_tag] = completion.tags
    end

    test "bang functions are sorted after non-bang functions", %{project: project} do
      {:ok, [normal, bang]} =
        project
        |> complete("Map.fetc|")
        |> fetch_completion("fetch")

      assert normal.label == "fetch(map, key)"
      assert bang.label == "fetch!(map, key)"
    end

    test "suggest arity 0 functions if not in a pipeline", %{project: project} do
      {:ok, completion} =
        project
        |> complete("Application.loaded_app|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(completion) == "Application.loaded_applications()"
    end

    test "do not suggest arity 0 functions if in a pipeline", %{project: project} do
      assert {:error, :not_found} =
               project
               |> complete("|> Application.loaded_app|")
               |> fetch_completion(kind: CompletionItemKind.function())
    end

    test "arity 1 omits arguments if in a pipeline", %{project: project} do
      {:ok, [completion, _]} =
        project
        |> complete("|> Enum.dedu|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(completion) == "|> Enum.dedup()"
    end

    test "arity > 1 omits the first argument if in a pipeline", %{project: project} do
      {:ok, completion} =
        project
        |> complete("|> Enum.chunk_b|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(completion) == "|> Enum.chunk_by(${1:fun})"
      assert completion.label == "chunk_by(fun)"
    end

    test "do not add parens if they're already present", %{project: project} do
      {:ok, completion} =
        project
        |> complete("Enum.dedup_b|()")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(completion) == "Enum.dedup_by()"
    end

    test "are suggested immediately after a dot", %{project: project} do
      {:ok, completion} =
        project
        |> complete("Enum.|")
        |> fetch_completion("dedup_by(enumerable, fun)")

      assert apply_completion(completion) == "Enum.dedup_by(${1:enumerable}, ${2:fun})"
    end

    test "completes funs in locals_without_parens with a specific arity",
         %{project: project} do
      source = ~q[
        Project.Functions.fun_1|
      ]

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.function())

      assert completion.label == "fun_1_without_parens arg"
      assert apply_completion(completion) =~ "Project.Functions.fun_1_without_parens ${1:arg}"
    end

    test "completes imported funs in locals_without_parens with a specific arity",
         %{project: project} do
      source = ~q[
        import Project.Functions

        fun_1|
      ]

      assert {:ok, completion} =
               project
               |> complete(source)
               |> fetch_completion(kind: CompletionItemKind.function())

      assert completion.label == "fun_1_without_parens arg"
      assert apply_completion(completion) =~ "fun_1_without_parens ${1:arg}"
    end
  end

  describe "function captures" do
    test "suggest modules", %{project: project} do
      source = ~q[
        Enum.map(1..10, &Inte|)
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.module())

      assert completion.label == "Integer"
    end

    test "of arity 1 are suggested with /1", %{project: project} do
      source = ~q[
        Enum.map(1..10, &Integer.to_|)
      ]

      completions = complete(project, source)

      arity_one_completions =
        Enum.filter(completions, fn completion ->
          String.contains?(completion.label, "/1") and completion.detail == "(Capture)"
        end)

      assert not Enum.empty?(arity_one_completions)

      Enum.each(arity_one_completions, fn completion ->
        assert completion |> apply_completion() |> String.contains?("/1)")
      end)
    end

    test "of arity 1 are suggested with named params", %{project: project} do
      source = ~q[
        Enum.map(1..10, &Integer.to_|)
      ]

      completions = complete(project, source)

      arity_one_completions =
        Enum.filter(completions, fn completion ->
          not String.contains?(completion.label, ",") and
            completion.detail =~ "(Capture with"
        end)

      assert not Enum.empty?(arity_one_completions)

      Enum.each(arity_one_completions, fn completion ->
        assert completion |> apply_completion() |> String.contains?("(${1:")
      end)
    end

    test "arity > 1 provides a snippet with parens and commas", %{project: project} do
      source = ~q[
        Enum.map(1..10, Enum.reduce_w|)
      ]

      {:ok, completion} =
        project
        |> complete(source)
        |> fetch_completion(kind: CompletionItemKind.function())

      assert completion.insert_text_format == InsertTextFormat.snippet()

      assert apply_completion(completion) == ~q[
        Enum.map(1..10, Enum.reduce_while(${1:enumerable}, ${2:acc}, ${3:fun}))
      ]
    end

    test "work with Kernel arity one functions", %{project: project} do
      source = "&is_ma|"

      [capture, args_capture] =
        project
        |> complete(source)
        |> Enum.filter(fn completion ->
          sort_text = completion.sort_text
          # arity 1 and is is_map
          String.ends_with?(sort_text, "001") and
            String.contains?(sort_text, "is_map")
        end)

      assert capture.detail == "(Capture)"
      assert apply_completion(capture) == "&is_map/1"

      assert args_capture.detail == "(Capture with arguments)"
      assert args_capture.insert_text_format == InsertTextFormat.snippet()
      assert apply_completion(args_capture) == "&is_map(${1:term})"
    end

    test "work with kernel two arity functions", %{project: project} do
      [is_map_key_complete, is_map_key_args] = complete(project, "&is_map_key|")

      assert is_map_key_complete.detail == "(Capture)"
      assert apply_completion(is_map_key_complete) == "&is_map_key/2"

      assert is_map_key_args.detail == "(Capture with arguments)"
      assert is_map_key_args.insert_text_format == InsertTextFormat.snippet()
      assert apply_completion(is_map_key_args) == "&is_map_key(${1:map}, ${2:key})"
    end
  end

  describe "handling default arguments" do
    test "includes every arity when all arguments have defaults", %{project: project} do
      {:ok, completions} =
        project
        |> complete("Project.DefaultArgs.multiple|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert Enum.map(completions, &apply_completion/1) == [
               "Project.DefaultArgs.multiple()",
               "Project.DefaultArgs.multiple(${1:a})",
               "Project.DefaultArgs.multiple(${1:a}, ${2:b})"
             ]
    end

    test "captures include every supported arity", %{project: project} do
      completions = complete(project, "&Project.DefaultArgs.options|")

      captures = Enum.filter(completions, &(&1.detail == "(Capture)"))

      assert Enum.map(captures, &apply_completion/1) == [
               "&Project.DefaultArgs.options/1",
               "&Project.DefaultArgs.options/2"
             ]
    end

    test "works with a first arg", %{project: project} do
      {:ok, [arity_1, arity_2]} =
        project
        |> complete("Project.DefaultArgs.first|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(arity_1) == "Project.DefaultArgs.first_arg(${1:y})"
      assert apply_completion(arity_2) == "Project.DefaultArgs.first_arg(${1:x}, ${2:y})"
    end

    test "works with the middle arg", %{project: project} do
      {:ok, [arity_1, arity_2]} =
        project
        |> complete("Project.DefaultArgs.middle|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(arity_1) == "Project.DefaultArgs.middle_arg(${1:a}, ${2:c})"
      assert apply_completion(arity_2) == "Project.DefaultArgs.middle_arg(${1:a}, ${2:b}, ${3:c})"
    end

    test "works with the last arg", %{project: project} do
      {:ok, [arity_1, arity_2]} =
        project
        |> complete("Project.DefaultArgs.last|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(arity_1) == "Project.DefaultArgs.last_arg(${1:x})"
      assert apply_completion(arity_2) == "Project.DefaultArgs.last_arg(${1:x}, ${2:y})"
    end

    test "works with options", %{project: project} do
      {:ok, [arity_1, arity_2]} =
        project
        |> complete("Project.DefaultArgs.opt|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(arity_1) == "Project.DefaultArgs.options(${1:a})"
      assert apply_completion(arity_2) == "Project.DefaultArgs.options(${1:a}, ${2:opts})"
    end

    test "works with struct defaults", %{project: project} do
      {:ok, [arity_1, arity_2]} =
        project
        |> complete("Project.DefaultArgs.struct|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(arity_1) == "Project.DefaultArgs.struct_arg(${1:a})"
      assert apply_completion(arity_2) == "Project.DefaultArgs.struct_arg(${1:a}, ${2:b})"
    end

    test "works with pattern match args", %{project: project} do
      {:ok, completion} =
        project
        |> complete("Project.DefaultArgs.pattern_match|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(completion) == "Project.DefaultArgs.pattern_match_arg(${1:user})"
    end

    test "works with reverse pattern match args", %{project: project} do
      {:ok, completion} =
        project
        |> complete("Project.DefaultArgs.reverse|")
        |> fetch_completion(kind: CompletionItemKind.function())

      assert apply_completion(completion) ==
               "Project.DefaultArgs.reverse_pattern_match_arg(${1:user})"
    end
  end

  describe "ordering" do
    test "functions with lower arity have higher completion priority", %{project: project} do
      [arity_2, arity_3] =
        project
        |> complete("Enum.|")
        |> fetch_completion("count_until")
        |> then(fn {:ok, list} -> list end)
        |> Enum.sort_by(& &1.sort_text)

      assert apply_completion(arity_2) == "Enum.count_until(${1:enumerable}, ${2:limit})"

      assert apply_completion(arity_3) ==
               "Enum.count_until(${1:enumerable}, ${2:fun}, ${3:limit})"
    end
  end
end
