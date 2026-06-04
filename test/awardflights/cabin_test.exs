defmodule Awardflights.CabinTest do
  use ExUnit.Case, async: true

  alias Awardflights.Cabin

  describe "format_name/1" do
    test "title-cases single-word cabins" do
      assert Cabin.format_name("ECONOMY") == "Economy"
      assert Cabin.format_name("BUSINESS") == "Business"
    end

    test "title-cases every word of multi-word cabins" do
      assert Cabin.format_name("PREMIUM ECONOMY") == "Premium Economy"
    end

    test "normalizes underscores to spaces" do
      assert Cabin.format_name("PREMIUM_ECONOMY") == "Premium Economy"
    end

    test "is idempotent on already-formatted names" do
      assert Cabin.format_name("Premium Economy") == "Premium Economy"
    end

    test "falls back to Unknown for non-binary input" do
      assert Cabin.format_name(nil) == "Unknown"
      assert Cabin.format_name(%{}) == "Unknown"
    end
  end
end
