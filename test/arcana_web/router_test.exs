defmodule ArcanaWeb.RouterTest do
  use ExUnit.Case, async: true

  describe "router" do
    test "defines dashboard route" do
      # The router should define a live route at /
      routes = ArcanaWeb.Router.__routes__()

      assert Enum.any?(routes, fn route ->
               route.path == "/" and route.plug == Phoenix.LiveView.Plug
             end)
    end
  end
end
