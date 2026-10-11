defmodule ExpertPhoenix.Test.Web.PageController do
  @moduledoc false

  def init(options), do: options
  def call(conn, _options), do: conn
  def action(conn, _options), do: conn
  def index(conn, _params), do: conn
  def show(conn, _params), do: conn
end

defmodule ExpertPhoenix.Test.Web.Admin.UserController do
  @moduledoc false

  def init(options), do: options
  def call(conn, _options), do: conn
  def action(conn, _options), do: conn
  def index(conn, _params), do: conn
end

defmodule ExpertPhoenix.Test.Web.DashboardLive do
  @moduledoc false

  def __live__, do: %{kind: :view}
end

defmodule ExpertPhoenix.Test.Web.HealthPlug do
  @moduledoc false

  def init(options), do: options
  def call(conn, _options), do: conn
end
