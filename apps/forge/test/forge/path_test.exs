defmodule Forge.PathTest do
  use ExUnit.Case, async: true

  doctest Forge.Path

  describe "contains?/2" do
    test "matches exact path and nested child path" do
      assert Forge.Path.contains?("/home/user/project", "/home/user/project")
      assert Forge.Path.contains?("/home/user/project/lib/foo.ex", "/home/user/project")

      assert Forge.Path.contains?(
               "/home/user/project/lib/nested/deep/bar.ex",
               "/home/user/project"
             )
    end

    test "handles trailing slashes on parent and child" do
      assert Forge.Path.contains?("/home/user/project/lib/foo.ex", "/home/user/project/")
      assert Forge.Path.contains?("/home/user/project/", "/home/user/project")
      assert Forge.Path.contains?("/home/user/project", "/home/user/project/")
    end

    test "does not match sibling directories with common prefix" do
      refute Forge.Path.contains?("/home/user/project_v2/lib/foo.ex", "/home/user/project")
      refute Forge.Path.contains?("/home/user/project_build/foo.ex", "/home/user/project")
      refute Forge.Path.contains?("/home/user/project.tar.gz", "/home/user/project")
    end

    test "handles root directory and empty string" do
      assert Forge.Path.contains?("/home/user/project", "/")
      assert Forge.Path.contains?("/home/user/project", "")
      refute Forge.Path.contains?("relative/path", "/")
    end

    test "handles Windows backslashes" do
      assert Forge.Path.contains?(
               "C:\\Users\\user\\project\\lib\\foo.ex",
               "C:\\Users\\user\\project"
             )

      refute Forge.Path.contains?(
               "C:\\Users\\user\\project_v2\\lib\\foo.ex",
               "C:\\Users\\user\\project"
             )
    end

    test "handles Windows drive letter case-insensitivity" do
      assert Forge.Path.contains?(
               "C:/Users/user/project/lib/foo.ex",
               "c:/Users/user/project"
             )

      assert Forge.Path.contains?(
               "c:/Users/user/project/lib/foo.ex",
               "C:/Users/user/project"
             )

      assert Forge.Path.contains?(
               "C:\\Users\\user\\project\\lib\\foo.ex",
               "c:/Users/user/project"
             )

      assert Forge.Path.contains?("C:/Users/user/project", "c:/Users/user/project")
      assert Forge.Path.contains?("c:/Users/user/project", "C:/Users/user/project")
    end

    test "handles unicode directory and file paths" do
      assert Forge.Path.contains?("/home/user/dự_án/thư_mục/file.ex", "/home/user/dự_án")
      assert Forge.Path.contains?("/home/user/プロジェクト/ソース/app.ex", "/home/user/プロジェクト")
      assert Forge.Path.contains?("/home/user/café/lib/app.ex", "/home/user/café/")
      assert Forge.Path.contains?("/home/user/dự_án", "/home/user/dự_án")

      refute Forge.Path.contains?("/home/user/dự_án_mới/file.ex", "/home/user/dự_án")
      refute Forge.Path.contains?("/home/user/プロジェクト2/app.ex", "/home/user/プロジェクト")
      refute Forge.Path.contains?("/home/user/cafétéria/lib/app.ex", "/home/user/café")
    end
  end

  describe "glob/2" do
    @tag :tmp_dir
    test "prunes excluded directories during wildcard traversal", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib/sub"))
      File.mkdir_p!(Path.join(tmp_dir, "_build/prod"))
      File.mkdir_p!(Path.join(tmp_dir, "deps/some_dep"))
      File.mkdir_p!(Path.join(tmp_dir, "thư_mục_bỏ_qua/con"))
      File.mkdir_p!(Path.join(tmp_dir, "thư_mục_giữ_lại"))

      keep1 = Path.join(tmp_dir, "lib/a.ex")
      keep2 = Path.join(tmp_dir, "lib/sub/b.exs")
      keep3 = Path.join(tmp_dir, "thư_mục_giữ_lại/f.ex")

      File.write!(keep1, "defmodule A, do: nil")
      File.write!(keep2, "defmodule B, do: nil")
      File.write!(Path.join(tmp_dir, "_build/prod/c.ex"), "defmodule C, do: nil")
      File.write!(Path.join(tmp_dir, "deps/some_dep/d.ex"), "defmodule D, do: nil")
      File.write!(Path.join(tmp_dir, "thư_mục_bỏ_qua/con/e.ex"), "defmodule E, do: nil")
      File.write!(keep3, "defmodule F, do: nil")

      excluded = [
        Path.join(tmp_dir, "_build"),
        Path.join(tmp_dir, "deps"),
        Path.join(tmp_dir, "thư_mục_bỏ_qua")
      ]

      result =
        [tmp_dir, "**", "*.{ex,exs}"]
        |> Forge.Path.glob(exclude: excluded)
        |> Enum.sort()

      assert result == Enum.sort([keep1, keep2, keep3])
    end

    @tag :tmp_dir
    test "supports relative excluded directory paths", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "_build"))

      keep = Path.join(tmp_dir, "lib/app.ex")
      File.write!(keep, "defmodule App, do: nil")
      File.write!(Path.join(tmp_dir, "_build/app.ex"), "defmodule App, do: nil")

      result = Forge.Path.glob([tmp_dir, "**", "*.ex"], exclude: ["_build"])
      assert result == [keep]
    end
  end
end
