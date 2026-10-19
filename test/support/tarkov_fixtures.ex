defmodule EftBuddy.TarkovFixtures do
  @moduledoc """
  Serves the trimmed tarkov.dev documents in test/fixtures/tarkov/ to
  `EftBuddy.TarkovApi` through `Req.Test`, so tests drive the real adapter with
  payloads that came from the live API rather than hand-made maps that agree
  with the code by construction.

  `stub/0` answers `/<mode>/<doc>` from `test/fixtures/tarkov/<mode>/<doc>.json`
  and counts each request, so a test can assert how often a document was
  fetched. An unknown path is a 404, which the adapter reports as an error.
  """

  @dir Path.expand("../fixtures/tarkov", __DIR__)

  @doc "Install the fixture stub for the calling test process."
  def stub do
    counter = :counters.new(1, [])
    paths = Agent.start_link(fn -> [] end) |> elem(1)

    Req.Test.stub(EftBuddy.TarkovApi, fn conn ->
      :counters.add(counter, 1, 1)
      Agent.update(paths, &[conn.request_path | &1])

      case File.read(Path.join(@dir, conn.request_path <> ".json")) do
        {:ok, body} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)

        {:error, _} ->
          Plug.Conn.send_resp(conn, 404, "no fixture for #{conn.request_path}")
      end
    end)

    %{
      requests: fn -> :counters.get(counter, 1) end,
      paths: fn -> Agent.get(paths, &Enum.reverse/1) end
    }
  end

  @doc "A fixture document, decoded."
  def doc(mode, name),
    do: Path.join([@dir, mode, name <> ".json"]) |> File.read!() |> Jason.decode!()
end
