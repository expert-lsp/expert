defmodule Expert.Project.IntelligenceTest do
  use ExUnit.Case
  use Patch
  use Expert.Test.DispatchFake

  import Forge.EngineApi.Messages

  alias Expert.EngineApi
  alias Expert.Project.Intelligence
  alias Expert.Search.Store
  alias Expert.Test.DispatchFake
  alias Forge.Search.Indexer.Entry
  alias Forge.Test.Fixtures

  setup do
    project = Fixtures.project()
    DispatchFake.start()

    start_supervised!({Intelligence, project})

    {:ok, project: project}
  end

  def with_parent_and_children(%{project: project}) do
    [
      module_updated(name: "RootStruct", struct: [name: nil, value: nil]),
      module_updated(name: "Parent", functions: []),
      module_updated(name: "Parent.Child"),
      module_updated(name: "Parent.ChildWithStruct", struct: [name: nil, value: nil]),
      module_updated(name: "Parent.Child.Grandchild"),
      module_updated(name: "Parent.Child.GrandchildWithStruct", struct: [name: nil]),
      module_updated(name: "NoStructs", functions: []),
      module_updated(name: "NoStructs.Child", functions: []),
      module_updated(name: "DeepStructs", functions: []),
      module_updated(name: "DeepStructs.Child", functions: []),
      module_updated(name: "DeepStructs.Child.Grandchild", functions: []),
      module_updated(name: "DeepStructs.Child.Grandchild.GreatGrandchild", functions: []),
      module_updated(
        name: "DeepStructs.Child.Grandchild.Greatgrandchild.GreatGreatGrandchild",
        functions: [],
        struct: [name: nil]
      )
    ]
    |> Enum.each(&EngineApi.broadcast(project, &1))

    Process.sleep(50)
    :ok
  end

  test "refreshes struct definitions from the project index", %{project: project} do
    struct_module = Module.concat(__MODULE__, IndexedStruct)

    patch(Store, :exact, fn ^project, :_, [type: :struct, subtype: :definition] ->
      {:ok, [%Entry{subject: struct_module}]}
    end)

    send(Process.whereis(Intelligence.name(project)), project_index_ready(project: project))

    assert Intelligence.collect_struct_modules(project, struct_module) == [inspect(struct_module)]
  end

  describe "defines_struct?/2" do
    setup [:with_parent_and_children]

    test "returns true if the module defines a struct", %{project: project} do
      assert Intelligence.defines_struct?(project, "Parent.ChildWithStruct")
    end

    test "returns false if the module doesn't have a struct", %{project: project} do
      refute Intelligence.defines_struct?(project, "Parent")
      refute Intelligence.defines_struct?(project, "Parent.Child")
    end
  end

  describe "defines_struct?/3" do
    setup [:with_parent_and_children]

    test "returns true if a child defines a struct", %{project: project} do
      assert Intelligence.defines_struct?(project, "Parent", from: :child, to: :child)
      assert Intelligence.defines_struct?(project, "Parent.Child", from: :child, to: :child)

      assert Intelligence.defines_struct?(project, Parent, from: :child, to: :child)
      assert Intelligence.defines_struct?(project, Parent.Child, from: :child, to: :child)
    end

    test "returns false if a child doesn't define a struct", %{project: project} do
      refute Intelligence.defines_struct?(project, "Parent.Child.Grandchild",
               from: :child,
               to: :child
             )

      refute Intelligence.defines_struct?(project, Parent.Child.Grandchild,
               from: :child,
               to: :child
             )
    end

    test "works with arbitrary ranges", %{project: project} do
      refute Intelligence.defines_struct?(project, "DeepStructs")
      refute Intelligence.defines_struct?(project, "DeepStructs", 0..1)
      refute Intelligence.defines_struct?(project, "DeepStructs", 0..2)
      refute Intelligence.defines_struct?(project, "DeepStructs", 0..3)
      assert Intelligence.defines_struct?(project, "DeepStructs", 0..4)
    end

    test "works with arbitrary ranges of names", %{project: project} do
      refute Intelligence.defines_struct?(project, "DeepStructs")
      refute Intelligence.defines_struct?(project, "DeepStructs", to: :child)
      refute Intelligence.defines_struct?(project, "DeepStructs", to: :grandchild)
      refute Intelligence.defines_struct?(project, "DeepStructs", to: :great_grandchild)
      assert Intelligence.defines_struct?(project, "DeepStructs", to: :great_great_grandchild)
    end

    test "works with arbitrary ranges of numbers", %{project: project} do
      refute Intelligence.defines_struct?(project, "DeepStructs")
      refute Intelligence.defines_struct?(project, "DeepStructs", to: 1)
      refute Intelligence.defines_struct?(project, "DeepStructs", to: 2)
      refute Intelligence.defines_struct?(project, "DeepStructs", to: 3)
      assert Intelligence.defines_struct?(project, "DeepStructs", to: 4)
    end

    test "returns true if a range defines a struct", %{project: project} do
      assert Intelligence.defines_struct?(project, Parent, to: :grandchild)
      assert Intelligence.defines_struct?(project, Parent, to: :grandchild)
    end
  end

  describe "collect_struct_modules/3" do
    setup [:with_parent_and_children]

    test "collecting the root module's struct", %{project: project} do
      assert ["RootStruct"] = Intelligence.collect_struct_modules(project, "RootStruct")
    end

    test "collecting direct children of a given module", %{project: project} do
      assert ["Parent.ChildWithStruct"] =
               Intelligence.collect_struct_modules(project, "Parent", from: :child, to: :child)

      assert ["Parent.Child.GrandchildWithStruct"] =
               Intelligence.collect_struct_modules(project, Parent.Child,
                 from: :child,
                 to: :child
               )
    end

    test "collecting a range of structs", %{project: project} do
      assert collected = Intelligence.collect_struct_modules(project, "Parent", to: :grandchild)

      assert "Parent.ChildWithStruct" in collected
      assert "Parent.Child.GrandchildWithStruct" in collected
    end

    test "collecting a range specifying from using names", %{project: project} do
      assert collected =
               Intelligence.collect_struct_modules(project, "Parent",
                 from: :child,
                 to: :grandchild
               )

      assert "Parent.ChildWithStruct" in collected
      assert "Parent.Child.GrandchildWithStruct" in collected

      assert ["Parent.Child.GrandchildWithStruct"] =
               Intelligence.collect_struct_modules(project, "Parent",
                 from: :grandchild,
                 to: :great_grandchild
               )
    end

    test "collecting a range specifying from using numbers", %{project: project} do
      assert collected =
               Intelligence.collect_struct_modules(project, "Parent",
                 from: 1,
                 to: 2
               )

      assert "Parent.ChildWithStruct" in collected
      assert "Parent.Child.GrandchildWithStruct" in collected

      assert ["Parent.Child.GrandchildWithStruct"] =
               Intelligence.collect_struct_modules(project, "Parent",
                 from: 2,
                 to: 3
               )
    end

    test "collecting a range using ranges", %{project: project} do
      assert collected = Intelligence.collect_struct_modules(project, "Parent", 1..2)

      assert "Parent.ChildWithStruct" in collected
      assert "Parent.Child.GrandchildWithStruct" in collected

      assert ["Parent.Child.GrandchildWithStruct"] =
               Intelligence.collect_struct_modules(project, "Parent", 2..3)
    end

    test "collecting modules using `:infinity`", %{project: project} do
      collected = Intelligence.collect_struct_modules(project, "Parent", :infinity)

      assert [grandchild_struct, child_struct] = collected

      assert child_struct == "Parent.ChildWithStruct"
      assert grandchild_struct == "Parent.Child.GrandchildWithStruct"
    end
  end
end
