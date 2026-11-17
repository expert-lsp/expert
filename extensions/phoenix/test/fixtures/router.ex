# The source of a router, which the tests read without compiling it.
defmodule ExpertPhoenix.Test.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias ExpertPhoenix.Test.Web.HealthPlug, as: Health

  scope "/", ExpertPhoenix.Test.Web do
    get "/", PageController, :index
    get "/pages/:id", PageController, :show

    scope "/admin", Admin do
      get "/users", UserController, :index
    end

    live "/dashboard", DashboardLive
  end

  scope "/plain" do
    get "/", ExpertPhoenix.Test.Web.PageController, :index
    forward "/health", Health

    resources "/users", ExpertPhoenix.Test.Web.Admin.UserController do
      get "/pages", ExpertPhoenix.Test.Web.PageController, :index
    end
  end
end
