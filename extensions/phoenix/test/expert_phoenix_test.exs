defmodule ExpertPhoenixTest do
  use ExUnit.Case, async: true

  alias ExpertExtensions.Test.Request

  @routes [:get, :post, :match, :forward, :resources, :live]

  describe "controllers" do
    test "complete the controllers under the alias of the scopes around the route" do
      source = """
      scope "/", ExpertPhoenix.Test do
        scope "/admin", Web.Admin do
          get "/", Use|
        end
      end
      """

      assert [%{label: "UserController", detail: detail}] = complete(source, :controllers)
      assert detail =~ "ExpertPhoenix.Test.Web.Admin.UserController"
    end

    test "complete the controllers under the namespace of the router outside of a scope" do
      source = ~s(get "/", PageCon|)

      assert ["ExpertPhoenix.Test.Web.PageController"] =
               source
               |> Request.build(
                 call: {Phoenix.Router, :get},
                 scope: :controllers,
                 module: "ExpertPhoenix.Router"
               )
               |> ExpertPhoenix.complete()
               |> labels()

      assert [] =
               source
               |> Request.build(
                 call: {Phoenix.Router, :get},
                 scope: :controllers,
                 module: "Elsewhere.Router"
               )
               |> ExpertPhoenix.complete()
    end

    test "complete the controllers with their full names outside of a scope" do
      assert [admin, page] = complete(~s(get "/", ExpertPhoenix.Test.Web.|), :controllers)
      assert admin.label == "ExpertPhoenix.Test.Web.Admin.UserController"
      assert page.label == "ExpertPhoenix.Test.Web.PageController"

      assert page.range == %{start: %{line: 1, character: 10}, end: %{line: 1, character: 33}}
    end

    test "use the alias option of a scope, with or without a path, and drop outer aliases with alias: false" do
      source = """
      scope "/", alias: ExpertPhoenix.Test.Web do
        resources "/pages", Pa|
      end
      """

      assert ["PageController"] = source |> complete(:controllers) |> labels()

      source = """
      scope "/", ExpertPhoenix.Test.Web do
        scope "/other", alias: false do
          get "/", ExpertPhoenix.Test.Web.Pa|
        end
      end
      """

      assert ["ExpertPhoenix.Test.Web.PageController"] =
               source |> complete(:controllers) |> labels()

      source = """
      scope alias: ExpertPhoenix.Test.Web do
        get "/", Pa|
      end
      """

      assert ["PageController"] = source |> complete(:controllers) |> labels()
    end
  end

  describe "actions" do
    test "complete the actions of the controller of the route over the typed atom" do
      source = """
      scope "/", ExpertPhoenix.Test.Web do
        get "/", PageController, :sh|
      end
      """

      assert [%{label: ":show", range: range}] = complete(source, :actions)
      assert range == %{start: %{line: 2, character: 28}, end: %{line: 2, character: 31}}
    end

    test "complete every action after the comma" do
      source = """
      scope "/", ExpertPhoenix.Test.Web do
        get "/", PageController, |
      end
      """

      assert [":index", ":show"] = source |> complete(:actions) |> labels()
    end

    test "counts each codepoint as one column" do
      prefix = ~s(get "/é😀", ExpertPhoenix.Test.Web.PageController, :sh)
      cursor = String.length(prefix) + 1

      assert [%{range: range}] = complete(prefix <> "|", :actions)

      assert range == %{
               start: %{line: 1, character: cursor - 3},
               end: %{line: 1, character: cursor}
             }
    end
  end

  describe "plugs and LiveViews" do
    test "complete the module plugs of forward/2" do
      source = """
      scope "/", ExpertPhoenix.Test.Web do
        forward "/health", Hea|
      end
      """

      assert ["HealthPlug"] = source |> complete(:plugs) |> labels()
    end

    test "complete the LiveViews of live/2" do
      source = """
      scope "/", ExpertPhoenix.Test.Web do
        live "/dashboard", Dash|
      end
      """

      assert ["DashboardLive"] = source |> complete(:live_views) |> labels()
    end
  end

  describe "resolve" do
    test "resolves a controller under the aliases of the scopes around the route" do
      source = """
      scope "/", ExpertPhoenix.Test do
        scope "/admin", Web.Admin do
          get "/", UserCon|troller, :index
        end
      end
      """

      assert %{
               entity: %{kind: :module, module: ExpertPhoenix.Test.Web.Admin.UserController},
               range: %{start: %{line: 3, character: 14}, end: %{line: 3, character: 28}}
             } = resolve(source, :controllers)
    end

    test "uses the aliases of the enclosing scopes only, not of sibling scopes" do
      source = """
      scope "/", ExpertPhoenix.Test do
        scope "/admin", Web.Admin do
          get "/", UserController, :index
        end

        scope "/web", Web do
          get "/", Page|Controller, :index
        end
      end
      """

      assert %{entity: %{module: ExpertPhoenix.Test.Web.PageController}} =
               resolve(source, :controllers)
    end

    test "resolves the segments of an alias up to the end of the segment at the cursor" do
      source = """
      scope "/", ExpertPhoenix.Test do
        get "/", Web.Admin.User|Controller, :index
      end
      """

      assert %{entity: %{module: ExpertPhoenix.Test.Web.Admin.UserController}, range: range} =
               resolve(source, :controllers)

      assert range == %{start: %{line: 2, character: 12}, end: %{line: 2, character: 36}}
    end

    test "resolves an action to the function of the controller of the route" do
      source = """
      scope "/", ExpertPhoenix.Test.Web do
        get "/", PageController, :sh|ow
      end
      """

      assert %{
               entity: %{
                 kind: :function,
                 module: ExpertPhoenix.Test.Web.PageController,
                 name: :show,
                 arity: 2
               }
             } == resolve(source, :actions)
    end

    test "resolves a LiveView" do
      source = """
      scope "/", ExpertPhoenix.Test.Web do
        live "/dashboard", Dashboard|Live
      end
      """

      assert %{entity: %{module: ExpertPhoenix.Test.Web.DashboardLive}} =
               resolve(source, :live_views)
    end

    test "returns nil for an alias that the source cannot expand" do
      assert nil == resolve(~s(get "/", __MODULE__.Page|Controller, :index), :controllers)

      source = """
      scope "/", __MODULE__.Web do
        get "/", Page|Controller, :index
      end
      """

      assert nil == resolve(source, :controllers)
    end

    test "returns nil for a module that does not exist" do
      assert nil == resolve(~s(get "/", Missin|gController, :index), :controllers)
    end

    test "does not create atoms for unknown modules" do
      suffix = System.unique_integer([:positive])
      name = "Missing#{suffix}Controller"
      atom_name = "Elixir." <> name

      refute existing_atom?(atom_name)
      assert nil == resolve(~s(get "/", #{name}|, :index), :controllers)
      refute existing_atom?(atom_name)
    end
  end

  describe "references" do
    test "lists the routes to a controller, under the alias of their scopes" do
      assert references(%{kind: :module, module: ExpertPhoenix.Test.Web.PageController}) == [
               {~s(get "/", PageController, :index), "PageController"},
               {~s(get "/pages/:id", PageController, :show), "PageController"},
               {~s(get "/", ExpertPhoenix.Test.Web.PageController, :index),
                "ExpertPhoenix.Test.Web.PageController"},
               {~s(get "/pages", ExpertPhoenix.Test.Web.PageController, :index),
                "ExpertPhoenix.Test.Web.PageController"}
             ]
    end

    test "lists the routes in nested scopes and resources" do
      assert references(%{kind: :module, module: ExpertPhoenix.Test.Web.Admin.UserController}) ==
               [
                 {~s(get "/users", UserController, :index), "UserController"},
                 {~s(resources "/users", ExpertPhoenix.Test.Web.Admin.UserController do),
                  "ExpertPhoenix.Test.Web.Admin.UserController"}
               ]
    end

    test "lists the verb routes to an action" do
      entity = %{kind: :function, module: ExpertPhoenix.Test.Web.PageController, arity: 2}

      assert [
               {~s(get "/", PageController, :index), ":index"},
               {~s(get "/", ExpertPhoenix.Test.Web.PageController, :index), ":index"},
               {~s(get "/pages", ExpertPhoenix.Test.Web.PageController, :index), ":index"}
             ] = references(Map.put(entity, :name, :index))

      assert [{~s(get "/pages/:id", PageController, :show), ":show"}] =
               references(Map.put(entity, :name, :show))

      assert [] = references(%{entity | arity: 3} |> Map.put(:name, :index))
    end

    test "lists the routes to LiveViews and to plugs through aliases" do
      assert [{~s(live "/dashboard", DashboardLive), "DashboardLive"}] =
               references(%{kind: :module, module: ExpertPhoenix.Test.Web.DashboardLive})

      assert [{~s(forward "/health", Health), "Health"}] =
               references(%{kind: :module, module: ExpertPhoenix.Test.Web.HealthPlug})
    end

    @tag :tmp_dir
    test "counts each codepoint of a route as one column", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "router.ex")
      line = ~s(  get "/café", PageController, :index)
      File.write!(path, "scope \"/\", ExpertPhoenix.Test.Web do\n#{line}\nend\n")
      calls = [%{position: %{line: 2, character: 3}, target: {Phoenix.Router, :get, 3}}]
      entity = %{kind: :module, module: ExpertPhoenix.Test.Web.PageController}

      assert [%{range: range}] =
               ExpertPhoenix.references(%{entity: entity, files: [%{path: path, calls: calls}]})

      length = range.end.character - range.start.character
      assert String.slice(line, range.start.character - 1, length) == "PageController"
    end

    test "reads only the calls of the request" do
      entity = %{kind: :module, module: ExpertPhoenix.Test.Web.PageController}
      [first | _calls] = calls()

      assert [{~s(get "/", PageController, :index), "PageController"}] =
               references(entity, [first])
    end
  end

  @router Path.expand("fixtures/router.ex", __DIR__)

  defp references(entity, calls \\ calls()) do
    lines = @router |> File.read!() |> String.split("\n")

    for %{path: @router, range: range} <-
          ExpertPhoenix.references(%{entity: entity, files: [%{path: @router, calls: calls}]}) do
      line = Enum.at(lines, range.start.line - 1)
      length = range.end.character - range.start.character
      {String.trim(line), String.slice(line, range.start.character - 1, length)}
    end
  end

  defp calls do
    {_ast, calls} =
      @router
      |> File.read!()
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn
        {route, meta, arguments} = node, calls when route in @routes ->
          router = if route == :live, do: Phoenix.LiveView.Router, else: Phoenix.Router
          target = {router, route, length(arguments)}

          {node,
           [%{position: %{line: meta[:line], character: meta[:column]}, target: target} | calls]}

        node, calls ->
          {node, calls}
      end)

    Enum.sort(calls)
  end

  defp complete(source, scope), do: source |> request(scope) |> ExpertPhoenix.complete()
  defp resolve(source, scope), do: source |> request(scope) |> ExpertPhoenix.resolve()

  defp request(source, scope) do
    route =
      source
      |> Request.build()
      |> Map.fetch!(:ancestors)
      |> Enum.find_value(fn
        {route, _meta, _arguments} when route in @routes -> route
        _ancestor -> nil
      end)

    router = if route == :live, do: Phoenix.LiveView.Router, else: Phoenix.Router
    Request.build(source, call: {router, route}, scope: scope)
  end

  defp labels(items), do: Enum.map(items, & &1.label)

  defp existing_atom?(name) do
    String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
