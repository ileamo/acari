defmodule AcariTest do
  use ExUnit.Case
  doctest Acari

  test "greets the world" do
    assert Acari.hello() == :world
  end
end
