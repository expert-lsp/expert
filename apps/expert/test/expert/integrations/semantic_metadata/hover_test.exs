defmodule Expert.Integrations.SemanticMetadata.HoverTest do
  use Expert.Test.SemanticMetadataCase, async: false

  @moduletag :tmp_dir

  setup %{project: project, tmp_dir: tmp_dir} do
    module =
      register_beam!(project, tmp_dir, """
      defmodule #{inspect(unique_module("Docs"))} do
        @doc "An AND where query expression."
        defmacro where(_query, _bindings, expression), do: expression

        @doc "Takes the first value which is not null."
        def coalesce(left, right), do: left || right
      end
      """)

    put_documents(project, [
      %{
        contexts: [%{mfa: {My.Query, :from, 2}, argument: 1, scope: :options}],
        scopes: %{
          options: %{
            entries: [
              %{
                kind: :keyword,
                name: :where,
                value_scope: :expressions,
                doc: {module, :macro, :where, 3}
              },
              %{kind: :keyword, name: :order, value_scope: :directions}
            ]
          },
          expressions: %{
            entries: [
              %{
                kind: :function,
                mfa: {module, :coalesce, 2},
                doc: {module, :function, :coalesce, 2}
              }
            ]
          },
          directions: %{entries: [%{kind: :literal, value: :asc, doc: "Ascending order."}]}
        }
      }
    ])

    {:ok, module: module}
  end

  test "reads the documentation of a keyword from a BEAM file", %{
    project: project,
    module: module
  } do
    assert [{"An AND where query expression.", range}] =
             hover(project, "My.Query.from(u in User, whe|re: coalesce(u.name, \"\"))")

    assert range.start.character == 26
    assert range.end.character == 31
    refute :code.is_loaded(module)
  end

  test "reads the documentation of a function from a BEAM file", %{
    project: project,
    module: module
  } do
    assert [{"Takes the first value which is not null.", range}] =
             hover(project, "My.Query.from(u in User, where: coal|esce(u.name, \"\"))")

    assert range.start.character == 33
    assert range.end.character == 41
    refute :code.is_loaded(module)
  end

  test "reads the documentation of an atom literal", %{project: project} do
    assert [{"Ascending order.", _range}] =
             hover(project, "My.Query.from(u in User, order: :as|c)")
  end
end
