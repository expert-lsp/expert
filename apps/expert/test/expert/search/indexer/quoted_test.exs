defmodule Expert.Search.Indexer.QuotedTest do
  use ExUnit.Case, async: false

  import Forge.Test.CodeSigil
  import Forge.Test.CursorSupport
  import Forge.Test.Fixtures

  alias Expert.Search.Indexer.ModuleRegistry
  alias Expert.Search.Indexer.Quoted
  alias Forge.Ast
  alias Forge.Document.Range
  alias Forge.Search.Indexer.Entry

  require Entry

  setup do
    project = project()
    Engine.set_project(project)
    start_supervised!({Expert.Project.Store, []})
    start_supervised!({ModuleRegistry, project})
    {:ok, project: project}
  end

  describe "entries_at/3" do
    test "returns the reference under the cursor", %{project: project} do
      code = ~q[
        defmodule Parent do
          def first, do: Other.first(1)
          def second, do: Other.sec|ond(2)
        end
      ]

      {_position, _analysis, entries} = entries_at(project, code)

      assert Enum.any?(entries, &(&1.subject == "Other.second/1"))
    end

    test "leaves out the entries of other expressions", %{project: project} do
      code = ~q[
        defmodule Parent do
          def first, do: Other.first(1)
          def second, do: Other.sec|ond(2)
        end
      ]

      {_position, _analysis, entries} = entries_at(project, code)

      refute Enum.any?(entries, &(&1.subject == "Other.first/1"))
    end

    test "returns every indexed entry that contains the position", %{project: project} do
      codes = [
        ~q[
          defmodule Parent do
            def fun(%Parent.Str|uct{} = struct), do: struct
          end
        ],
        ~q[
          defmodule Parent do
            def fun(list), do: list |> Enum.ma|p(&to_string/1) |> Enum.join()
          end
        ],
        ~q[
          defmodule Parent do
            alias Parent.{First, Sec|ond}
            def fun, do: {First, Second}
          end
        ],
        ~q[
          defmodule Parent do
            def fu|n(a, b), do: __MODULE__.other(a, b)
            def other(a, b), do: {a, b}
          end
        ],
        ~q[
          defmodule Parent do
            def fun(a), do: Parent.Oth|er.call(a)
          end
        ],
        ~q[
          defmodule Parent do
            alias Parent.Oth|er
            def fun(a), do: Other.call(a)
          end
        ],
        ~q[
          defmodule Parent do
            @attr :lists
            def fun(list), do: :lists.reverse(list) == @at|tr
          end
        ]
      ]

      for code <- codes do
        {position, analysis, entries} = entries_at(project, code)
        {:ok, all} = Quoted.index_with_cleanup(analysis, project)

        containing =
          for entry <- all,
              not Entry.is_structure(entry),
              Range.contains?(entry.range, position),
              do: key(entry)

        assert containing != []
        assert containing -- Enum.map(entries, &key/1) == []
      end
    end
  end

  defp entries_at(project, code) do
    {position, document} = pop_cursor(code, as: :document)
    analysis = Ast.analyze(document)
    {:ok, entries} = Quoted.entries_at(analysis, project, position)
    {position, analysis, entries}
  end

  defp key(entry), do: {entry.subject, entry.type, entry.subtype, entry.range}
end
