defmodule EftBuddy.TarkovFixtures do
  @moduledoc """
  Serves the trimmed tarkov.dev documents in test/fixtures/tarkov/ to
  `EftBuddy.TarkovApi` through `Req.Test`, so tests drive the real adapter with
  payloads that came from the live API rather than hand-made maps that agree
  with the code by construction.

  `stub/0` answers `/<mode>/<doc>` from `test/fixtures/tarkov/<mode>/<doc>.json`
  and counts each request, so a test can assert how often a document was
  fetched. An unknown path is a 404, which the adapter reports as an error.
  `stub(%{path => status})` answers those paths with that status instead, to
  simulate one upstream failing while the rest answer.
  """

  @dir Path.expand("../fixtures/tarkov", __DIR__)

  @doc "Install the fixture stub for the calling test process."
  def stub(failing \\ %{}) do
    counter = :counters.new(1, [])
    paths = Agent.start_link(fn -> [] end) |> elem(1)

    Req.Test.stub(EftBuddy.TarkovApi, fn conn ->
      :counters.add(counter, 1, 1)
      Agent.update(paths, &[conn.request_path | &1])

      case {failing[conn.request_path], File.read(fixture_path(conn.request_path))} do
        {status, _} when is_integer(status) ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(status, "simulated failure")

        {nil, {:ok, body}} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)

        {nil, {:error, _}} ->
          Plug.Conn.send_resp(conn, 404, "no fixture for #{conn.request_path}")
      end
    end)

    %{
      requests: fn -> :counters.get(counter, 1) end,
      paths: fn -> Agent.get(paths, &Enum.reverse/1) end
    }
  end

  @doc "The request path of tarkov.dev's frontend `maps.json`."
  def maps_media_path, do: "/the-hideout/tarkov-dev/main/src/data/maps.json"

  # tarkov.dev's frontend `maps.json` (map imagery) is fetched from GitHub
  # rather than the JSON API, so it has its own file.
  defp fixture_path("/the-hideout/tarkov-dev/main/src/data/maps.json"),
    do: Path.join(@dir, "maps_media.json")

  defp fixture_path(request_path), do: Path.join(@dir, request_path <> ".json")

  @doc "A fixture document, decoded."
  def doc(mode, name),
    do: Path.join([@dir, mode, name <> ".json"]) |> File.read!() |> Jason.decode!()
end
