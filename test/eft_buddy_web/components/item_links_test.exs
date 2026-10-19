defmodule EftBuddyWeb.ItemLinksTest do
  @moduledoc """
  Item links must survive the characters item names actually contain (audit M14).

  `"/items?q=" <> URI.encode(name)` keeps reserved characters as they are, so
  "#FireKlean gun lube" became a URL fragment and linked to the unfiltered
  catalogue; `&` and `+` cut or altered the query the same way.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EftBuddyWeb.UI

  doctest EftBuddyWeb.UI, only: [item_search_url: 1]

  test "names with #, & and + round-trip through the query string" do
    for name <- [
          "#FireKlean gun lube",
          "Salt & Pepper",
          "Ibuprofen+",
          "Can of Majaica coffee beans"
        ] do
      %URI{query: query} = URI.parse(UI.item_search_url(name))
      assert URI.decode_query(query) == %{"q" => name}
    end
  end

  test "an item tile links to its own search" do
    html =
      render_component(&UI.item_tile/1,
        item: %{name: "#FireKlean gun lube", short_name: "Lube", icon_link: nil},
        link: true
      )

    [href] = Regex.run(~r/href="([^"]+)"/, html, capture: :all_but_first)
    %URI{query: query} = URI.parse(href |> String.replace("&amp;", "&"))

    assert URI.decode_query(query) == %{"q" => "#FireKlean gun lube"}
  end

  test "a missing name links to the whole catalogue" do
    assert UI.item_search_url(nil) == "/items"
  end
end
