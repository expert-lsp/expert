defmodule Engine.CodeMod.Format.CacheTest do
  use ExUnit.Case, async: false
  use Patch

  alias Engine.CodeMod.Format.Cache
  alias Engine.CodeMod.Format.Resolver
  alias Forge.Document
  alias Forge.Project

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    dot_formatter_path = Path.join(tmp_dir, ".formatter.exs")
    create_file(tmp_dir, ".formatter.exs", "[inputs: [\"**/*.{ex,exs,heex}\"]]\n")

    project =
      tmp_dir
      |> Document.Path.to_uri()
      |> Project.new()

    ex_path = create_file(tmp_dir, "a.ex")
    other_ex_path = create_file(tmp_dir, "b.ex")

    start_supervised!(Document.Store)
    start_supervised!({Cache, project: project, refresh_interval: :timer.hours(1)})

    # Refresh evicts entries for closed documents, so cached paths must be
    # open in the store to survive it, as they are in production.
    for path <- [ex_path, other_ex_path] do
      :ok = path |> Document.Path.to_uri() |> Document.Store.open("", 1)
    end

    {:ok,
     dot_formatter_path: dot_formatter_path,
     ex_path: ex_path,
     other_ex_path: other_ex_path,
     project: project,
     tmp_dir: tmp_dir}
  end

  test "a miss resolves the formatter and caches it", ctx do
    patch_resolver()

    assert {:ok, formatter, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)
    assert is_function(formatter, 1)
    assert opts[:line_length] == 98
    assert_called(Resolver.resolve(_, _), 1)
  end

  test "a hit only resolves once", ctx do
    assert {:ok, _, _} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    patch_resolver()

    assert {:ok, _, _} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    refute_called(Resolver.resolve(_, _), 1)
  end

  test "second fetch hits ETS directly without going through the genserver", ctx do
    assert {:ok, formatter, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    spy(GenServer)

    assert {:ok, ^formatter, ^opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    refute_any_call(GenServer, :call)
  end

  test "fetch returns :error when resolution fails", ctx do
    patch(Resolver, :resolve, fn _project, _file_path -> raise "boom" end)

    assert :error = Cache.fetch_formatter(ctx.project, ctx.ex_path)
  end

  test "refresh does nothing when no .formatter.exs changed", ctx do
    assert {:ok, _, _} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    refresh()
    spy(Cache.State)

    refute_called(Cache.State.put_dot_formatters(_, _))
  end

  test "a changed .formatter.exs clears the cache on refresh", ctx do
    patch_resolver()
    assert {:ok, _, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)
    assert opts[:line_length] == 98

    patch_resolver(line_length: 80)
    touch(ctx.dot_formatter_path)
    refresh()

    assert {:ok, _, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)
    assert opts[:line_length] == 80
  end

  test "a new .formatter.exs reachable via :subdirectories is picked up on refresh", ctx do
    patch_resolver()
    assert {:ok, _, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)
    assert opts[:line_length] == 98

    lib_dir = Path.join(ctx.tmp_dir, "lib")

    create_file(lib_dir, ".formatter.exs", "[inputs: [\"**/*.ex\"]]\n")

    create_file(
      Path.dirname(ctx.dot_formatter_path),
      Path.basename(ctx.dot_formatter_path),
      ~s([inputs: ["**/*.{ex,exs,heex}"], subdirectories: ["lib"]]\n)
    )

    patch_resolver(line_length: 80)
    touch(ctx.dot_formatter_path)
    refresh()

    assert {:ok, _, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)
    assert opts[:line_length] == 80
  end

  test "a new .formatter.exs not in :subdirectories is not discovered", ctx do
    patch_resolver()
    assert {:ok, _, _} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    ctx.tmp_dir
    |> Path.join("lib")
    |> create_file(".formatter.exs", "[inputs: [\"**/*.ex\"]]\n")

    patch_resolver(line_length: 80)
    refresh()

    assert {:ok, _, opts} = Cache.fetch_formatter(ctx.project, ctx.ex_path)
    assert opts[:line_length] == 98
  end

  test ".formatter.exs files under deps and _build are ignored", ctx do
    patch_resolver()
    assert {:ok, _, _} = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    for dir <- ["deps/some_dep", "_build/dev"] do
      path = Path.join([ctx.tmp_dir, dir])
      create_file(path, ".formatter.exs", "[inputs: []]\n")
    end

    refresh()

    assert_called(Resolver.resolve(_, _), 1)
  end

  test "formatter functions are cached per file path",
       %{ex_path: ex_path, other_ex_path: other_ex_path} = ctx do
    # Force the resolver to use the context project's root for the formatter
    Engine.set_project(ctx.project)

    invalid_source = "def foo(a, ), do: true"

    assert {:ok, ex_formatter, _opts} =
             Cache.fetch_formatter(ctx.project, ex_path)

    assert {:ok, other_ex_formatter, _opts} =
             Cache.fetch_formatter(ctx.project, other_ex_path)

    assert {:error, %SyntaxError{file: ^ex_path}} =
             ex_formatter.(invalid_source)

    assert {:error, %SyntaxError{file: ^other_ex_path}} =
             other_ex_formatter.(invalid_source)
  end

  test "closing one file does not break another cached formatter", ctx do
    Engine.set_project(ctx.project)

    assert {:ok, _, _} =
             Cache.fetch_formatter(ctx.project, ctx.ex_path)

    assert {:ok, other_formatter, other_opts} =
             Cache.fetch_formatter(ctx.project, ctx.other_ex_path)

    :ok =
      ctx.ex_path
      |> Document.Path.to_uri()
      |> Document.Store.close()

    refresh()

    assert {:ok, ^other_formatter, ^other_opts} =
             Cache.fetch_formatter(ctx.project, ctx.other_ex_path)
  end

  test "a resolution failure is not cached", ctx do
    patch(Resolver, :resolve, fn _project, _file_path ->
      raise "boom"
    end)

    assert :error = Cache.fetch_formatter(ctx.project, ctx.ex_path)

    patch_resolver()

    assert {:ok, _, _} =
             Cache.fetch_formatter(ctx.project, ctx.ex_path)
  end

  defp create_file(dir, name, contents \\ "") do
    path = Path.join(dir, name)
    File.mkdir_p!(dir)
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp patch_resolver(overrides \\ []) do
    patch(Resolver, :resolve, fn _project, file_path ->
      {fn source -> source end, resolver_opts([root: Path.dirname(file_path)] ++ overrides)}
    end)
  end

  defp resolver_opts(overrides) do
    Keyword.merge(
      [
        inputs: ["**/*.{ex,exs,heex}"],
        line_length: 98,
        locals_without_parens: []
      ],
      overrides
    )
  end

  defp touch(path) do
    File.touch!(path, System.os_time(:second) + 1)
  end

  defp refresh do
    pid = Process.whereis(Cache)
    send(pid, :refresh)
    :sys.get_state(pid)

    :ok
  end
end
