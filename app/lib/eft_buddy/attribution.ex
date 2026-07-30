defmodule EftBuddy.Attribution do
  @moduledoc """
  The upstream sources whose material EFT Buddy renders, and the licence each
  one carries.

  Read by `EftBuddyWeb.CoreComponents.source_credit/1`, which renders the
  credit line beside the content itself. Keeping creator, licence name and
  licence URL together as data — rather than as prose repeated in each
  template — is what stops the same source being credited two different ways
  in two different places.

  ## Only what gets rendered lives here

  Both entries below are ShareAlike-licensed, which means attribution is a
  condition of the grant rather than a courtesy: drop the credit and the
  licence lapses. Those are the two that need to reach the screen, so those
  are the two this module holds.

  Obligations that are satisfied by a file rather than by the UI are recorded
  where that file lives, not here:

    * the **MIT** notice for the map projection config copied from
      tarkov.dev — reproduced in full in
      `priv/static/images/maps/ATTRIBUTION.md`, as MIT requires
    * the **SIL OFL** typefaces — `priv/static/fonts/README.md`
    * the vendored SVGs' ShareAlike / NonCommercial / prohibited-use terms —
      `priv/static/images/maps/ATTRIBUTION.md`
    * **tarkov.dev's API data**, which carries no published data licence at
      all, so nothing is owed for it

  The full licence research behind these — including why the wiki's licence is
  pinned at 3.0 when the wiki itself no longer states a version — is in
  `docs/attribution/CONTEXT.md`.

  ## What a wiki can and cannot license

  The Escape from Tarkov Wiki licenses the material *it may lawfully license*:
  the prose its contributors wrote. It cannot sublicense Battlestate Games'
  intellectual property, so the game screenshots and extracted icons hosted
  there are **not** covered by CC BY-NC-SA. Never label those with a CC
  licence — asserting a grant nobody made is worse than showing no credit at
  all. The site-wide disclaimer in the footer covers them instead.

  ## Why the wiki licence is pinned at 3.0

  The wiki's footer now reads "CC BY-NC-SA" with no version. That is a
  Fandom-wide presentation change from January 2023, not a relicensing: the
  footer read "CC BY-NC-SA 3.0" until then, and the wiki's own copyright page
  named "3.0 Unported" outright until it was deleted in April 2023. Its text
  survives in that page's public deletion log and in Internet Archive
  captures. 3.0 and 4.0 differ in ways that matter to anyone reusing content
  from here, so the version is recorded rather than dropped.
  """

  @type t :: %{
          id: atom(),
          name: String.t(),
          url: String.t(),
          creator: String.t(),
          license: String.t(),
          license_url: String.t()
        }

  @wiki %{
    id: :eft_wiki,
    name: "Escape from Tarkov Wiki",
    url: "https://escapefromtarkov.fandom.com/wiki/Escape_from_Tarkov_Wiki",
    creator: "Escape from Tarkov Wiki contributors",
    license: "CC BY-NC-SA 3.0",
    license_url: "https://creativecommons.org/licenses/by-nc-sa/3.0/"
  }

  # The vendored interactive base maps. The strictest licence we build on:
  # ShareAlike means our restyled copies stay under it, and the upstream README
  # adds an explicit prohibition on use in cheating tools (radar/ESP overlays,
  # pixel-bots) that revokes the grant automatically. That clause is the reason
  # the map viewer must stay static reference material with no game
  # integration — see `priv/static/images/maps/ATTRIBUTION.md`.
  @svg_maps %{
    id: :svg_maps,
    name: "Escape from Tarkov SVG Maps Project",
    url: "https://github.com/the-hideout/tarkov-dev-svg-maps",
    # The project, not an individual — the repo has many contributors and
    # singling any out under-credits the rest and goes stale as it moves on. The
    # linked repo is the authoritative list.
    #
    # This used to be the *whole* credit, which left the artist maps.json names
    # for each map unmentioned. The credit line now leads with that author and
    # follows it with this, so the named creator and the full contributor list
    # are both reachable. No leading article: it reads mid-line now.
    creator: "tarkov-dev-svg-maps contributors",
    license: "CC BY-NC-SA 4.0",
    license_url: "https://creativecommons.org/licenses/by-nc-sa/4.0/"
  }

  @doc """
  The Escape from Tarkov Wiki — quest guides, storyline chapters, event notes.

  The default source for `source_credit/1`, since the wiki is what most
  credited content comes from.
  """
  @spec wiki() :: t()
  def wiki, do: @wiki

  @doc "The hand-drawn base maps vendored into the interactive map viewer."
  @spec svg_maps() :: t()
  def svg_maps, do: @svg_maps
end
