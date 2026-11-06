defmodule EftBuddyWeb.EndpointStaticTest do
  # Not async: these write real files into the directory Plug.Static serves.
  use EftBuddyWeb.ConnCase, async: false

  # `phx.digest` output is gitignored, so it exists in the production image but
  # not in CI. Each test writes the one file it needs.
  defp write_static!(name, contents) do
    path = Application.app_dir(:eft_buddy, Path.join("priv/static", name))
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
  end

  test "serves the digested favicon the root layout links to", %{conn: conn} do
    name = "favicon-00000000000000000000000000000000.ico"
    write_static!(name, "icon")

    assert conn |> get("/" <> name) |> response(200) == "icon"
  end

  test "does not serve other files from the static root", %{conn: conn} do
    name = "unlisted-probe.txt"
    write_static!(name, "private")

    refute conn |> get("/" <> name) |> response(404) =~ "private"
  end
end
