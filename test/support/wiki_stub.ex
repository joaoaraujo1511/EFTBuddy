defmodule EftBuddy.WikiStub do
  @moduledoc """
  A fake Fandom wiki behind `Req.Test`, answering the MediaWiki queries the three
  scrapers send (`EftBuddy.Wiki.Api`, `Contributors`, `FileLicense`).

      WikiStub.serve(%{
        categories: %{"Category:Quests" => ["Golden Swag"]},
        pages: %{"Golden Swag" => WikiStub.page(revid: 7, sections: [{"Guide", "guide text"}])},
        files: %{"File:Swag.png" => %{user: "Uploader"}},
        fail: fn params -> params["section"] == "1" end
      })

  `:fail` receives each request's query parameters; returning true answers that
  request with a 503, which is how the tests inject a transient failure.
  `:api_error` does the same with an HTTP 200 carrying an `error` body.
  `:page_size` splits category listings into pages joined by `cmcontinue`.
  `:observe` is called with every request's parameters, for counting requests.
  """

  @doc """
  A page. `lead` is section 0's wikitext; `sections` are `{heading, wikitext}`
  pairs numbered from 1. `contributors` are the named editors.
  """
  def page(opts \\ []) do
    sections = Keyword.get(opts, :sections, [])

    %{
      revid: Keyword.get(opts, :revid, 1),
      lead: Keyword.get(opts, :lead, "{{Infobox quest\n|given by=[[Prapor]]\n}}\nLead text."),
      sections:
        sections
        |> Enum.with_index(1)
        |> Enum.map(fn {{heading, text}, i} -> %{index: "#{i}", heading: heading, text: text} end),
      full: Keyword.get(opts, :full),
      contributors: Keyword.get(opts, :contributors, ["Editor"])
    }
  end

  @doc "Route every wiki request in the calling test to `wiki`."
  def serve(wiki) do
    Req.Test.stub(EftBuddy.Wiki.DumpScript, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      params = conn.query_params
      Map.get(wiki, :observe, fn _ -> :ok end).(params)

      cond do
        Map.get(wiki, :fail, fn _ -> false end).(params) ->
          Plug.Conn.send_resp(conn, 503, "Service Unavailable")

        # MediaWiki's other way of failing: HTTP 200 with an `error` body.
        Map.get(wiki, :api_error, fn _ -> false end).(params) ->
          Req.Test.json(conn, %{"error" => %{"code" => "ratelimited", "info" => "slow down"}})

        true ->
          Req.Test.json(conn, answer(params, wiki))
      end
    end)
  end

  defp answer(%{"action" => "query", "list" => "categorymembers"} = p, wiki) do
    titles = get_in(wiki, [:categories, p["cmtitle"]]) || []
    size = Map.get(wiki, :page_size, 500)
    offset = String.to_integer(p["cmcontinue"] || "0")
    slice = Enum.slice(titles, offset, size)
    body = %{"query" => %{"categorymembers" => Enum.map(slice, &%{"title" => &1})}}

    if offset + size < length(titles),
      do: Map.put(body, "continue", %{"cmcontinue" => "#{offset + size}"}),
      else: body
  end

  defp answer(%{"action" => "query", "prop" => "revisions", "rvprop" => "ids"} = p, wiki) do
    pages(p, fn title ->
      case wiki_page(wiki, title) do
        nil -> %{"title" => title, "missing" => true}
        page -> %{"title" => title, "revisions" => [%{"revid" => page.revid}]}
      end
    end)
  end

  defp answer(%{"action" => "query", "prop" => "revisions"} = p, wiki) do
    pages(p, fn title ->
      case get_in(wiki, [:files, title]) do
        nil ->
          %{"title" => title, "missing" => true}

        file ->
          content = Map.get(file, :page, "")
          %{"title" => title, "revisions" => [%{"slots" => %{"main" => %{"content" => content}}}]}
      end
    end)
  end

  defp answer(%{"action" => "query", "prop" => "imageinfo"} = p, wiki) do
    pages(p, fn title ->
      case get_in(wiki, [:files, title]) do
        nil ->
          %{"title" => title, "missing" => true}

        file ->
          name = String.replace_prefix(title, "File:", "")

          %{
            "title" => title,
            "imageinfo" => [
              %{
                "url" => "https://static.wikia.example/#{name}",
                "descriptionurl" => "https://wiki.example/wiki/#{title}",
                "width" => 100,
                "height" => 100,
                "mime" => "image/png",
                "user" => Map.get(file, :user, "Uploader")
              }
            ]
          }
      end
    end)
  end

  defp answer(%{"action" => "query", "prop" => "contributors"} = p, wiki) do
    pages(p, fn title ->
      case wiki_page(wiki, title) do
        nil ->
          %{"title" => title, "missing" => true}

        page ->
          %{"title" => title, "contributors" => Enum.map(page.contributors, &%{"name" => &1})}
      end
    end)
  end

  defp answer(%{"action" => "parse", "prop" => "sections", "page" => title}, wiki) do
    case wiki_page(wiki, title) do
      nil ->
        missing(title)

      page ->
        %{
          "parse" => %{
            "sections" =>
              Enum.map(
                page.sections,
                &%{"index" => &1.index, "line" => &1.heading, "level" => "2"}
              )
          }
        }
    end
  end

  defp answer(%{"action" => "parse", "prop" => "wikitext", "page" => title} = p, wiki) do
    case wiki_page(wiki, title) do
      nil ->
        missing(title)

      page ->
        text =
          case p["section"] do
            nil ->
              page.full ||
                Enum.map_join([page.lead | Enum.map(page.sections, & &1.text)], "\n", & &1)

            "0" ->
              page.lead

            i ->
              Enum.find_value(
                page.sections,
                "",
                &(&1.index == i && "==#{&1.heading}==\n#{&1.text}")
              )
          end

        %{"parse" => %{"wikitext" => text}}
    end
  end

  defp answer(params, _wiki),
    do: %{
      "error" => %{"code" => "badquery", "info" => "stub has no answer for #{inspect(params)}"}
    }

  defp pages(params, fun) do
    titles = params |> Map.get("titles", "") |> String.split("|", trim: true)
    %{"query" => %{"pages" => Enum.map(titles, fun)}}
  end

  defp wiki_page(wiki, title), do: get_in(wiki, [:pages, title])

  defp missing(title),
    do: %{"error" => %{"code" => "missingtitle", "info" => "The page #{title} doesn't exist."}}
end
