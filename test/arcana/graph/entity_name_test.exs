defmodule Arcana.Graph.EntityNameTest do
  use ExUnit.Case, async: true

  doctest Arcana.Graph.EntityName

  alias Arcana.Graph.EntityName

  describe "normalize/1" do
    test "returns nil for nil" do
      assert EntityName.normalize(nil) == nil
    end

    test "case-folds, converts separators and collapses runs" do
      assert EntityName.normalize("Two_Year--Limited   Warranty") == "two year limited warranty"
    end

    # The Ecto store normalizes in SQL, where Postgres' `\s` matches the
    # Unicode space separators. Elixir's `\s` matches ASCII only, so an
    # unqualified `~r/\s+/` here made the two backends disagree about which
    # names are the same entity. Both sides now use the Unicode
    # White_Space set.
    for {label, name} <- [
          {"tab", "Acme\tCorp"},
          {"newline", "Acme\nCorp"},
          {"NEL", "Acme\u{85}Corp"},
          {"NBSP", "Acme\u{a0}Corp"},
          {"ogham space mark", "Acme\u{1680}Corp"},
          {"en quad", "Acme\u{2000}Corp"},
          {"thin space", "Acme\u{2009}Corp"},
          {"line separator", "Acme\u{2028}Corp"},
          {"narrow NBSP", "Acme\u{202f}Corp"},
          {"medium mathematical space", "Acme\u{205f}Corp"},
          {"ideographic space", "Acme\u{3000}Corp"}
        ] do
      test "collapses a #{label} like a plain space" do
        assert EntityName.normalize(unquote(name)) == "acme corp"
      end
    end

    test "trims unicode whitespace at both edges" do
      assert EntityName.normalize("\u{3000}Delivery\u{a0}") == "delivery"
    end

    # Not whitespace: these carry meaning in the scripts that use them and
    # neither backend strips them.
    test "leaves zero-width characters alone" do
      assert EntityName.normalize("Acme\u{200b}Corp") == "acme\u{200b}corp"
    end
  end
end
