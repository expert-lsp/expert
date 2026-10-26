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
end
