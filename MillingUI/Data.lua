---
-- MillingUI: herb -> pigment table for 3.3.5a.
-- The client has no API for "is this item millable" or "what does it mill into",
-- so the milling_loot_template knowledge lives here. `skill` is the Inscription
-- rank the server checks before letting you mill that herb.

local _, private = ...;

-- Groups are shown as headers in the list, in this order.
private.groups = {
	{
		skill = 1,
		pigment = 39151, pigmentName = "Alabaster Pigment",
		herbs = {
			{ id = 2447, name = "Peacebloom" },
			{ id = 765,  name = "Silverleaf" },
			{ id = 2449, name = "Earthroot" },
		},
	},
	{
		skill = 25,
		pigment = 39334, pigmentName = "Dusky Pigment",
		rare = 43103, rareName = "Verdant Pigment",
		herbs = {
			{ id = 785,  name = "Mageroyal" },
			{ id = 2450, name = "Briarthorn" },
			{ id = 2452, name = "Swiftthistle" },
			{ id = 2453, name = "Bruiseweed" },
			{ id = 3820, name = "Stranglekelp" },
		},
	},
	{
		skill = 75,
		pigment = 39338, pigmentName = "Golden Pigment",
		rare = 43104, rareName = "Burnt Pigment",
		herbs = {
			{ id = 3355, name = "Wild Steelbloom" },
			{ id = 3369, name = "Grave Moss" },
			{ id = 3356, name = "Kingsblood" },
			{ id = 3357, name = "Liferoot" },
		},
	},
	{
		skill = 125,
		pigment = 39339, pigmentName = "Emerald Pigment",
		rare = 43105, rareName = "Indigo Pigment",
		herbs = {
			{ id = 3818, name = "Fadeleaf" },
			{ id = 3821, name = "Goldthorn" },
			{ id = 3358, name = "Khadgar's Whisker" },
			{ id = 3819, name = "Wintersbite" },
		},
	},
	{
		skill = 175,
		pigment = 39340, pigmentName = "Violet Pigment",
		rare = 43106, rareName = "Ruby Pigment",
		herbs = {
			{ id = 4625, name = "Firebloom" },
			{ id = 8831, name = "Purple Lotus" },
			{ id = 8836, name = "Arthas' Tears" },
			{ id = 8838, name = "Sungrass" },
			{ id = 8839, name = "Blindweed" },
			{ id = 8845, name = "Ghost Mushroom" },
			{ id = 8846, name = "Gromsblood" },
		},
	},
	{
		skill = 225,
		pigment = 39341, pigmentName = "Silvery Pigment",
		rare = 43107, rareName = "Sapphire Pigment",
		herbs = {
			{ id = 13464, name = "Golden Sansam" },
			{ id = 13463, name = "Dreamfoil" },
			{ id = 13465, name = "Mountain Silversage" },
			{ id = 13466, name = "Sorrowmoss" },
			{ id = 13467, name = "Icecap" },
		},
	},
	{
		skill = 275,
		pigment = 39342, pigmentName = "Nether Pigment",
		rare = 43108, rareName = "Ebon Pigment",
		herbs = {
			{ id = 22785, name = "Felweed" },
			{ id = 22786, name = "Dreaming Glory" },
			{ id = 22787, name = "Ragveil" },
			{ id = 22789, name = "Terocone" },
			{ id = 22790, name = "Ancient Lichen" },
			{ id = 22791, name = "Netherbloom" },
			{ id = 22792, name = "Nightmare Vine" },
			{ id = 22793, name = "Mana Thistle" },
		},
	},
	{
		skill = 325,
		pigment = 39343, pigmentName = "Azure Pigment",
		rare = 43109, rareName = "Icy Pigment",
		herbs = {
			{ id = 36901, name = "Goldclover" },
			{ id = 36904, name = "Tiger Lily" },
			{ id = 36907, name = "Talandra's Rose" },
			{ id = 36903, name = "Adder's Tongue" },
			{ id = 37921, name = "Deadnettle" },
			{ id = 36905, name = "Lichbloom" },
			{ id = 36906, name = "Icethorn" },
		},
	},
};

-- herb id -> its group, for quick lookups from bag scans.
private.herbGroup = {};
for _, group in ipairs(private.groups) do
	for _, herb in ipairs(group.herbs) do
		private.herbGroup[herb.id] = group;
	end
end
