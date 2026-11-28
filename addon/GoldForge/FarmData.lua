-- Gold Forge: the farm database for Gold Guide.
-- Source: your own research notes (Horde Hunter 60, EU PvP), collected 19-27 Nov 2026.
--   drop chances = Classic data assumed carried into Forever; coordinates are approximate.
--   est = your g/h estimates at 110-170 kills/h (expect 10-20% less in contested PvP zones).
-- Prices are never stored here: Gold Guide reads live TSM prices.
-- mobs = name parts used to recognise which farm a session was (matched against the mobs you kill).
local _, FF = ...

FF.FarmData = {
  -- ---------- open world, no profession ----------
  { id = "silithus_air_earth", name = "NW Silithus: Air + Earth", zone = "Silithus", area = "North-west, Crystal Vale area",
    mobs = { "Cyclone Warrior", "Desert Rager", "Desert Rumbler" }, cat = "Elemental",
    drops = { { 7082, 4.5 }, { 7076, 3.3 } }, est = { 20, 35 },
    notes = "Main no-skin farm. Air price has been falling: sell continuously, repost when undercut. Earth 3.3% from Ragers, 2.2% from Rumblers." },
  { id = "felwood_fire", name = "Felwood: Fire", zone = "Felwood", area = "Entropic Horrors",
    mobs = { "Entropic Horror" }, cat = "Elemental",
    drops = { { 7078, 2.7 }, { 7077, 6.5 }, { 7068, 6.3 } }, est = { 25, 33 },
    notes = "Bank the fire mats and sell in raid week (from 9 Dec)." },
  { id = "winterspring_icy_chill", name = "Winterspring lake: Icy Chill", zone = "Winterspring", area = "The lake (Mazthoril / Darkwhisper area: confirm)",
    mobs = { "Anguished Highborne" }, cat = "Formula lottery",
    drops = { { 12808, 7.5 } }, est = { 20, 20 },
    notes = "Formula: Enchant Weapon - Icy Chill (item ID not confirmed) plus 3 chest spawns. Contested zone. List formulas high; check the AH first." },
  { id = "deadwind_pass", name = "Deadwind Pass", zone = "Deadwind Pass", area = "Warlocks and undead",
    mobs = { "Deadwind" }, cat = "Formula lottery",
    drops = { { 14047 } }, est = { 20, 20 },
    notes = "Formula: Superior Strength (item ID not confirmed). List formulas high; check the AH first." },
  { id = "silithus_scorpions", name = "Silithus scorpions", zone = "Silithus", area = "Scorpids",
    mobs = { "Stonelash Pincer", "Stonelash Flayer" }, drops = { { 19933, 26 } }, cat = "Vendor", est = { 15, 22 },
    notes = "Glowing Scorpid Blood vendors for 11s 80c in Forever (20s 80c in Classic), so the 15-22g in your notes is about 40% too high. 26% from Stonelash Pincers and Flayers (Forever loot logs)." },
  { id = "epl_bats", name = "EPL bats", zone = "Eastern Plaguelands", area = "Bats",
    mobs = { "Plaguebat", "Duskwing", "bat" }, drops = { { 11404, 28.5 } }, cat = "Vendor", est = { 15, 22 },
    notes = "Evil Bat Eye: about 28% from Monstrous Plaguebats and Duskwings. Vendor value is read from the game." },
  { id = "wpl_spiders", name = "WPL spiders", zone = "Western Plaguelands", area = "All spiders",
    mobs = { "Plague Lurker", "Spider", "Webweaver", "Crypt" }, cat = "Filler",
    drops = { { 14227, 14 } }, est = { 15, 20 } },
  { id = "hederine_initiate", name = "Hederine Initiates (elite)", zone = "Winterspring", area = "Hederine Initiates",
    mobs = { "Hederine Initiate" }, cat = "Cloth",
    drops = { { 14256, 8.5 } },
    notes = "About 21s per kill. A Hunter can solo the elites." },
  { id = "blackmaw_hold", name = "Blackmaw Hold Devotees", zone = "Winterspring", area = "Blackmaw Hold",
    mobs = { "Blackmaw" }, cat = "Dead", status = "dead", est = { 0, 0 },
    notes = "Loot removed by the 16 Nov hotfix. Don't farm here." },

  { id = "winterspring_watery", name = "Watery Invaders: Essence of Water", zone = "Winterspring", area = "Watery Invaders",
    mobs = { "Watery Invader" }, cat = "Elemental", lvl = 57, drops = { { 7080, 5.2 } } },
  { id = "wpl_decaying_horror", name = "Decaying Horrors: Living Essence", zone = "Western Plaguelands", area = "North-east",
    mobs = { "Decaying Horror" }, cat = "Elemental", lvl = 56, drops = { { 12803, 6.3 } },
    notes = "Dire Maul's Death Lash (elite) drops it more often (9%)." },

  -- ---------- skinning ----------
  { id = "tanaris_snappers", name = "Steeljaw Snappers", zone = "Tanaris", area = "East coast", mobs = { "Steeljaw Snapper" },
    cat = "Skinning", skill = { 210, 225 }, drops = { { 8167 }, { 4304 } }, est = { 20, 20 },
    notes = "Skill-levelling (215-225). Train Artisan at 225." },
  { id = "tanaris_surf_gliders", name = "Surf Gliders", zone = "Tanaris", area = "Southern tip", mobs = { "Surf Glider" },
    cat = "Skinning", skill = { 225, 265 }, drops = { { 8167, 15 }, { 4304 } }, est = { 20, 25 },
    notes = "Skill-levelling 225-265." },
  { id = "wpl_black_bears", name = "Diseased Black Bears", zone = "Western Plaguelands", area = "Loop from The Bulwark",
    mobs = { "Diseased Black Bear" }, cat = "Skinning", skill = { 265, 280 }, drops = { { 8170 }, { 4304 }, { 8171 } }, est = { 25, 35 },
    route = { { 37, 56, "Felstone Field" }, { 46, 52, "Dalson's Tears" }, { 53, 65, "Writhing Haunt" }, { 50, 80, "Sorrow Hill" } },
    notes = "About 20-25s per kill. No Warbear Leather from these. Skill-ups to about 280. Avoid Chillwind Camp (Alliance)." },
  { id = "wpl_grizzlies", name = "Diseased Grizzlies", zone = "Western Plaguelands", area = "East of Dalson's Tears",
    mobs = { "Diseased Grizzly" }, cat = "Skinning", skill = { 275, 300 }, drops = { { 8170 } },
    route = { { 53, 48, "East of Dalson's Tears" } },
    notes = "Don't confuse with the Black Bears. g/h not measured yet." },
  { id = "ungoro_devilsaur", name = "Devilsaurs (elite)", zone = "Un'Goro Crater", area = "Devilsaurs",
    mobs = { "Devilsaur" }, cat = "Skinning", skill = { 280, 300 }, drops = { { 15417 } }, est = { 43, 60 },
    notes = "Best farm at 280+. Kite at range, Feign Death if needed. Check Nergal (Marshal's Refuge) for the Devilsaur Gauntlets pattern." },
  { id = "winterspring_frostsaber", name = "Frostsabers", zone = "Winterspring", area = "Frostsabers",
    mobs = { "Frostsaber" }, cat = "Skinning", skill = { 275, 300 }, drops = { { 15422 }, { 8170 } }, est = { 29, 39 },
    notes = "Frostsaber Leather has crashed (38s -> 11s)." },
  { id = "winterspring_shardtooth", name = "Rabid Shardtooths", zone = "Winterspring", area = "Shardtooths",
    mobs = { "Shardtooth" }, cat = "Skinning", skill = { 290, 300 }, drops = { { 15419 }, { 8170 } },
    notes = "Check the Warbear Leather price first. g/h not measured yet." },
  { id = "bs_dragonkin", name = "Black dragonkin", zone = "Burning Steppes", area = "Black whelps and drakes",
    mobs = { "Black Drake", "Black Whelp", "Black Broodling", "Black Dragonspawn", "Black Wyrmkin" }, cat = "Skinning",
    skill = { 275, 300 }, drops = { { 15416 }, { 8170 } }, est = { 29, 43 },
    notes = "Dragonscale price is volatile." },
  { id = "bs_firetail_scorpid", name = "Firetail Scorpids", zone = "Burning Steppes", area = "Firetail Scorpids",
    mobs = { "Firetail Scorpid" }, cat = "Skinning", skill = { 260, 300 }, drops = { { 15408 } }, est = { 28, 37 },
    notes = "Scale price has fallen (26s -> 13s)." },
  { id = "silithus_stonelash", name = "Stonelash Scorpids", zone = "Silithus", area = "Stonelash Scorpids",
    mobs = { "Stonelash Scorpid" }, cat = "Skinning", skill = { 270, 300 }, drops = { { 15408 } },
    notes = "Not worth it at the current scale price." },

  -- ---------- dungeons, groups, weekly ----------
  { id = "dm_north_tribute", name = "Dire Maul North Tribute (solo)", zone = "Dire Maul", area = "Feralas",
    cat = "Dungeon", est = { 50, 75 },
    notes = "Claimed 50-75 g/h. Hard to learn (Feign Death resists). Worth it once a run takes under 30 min. Dungeon resets capped at 5/hour (21 Nov hotfix)." },
  { id = "strat_righteous_orbs", name = "Stratholme Live: Righteous Orbs", zone = "Stratholme", area = "Scarlet side",
    mobs = { "Crimson" }, cat = "Dungeon (duo)", drops = { { 12811 } }, est = { 50, 80 },
    notes = "Needs a partner. Crimson mobs." },
  { id = "weekly_elven_curiosities", name = "Weekly: Ancient Elven Curiosities", zone = "Booty Bay", area = "Pix Xizzix, southern docks",
    cat = "Weekly (group)", weekly = 24,
    notes = "All 3 Dire Maul wings. Satchel: Gold Nugget 10g 40%, Huge Quartz Gem 20g 35%, Silver Necklace 40g 20%, Gold Ring 100g 5%. About 24g a week on average. Resets Tuesday." },
  { id = "quests_48plus", name = "Leftover quests, level 48+", zone = "Anywhere", cat = "One-time",
    notes = "Since the 10 Nov hotfix most 48+ quests give gold. One-time." },

  -- ---------- fishing ----------
  { id = "hyjal_gem_fish", name = "Gem Fish", zone = "Mount Hyjal", cat = "Fishing", est = { 10, 20 },
    notes = "Low effort; beta-era report. Item ID not confirmed." },
}

-- what to farm for your skinning skill (your progression table)
FF.FarmSkinning = {
  { 0, 224, "tanaris_snappers" }, { 225, 264, "tanaris_surf_gliders" }, { 265, 279, "wpl_black_bears" }, { 280, 999, "ungoro_devilsaur" },
}
FF.FarmNoSkinning = "silithus_air_earth"

-- your weekly rotation (2-hour sessions); [1] = Sunday as in date("%w")+1
FF.FarmRotation = {
  "Felwood Fire (1h) + flex",
  "NW Silithus Air + Earth",
  "Weekly Elven Curiosities + Felwood Fire (1h); check Qia",
  "Dire Maul North Tribute practice, or NW Silithus",
  "Deadwind Pass (1h) + Silithus scorpions (1h)",
  "AH day: repost undercuts, sell Air/Earth, keep the fire mats",
  "NW Silithus or Devilsaurs (check Nergal)",
}

-- vendor and pattern checks
FF.FarmReminders = {
  "Qia (Everlook): limited Runecloth Bag pattern",
  "Nergal (Marshal's Refuge, Un'Goro): Devilsaur Gauntlets pattern",
  "Lokhtos Darkbargainer (Grim Guzzler, BRD): Elemental Flux about 3g at the vendor, more on the AH",
}
