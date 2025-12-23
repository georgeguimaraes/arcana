defmodule ArcanaTest do
  use ExUnit.Case
  doctest Arcana

  test "greets the world" do
    assert Arcana.hello() == :world
  end
end
