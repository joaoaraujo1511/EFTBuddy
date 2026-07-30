defmodule EftBuddy.Armor.Material do
  @moduledoc """
  Armor material reference: display labels and the **destructibility**
  factor for each material, from the tarkov.dev JSON API's
  `data.armorMaterials`.

  Destructibility is a hidden in-game stat that governs how fast a plate
  degrades under fire — the lower it is, the tougher the plate for the
  same raw durability. The community "effective durability" metric

      Effective Durability = durability / destructibility

  normalises plates of different materials onto a comparable toughness
  scale (e.g. a 60-durability Ceramic plate and a 50-durability steel
  plate both work out to ~100 effective durability).

  These values are static (they change at most on a game patch), so they
  live here rather than in the DB — same approach as `Ammo.Caliber`.
  """

  # material token => destructibility (from data.armorMaterials). Used for
  # bullet hits — the toughness normaliser behind "effective durability".
  @destructibility %{
    "Aramid" => 0.1875,
    "UHMWPE" => 0.3375,
    "Combined" => 0.375,
    "Titan" => 0.4125,
    "Aluminium" => 0.45,
    "ArmoredSteel" => 0.525,
    "Ceramic" => 0.6,
    "Glass" => 0.6
  }

  # material token => explosive destructibility (from data.armorMaterials).
  # Grenade / blast damage degrades a plate at this rate instead of the
  # bullet-hit destructibility above.
  @explosive_destructibility %{
    "Aramid" => 0.15,
    "UHMWPE" => 0.3,
    "Combined" => 0.2,
    "Titan" => 0.375,
    "Aluminium" => 0.45,
    "ArmoredSteel" => 0.45,
    "Ceramic" => 0.525,
    "Glass" => 0.6
  }

  # Display order for the materials reference table: softest (toughest per
  # point of durability) → hardest, matching the community/wiki listing.
  @order ~w(Aramid UHMWPE Combined Titan Aluminium ArmoredSteel Ceramic Glass)

  # Human display label for the material tokens that aren't already
  # reader-friendly.
  @labels %{
    "ArmoredSteel" => "Armored Steel",
    "Combined" => "Combined Materials"
  }

  @doc "Destructibility factor for a material token, or `nil` if unknown."
  @spec destructibility(String.t() | nil) :: float() | nil
  def destructibility(material), do: Map.get(@destructibility, material)

  @doc "Explosive destructibility factor for a material token, or `nil` if unknown."
  @spec explosive_destructibility(String.t() | nil) :: float() | nil
  def explosive_destructibility(material), do: Map.get(@explosive_destructibility, material)

  @doc """
  Effective durability of a plate: `durability / destructibility`, rounded
  to a whole number. Falls back to the raw durability if the material is
  unknown (so a new patch material never blanks the column).
  """
  @spec effective_durability(integer() | nil, String.t() | nil) :: integer() | nil
  def effective_durability(nil, _material), do: nil

  def effective_durability(durability, material) when is_integer(durability) do
    case destructibility(material) do
      nil -> durability
      factor -> round(durability / factor)
    end
  end

  @doc "Human display label for a material token (e.g. `ArmoredSteel` -> `Armored Steel`)."
  @spec label(String.t() | nil) :: String.t()
  def label(material) when is_binary(material), do: Map.get(@labels, material, material)
  def label(_), do: "Unknown"

  @doc """
  The full armor-material reference, in display order, as a list of maps:

      %{token:, label:, destructibility:, explosive_destructibility:}

  Backs the "Armor materials & durability" reference table on the
  Ballistics page — the same destructibility figures used for the
  effective-durability column, laid out so a player can see how fast each
  material degrades under bullets vs. explosions.
  """
  @spec reference() :: [
          %{
            token: String.t(),
            label: String.t(),
            destructibility: float(),
            explosive_destructibility: float()
          }
        ]
  def reference do
    Enum.map(@order, fn token ->
      %{
        token: token,
        label: label(token),
        destructibility: destructibility(token),
        explosive_destructibility: explosive_destructibility(token)
      }
    end)
  end
end
