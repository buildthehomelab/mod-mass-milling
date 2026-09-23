---
-- MillingUI: gives Milling its own profession window, built the same way the
-- 3.3.5a TradeSkillFrame is (same art, same FrameXML templates, same anchors)
-- so it looks like part of the default Blizzard UI.
--
-- It lists every millable herb grouped by the pigment it gives, colours each
-- one by difficulty against your Inscription rank (the server still decides
-- whether you may mill), and mills the selected herb from a secure button.

local _, private = ...;

local groups = private.groups;
local herbGroup = private.herbGroup;

local pairs, ipairs, select, tonumber = pairs, ipairs, select, tonumber;
local floor, format = math.floor, string.format;
local tinsert, wipe = table.insert, table.wipe;

local SPELL_MILLING = 51005;
local SPELL_INSCRIPTION = 45357;
local MILL_STACK = 5;
local ROWS = 8;                -- TRADE_SKILLS_DISPLAYED
local ROW_HEIGHT = 16;         -- TRADE_SKILL_HEIGHT
local TEXT_WIDTH = 275;        -- TRADE_SKILL_TEXT_WIDTH

local MILLING_NAME, _, MILLING_ICON = GetSpellInfo(SPELL_MILLING);
MILLING_NAME = MILLING_NAME or "Milling";
MILLING_ICON = MILLING_ICON or [[Interface\Icons\Ability_Miling]];
local INSCRIPTION_NAME = GetSpellInfo(SPELL_INSCRIPTION) or "Inscription";
local QUESTION_ICON = [[Interface\Icons\INV_Misc_QuestionMark]];

-- Mirrors TradeSkillTypeColor from Blizzard_TradeSkillUI.lua.
local COLORS = {
	optimal  = { r = 1.00, g = 0.50, b = 0.25, font = GameFontNormalLeftOrange },
	medium   = { r = 1.00, g = 1.00, b = 0.00, font = GameFontNormalLeftYellow },
	easy     = { r = 0.25, g = 0.75, b = 0.25, font = GameFontNormalLeftLightGreen },
	trivial  = { r = 0.50, g = 0.50, b = 0.50, font = GameFontNormalLeftGrey },
	header   = { r = 1.00, g = 0.82, b = 0.00, font = GameFontNormalLeft },
	unusable = { r = 1.00, g = 0.10, b = 0.10, font = GameFontNormalLeftRed },
};

BINDING_HEADER_MILLINGUI = MILLING_NAME;
BINDING_NAME_MILLINGUI_TOGGLE = "Toggle " .. MILLING_NAME .. " window";

local db;                  -- MillingUIDB, per character
local frame;
local rows = {};
local list = {};           -- flattened header/herb entries currently visible
local bagTotal = {};       -- herb id -> total count in bags
local bagStacks = {};      -- herb id -> { {bag, slot, count}, ... }
local selectedHerb;
local pendingHerb;         -- herb the last Mill click targeted
local queued = 0;          -- mills left in the current run (0 = idle)

-- mod-mass-milling (server): repeats Milling on the server like Create All.
local serverMill = false;  -- true once the server answers our ping
local serverRun;           -- herb id while the server is milling for us
local pingedAt;

-- ---------------------------------------------------------------------------
-- Game state helpers
-- ---------------------------------------------------------------------------

-- Region:SetSize is not reliable on every 3.3.5 client build.
local function Size(region, w, h)
	region:SetWidth(w);
	region:SetHeight(h);
end

local function ItemName(id, fallback)
	return (GetItemInfo(id)) or fallback;
end

local function ItemIcon(id)
	return select(10, GetItemInfo(id)) or GetItemIcon and GetItemIcon(id) or QUESTION_ICON;
end

local function KnowsMilling()
	-- Looking a spell up by name only succeeds when it is in your spellbook.
	return GetSpellInfo(MILLING_NAME) ~= nil;
end

local function GetInscriptionRank()
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank, _, modifier, maxRank = GetSkillLineInfo(i);
		if not isHeader and name == INSCRIPTION_NAME then
			return rank + (modifier or 0), maxRank;
		end
	end
	return 0, 0;
end

local function Difficulty(rank, required)
	if rank < required then return "unusable"; end
	if rank < required + 25 then return "optimal"; end
	if rank < required + 50 then return "medium"; end
	if rank < required + 100 then return "easy"; end
	return "trivial";
end

local function ScanBags()
	wipe(bagTotal);
	for _, stacks in pairs(bagStacks) do wipe(stacks); end

	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot);
			local id = link and tonumber(link:match("item:(%d+)"));
			if id and herbGroup[id] then
				local _, count = GetContainerItemInfo(bag, slot);
				count = count or 0;
				bagTotal[id] = (bagTotal[id] or 0) + count;
				bagStacks[id] = bagStacks[id] or {};
				tinsert(bagStacks[id], { bag = bag, slot = slot, count = count });
			end
		end
	end
end

-- Milling takes 5 herbs from one stack, so only stacks of 5+ count.
local function MillsAvailable(id)
	local n = 0;
	for _, s in ipairs(bagStacks[id] or {}) do
		n = n + floor(s.count / MILL_STACK);
	end
	return n;
end

-- Smallest stack that can still be milled, so broken stacks are used up first.
local function FindMillStack(id)
	local best;
	for _, s in ipairs(bagStacks[id] or {}) do
		local _, count, locked = GetContainerItemInfo(s.bag, s.slot);
		if count and count >= MILL_STACK and not locked and (not best or count < best.count) then
			best = { bag = s.bag, slot = s.slot, count = count };
		end
	end
	return best;
end

-- ---------------------------------------------------------------------------
-- List
-- ---------------------------------------------------------------------------

local function BuildList()
	wipe(list);
	for index, group in ipairs(groups) do
		local herbs = {};
		for _, herb in ipairs(group.herbs) do
			if not db.haveMaterials or MillsAvailable(herb.id) > 0 then
				tinsert(herbs, herb);
			end
		end

		if #herbs > 0 then
			tinsert(list, { header = true, group = group, index = index });
			if not db.collapsed[index] then
				for _, herb in ipairs(herbs) do
					tinsert(list, { herb = herb, group = group });
				end
			end
		end
	end

	-- Keep the selection while it is still listed, otherwise pick the first
	-- herb you can mill right now (or just the first herb).
	local first, firstReady;
	for _, entry in ipairs(list) do
		if entry.herb then
			if entry.herb == selectedHerb then return; end
			first = first or entry.herb;
			if not firstReady and MillsAvailable(entry.herb.id) > 0 then firstReady = entry.herb; end
		end
	end
	selectedHerb = firstReady or first;
end

local UpdateDetail;

-- Row handling follows TradeSkillFrame_Update.
local function UpdateList()
	local rank = GetInscriptionRank();
	local offset = FauxScrollFrame_GetOffset(frame.scroll);

	frame.highlight:Hide();
	FauxScrollFrame_Update(frame.scroll, #list, ROWS, ROW_HEIGHT, nil, nil, nil, frame.highlight, 293, 316);

	for i = 1, ROWS do
		local row = rows[i];
		local entry = list[i + offset];
		row.entry = entry;

		if not entry then
			row:Hide();
		else
			row:SetWidth(frame.scroll:IsShown() and 293 or 323);
			row:Show();

			if entry.header then
				local color = COLORS.header;
				row:SetNormalFontObject(color.font);
				row:SetText(format("%s (%d)", ItemName(entry.group.pigment, entry.group.pigmentName), entry.group.skill));
				row.text:SetWidth(TEXT_WIDTH);
				row.count:SetText("");
				row:SetNormalTexture(db.collapsed[entry.index]
					and [[Interface\Buttons\UI-PlusButton-Up]]
					or [[Interface\Buttons\UI-MinusButton-Up]]);
				row.highlightTex:SetTexture([[Interface\Buttons\UI-PlusButton-Hilight]]);
				row:UnlockHighlight();
				row.isHighlighted = false;
			else
				local herb = entry.herb;
				local color = COLORS[Difficulty(rank, entry.group.skill)];
				local mills = MillsAvailable(herb.id);

				row:SetNormalFontObject(color.font);
				row.r, row.g, row.b = color.r, color.g, color.b;
				row.count:SetVertexColor(color.r, color.g, color.b);
				row:SetNormalTexture("");
				row.highlightTex:SetTexture("");

				row:SetText(" " .. ItemName(herb.id, herb.name));
				if mills > 0 then
					row.count:SetText("[" .. mills .. "]");
					row.text:SetWidth(0);
					if row.text:GetStringWidth() + 2 + row.count:GetStringWidth() > TEXT_WIDTH then
						row.text:SetWidth(TEXT_WIDTH - 2 - row.count:GetStringWidth());
					end
				else
					row.count:SetText("");
					row.text:SetWidth(TEXT_WIDTH);
				end

				if herb == selectedHerb then
					frame.highlight:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
					frame.highlightTex:SetVertexColor(color.r, color.g, color.b);
					frame.highlight:Show();
					row.count:SetVertexColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b);
					row:LockHighlight();
					row.isHighlighted = true;
				else
					row:UnlockHighlight();
					row.isHighlighted = false;
				end
			end
		end
	end
end

local function Refresh()
	if not frame or not frame:IsShown() then return; end

	ScanBags();
	BuildList();

	local rank, maxRank = GetInscriptionRank();
	frame.rank:SetMinMaxValues(0, maxRank > 0 and maxRank or 1);
	frame.rank:SetValue(rank);
	frame.rank.text:SetText(maxRank > 0 and format("%d/%d", rank, maxRank) or ("Requires " .. INSCRIPTION_NAME));
	frame.haveMaterials:SetChecked(db.haveMaterials);
	frame.milledTotal:SetText(format("Herbs milled: |cffffffff%d|r", db.totalMilled));

	UpdateList();
	UpdateDetail();
end

-- ---------------------------------------------------------------------------
-- Detail pane
-- ---------------------------------------------------------------------------

local function SetSlot(slot, itemId, fallbackName, countText)
	slot.itemId = itemId;
	slot.icon:SetTexture(ItemIcon(itemId));
	slot.name:SetText(ItemName(itemId, fallbackName));
	slot.count:SetText(countText or "");
	slot:Show();
end

UpdateDetail = function()
	local d = frame.detailChild;
	local herb = selectedHerb;

	if not herb then
		frame.detail:Hide();
		if not InCombatLockdown() then
			frame.mill:Disable();
			frame.millAll:Disable();
		end
		return;
	end

	frame.detail:Show();
	local group = herbGroup[herb.id];
	local rank = GetInscriptionRank();
	local total = bagTotal[herb.id] or 0;
	local mills = MillsAvailable(herb.id);

	d.iconButton.itemId = herb.id;
	d.iconButton:SetNormalTexture(ItemIcon(herb.id));
	d.iconCount:SetText(mills > 0 and mills or "");
	d.name:SetText(ItemName(herb.id, herb.name));

	local reqColor = rank >= group.skill and "|cffffffff" or "|cffff2020";
	d.requires:SetText(format("%s %s%s (%d)|r", REQUIRES_LABEL or "Requires:", reqColor, INSCRIPTION_NAME, group.skill));
	d.milled:SetText(format("Milled: |cffffffff%d|r", db.milled[herb.id] or 0));

	local haveColor = total >= MILL_STACK and "|cffffffff" or "|cffff2020";
	SetSlot(d.reagent, herb.id, herb.name, format("%s%d/%d|r", haveColor, total, MILL_STACK));
	if total < MILL_STACK then
		d.reagent.name:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b);
	else
		d.reagent.name:SetTextColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b);
	end

	SetSlot(d.pigment, group.pigment, group.pigmentName, "2-4");
	if group.rare then
		SetSlot(d.rare, group.rare, group.rareName, "0-1");
	else
		d.rare:Hide();
	end

	-- A run can't outlast the herbs in your bags.
	if queued > mills then
		queued = mills;
		frame.amount:SetNumber(queued > 0 and queued or 1);
	end

	if not KnowsMilling() then
		d.status:SetText("|cffff2020You have not learned " .. MILLING_NAME .. ".|r");
	elseif rank < group.skill then
		d.status:SetText("|cffff2020Your " .. INSCRIPTION_NAME .. " is too low.|r");
	elseif mills == 0 and total >= MILL_STACK then
		d.status:SetText("|cffff2020Combine your stacks into 5 or more.|r");
	elseif serverRun then
		d.status:SetText(format("%s: |cffffffff%d|r left. Move or click to stop.", MILLING_NAME, queued));
	elseif queued > 0 then
		d.status:SetText(format("Click %s to continue: |cffffffff%d|r left", MILLING_NAME, queued));
	else
		d.status:SetText("");
	end

	if not InCombatLockdown() then
		if KnowsMilling() and rank >= group.skill and mills > 0 then
			frame.mill:Enable();
			frame.millAll:Enable();
		else
			frame.mill:Disable();
			frame.millAll:Disable();
		end
	end

	-- Keep the ReagentBankUI controls (if installed) on the selected herb.
	local bank = _G.ReagentBankUI;
	if bank and bank.NotifyRecipeProviderChanged then
		bank:NotifyRecipeProviderChanged();
	end
end

-- ---------------------------------------------------------------------------
-- Frame construction (anchors copied from Blizzard_TradeSkillUI.xml)
-- ---------------------------------------------------------------------------

local function ShowItemTooltip(self)
	local id = self.itemId;
	if not id then return; end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	GameTooltip:SetHyperlink("item:" .. id);
	GameTooltip:Show();
end

local function ClickItemLink(self)
	if self.itemId and IsModifiedClick("CHATLINK") then
		local _, link = GetItemInfo(self.itemId);
		if link then ChatEdit_InsertLink(link); end
	end
end

-- Same look as TradeSkillItemTemplate (QuestItemTemplate -> LargeItemButtonTemplate).
local function CreateItemSlot(name, parent)
	local slot = CreateFrame("Button", name, parent, "LargeItemButtonTemplate");
	slot.icon = _G[name .. "IconTexture"];
	slot.name = _G[name .. "Name"];
	slot.count = _G[name .. "Count"];
	slot:SetScript("OnEnter", ShowItemTooltip);
	slot:SetScript("OnLeave", GameTooltip_Hide);
	slot:SetScript("OnClick", ClickItemLink);
	return slot;
end

local function OnRowClick(self)
	local entry = self.entry;
	if not entry then return; end

	if entry.header then
		db.collapsed[entry.index] = not db.collapsed[entry.index] or nil;
		Refresh();
		return;
	end

	if IsModifiedClick("CHATLINK") then
		ClickItemLink({ itemId = entry.herb.id });
		return;
	end

	if selectedHerb ~= entry.herb then
		selectedHerb = entry.herb;
		queued = 0;
		frame.amount:SetNumber(1);
	end
	UpdateList();
	UpdateDetail();
end

local function OnRowEnter(self)
	self.count:SetVertexColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b);
	if self.entry and self.entry.herb then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
		GameTooltip:SetHyperlink("item:" .. self.entry.herb.id);
		GameTooltip:Show();
	end
end

local function OnRowLeave(self)
	if not self.isHighlighted and self.r then
		self.count:SetVertexColor(self.r, self.g, self.b);
	end
	GameTooltip:Hide();
end

local function AddTexture(parent, layer, file, w, h, point, x, y)
	local t = parent:CreateTexture(nil, layer);
	t:SetTexture(file);
	Size(t, w, h);
	t:SetPoint(point, x or 0, y or 0);
	return t;
end

local function CreateMainFrame()
	frame = CreateFrame("Frame", "MillingFrame", UIParent);
	Size(frame, 384, 512);
	frame:SetPoint("TOPLEFT", 0, -104);
	frame:SetToplevel(true);
	frame:EnableMouse(true);
	frame:SetHitRectInsets(0, 34, 0, 75);
	frame:Hide();

	-- Portrait and background: the TradeSkillFrame reuses the class trainer art
	-- for three corners and has its own bottom-left piece.
	local portrait = frame:CreateTexture(nil, "BACKGROUND");
	Size(portrait, 60, 60);
	portrait:SetPoint("TOPLEFT", 7, -6);
	SetPortraitToTexture(portrait, MILLING_ICON);

	AddTexture(frame, "BORDER", [[Interface\ClassTrainerFrame\UI-ClassTrainer-TopLeft]], 256, 256, "TOPLEFT");
	AddTexture(frame, "BORDER", [[Interface\ClassTrainerFrame\UI-ClassTrainer-TopRight]], 128, 256, "TOPRIGHT");
	AddTexture(frame, "BORDER", [[Interface\TradeSkillFrame\UI-TradeSkill-BotLeft]], 256, 256, "BOTTOMLEFT");
	AddTexture(frame, "BORDER", [[Interface\ClassTrainerFrame\UI-ClassTrainer-BotRight]], 128, 256, "BOTTOMRIGHT");

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal");
	title:SetPoint("TOP", frame, "TOP", 0, -17);
	title:SetText(MILLING_NAME);

	-- Divider between the list and the detail pane
	local barLeft = AddTexture(frame, "ARTWORK", [[Interface\ClassTrainerFrame\UI-ClassTrainer-HorizontalBar]], 256, 16, "TOPLEFT", 15, -221);
	barLeft:SetTexCoord(0, 1.0, 0, 0.25);
	local barRight = frame:CreateTexture(nil, "ARTWORK");
	barRight:SetTexture([[Interface\ClassTrainerFrame\UI-ClassTrainer-HorizontalBar]]);
	Size(barRight, 75, 16);
	barRight:SetPoint("LEFT", barLeft, "RIGHT", 0, 0);
	barRight:SetTexCoord(0, 0.29296875, 0.25, 0.5);

	local close = CreateFrame("Button", "MillingFrameCloseButton", frame, "UIPanelCloseButton");
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -29, -8);

	-- Rank bar (TradeSkillRankFrame)
	local rank = CreateFrame("StatusBar", "MillingFrameRankFrame", frame);
	Size(rank, 265, 14);
	rank:SetPoint("TOPLEFT", 75, -36);
	rank:SetStatusBarTexture([[Interface\PaperDollInfoFrame\UI-Character-Skills-Bar]]);
	rank:SetStatusBarColor(0.0, 0.0, 1.0, 0.5);
	local rankBg = rank:CreateTexture(nil, "BACKGROUND");
	rankBg:SetAllPoints();
	rankBg:SetTexture(1.0, 1.0, 1.0, 0.2);
	rankBg:SetVertexColor(0.0, 0.0, 0.75, 0.5);
	AddTexture(rank, "OVERLAY", [[Interface\PaperDollInfoFrame\UI-Character-Skills-BarBorder]], 274, 27, "LEFT", -5, 0);
	rank.text = rank:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
	rank.text:SetPoint("TOP", title, "TOP", 0, -20);
	frame.rank = rank;

	-- "Have Materials" filter (TradeSkillFrameAvailableFilterCheckButton)
	local have = CreateFrame("CheckButton", "MillingFrameAvailableFilterCheckButton", frame, "UICheckButtonTemplate");
	Size(have, 24, 24);
	have:SetPoint("TOPLEFT", 70, -46);
	have:SetHitRectInsets(0, -75, 0, 0);
	_G["MillingFrameAvailableFilterCheckButtonText"]:SetText(CRAFT_IS_MAKEABLE or "Have Materials");
	have:SetScript("OnClick", function(self)
		db.haveMaterials = self:GetChecked() and true or false;
		Refresh();
	end);
	frame.haveMaterials = have;

	-- Sits where the search box is on the stock window.
	frame.milledTotal = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
	frame.milledTotal:SetPoint("TOPRIGHT", rank, "BOTTOMRIGHT", 0, -8);

	-- Herb list (TradeSkillSkill1..8 + TradeSkillListScrollFrame)
	local highlight = CreateFrame("Frame", nil, frame);
	Size(highlight, 293, ROW_HEIGHT);
	highlight:Hide();
	frame.highlightTex = highlight:CreateTexture(nil, "ARTWORK");
	frame.highlightTex:SetTexture([[Interface\Buttons\UI-Listbox-Highlight2]]);
	frame.highlightTex:SetAllPoints();
	frame.highlight = highlight;

	for i = 1, ROWS do
		local name = "MillingFrameSkill" .. i;
		local row = CreateFrame("Button", name, frame, "ClassTrainerSkillButtonTemplate");
		if i == 1 then
			row:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -96);
		else
			row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0);
		end
		row.text = _G[name .. "Text"];
		row.highlightTex = _G[name .. "Highlight"];
		row.count = row:CreateFontString(nil, "OVERLAY", "GameFontNormal");
		row.count:SetHeight(13);
		row.count:SetPoint("LEFT", row.text, "RIGHT", 2, 0);
		row:RegisterForClicks("LeftButtonUp");
		row:SetScript("OnClick", OnRowClick);
		row:SetScript("OnEnter", OnRowEnter);
		row:SetScript("OnLeave", OnRowLeave);
		rows[i] = row;
	end

	local scroll = CreateFrame("ScrollFrame", "MillingFrameListScrollFrame", frame, "ClassTrainerListScrollFrameTemplate");
	Size(scroll, 296, 130);
	scroll:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -67, -96);
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateList);
	end);
	frame.scroll = scroll;

	-- Detail pane (TradeSkillDetailScrollFrame)
	local detail = CreateFrame("ScrollFrame", "MillingFrameDetailScrollFrame", frame, "ClassTrainerDetailScrollFrameTemplate");
	Size(detail, 297, 176);
	detail:SetPoint("TOPLEFT", 20, -234);
	frame.detail = detail;

	local d = CreateFrame("Frame", "MillingFrameDetailScrollChildFrame", detail);
	Size(d, 297, 190);
	detail:SetScrollChild(d);
	frame.detailChild = d;

	local headerLeft = AddTexture(d, "BACKGROUND", [[Interface\ClassTrainerFrame\UI-ClassTrainer-DetailHeaderLeft]], 256, 64, "TOPLEFT", 0, 3);
	local headerRight = d:CreateTexture(nil, "BACKGROUND");
	headerRight:SetTexture([[Interface\ClassTrainerFrame\UI-ClassTrainer-DetailHeaderRight]]);
	Size(headerRight, 64, 64);
	headerRight:SetPoint("TOPLEFT", headerLeft, "TOPRIGHT", 0, 0);

	local iconButton = CreateFrame("Button", "MillingFrameSkillIcon", d);
	Size(iconButton, 37, 37);
	iconButton:SetPoint("TOPLEFT", 8, -3);
	iconButton:SetScript("OnEnter", ShowItemTooltip);
	iconButton:SetScript("OnLeave", GameTooltip_Hide);
	iconButton:SetScript("OnClick", ClickItemLink);
	d.iconButton = iconButton;
	d.iconCount = iconButton:CreateFontString(nil, "ARTWORK", "NumberFontNormal");
	d.iconCount:SetPoint("BOTTOMRIGHT", -5, 2);

	d.name = d:CreateFontString(nil, "ARTWORK", "GameFontNormal");
	d.name:SetWidth(244);
	d.name:SetJustifyH("LEFT");
	d.name:SetPoint("TOPLEFT", 50, -5);

	d.requires = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
	d.requires:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, 0);

	d.milled = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
	d.milled:SetPoint("TOPLEFT", d.requires, "BOTTOMLEFT", 0, 0);

	d.status = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
	d.status:SetPoint("TOPLEFT", d.milled, "BOTTOMLEFT", 0, 0);

	local reagentLabel = d:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
	reagentLabel:SetPoint("TOPLEFT", 5, -50);
	reagentLabel:SetText("Reagents:");
	d.reagent = CreateItemSlot("MillingFrameReagent1", d);
	d.reagent:SetPoint("TOPLEFT", reagentLabel, "BOTTOMLEFT", -2, -3);

	local yieldLabel = d:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
	yieldLabel:SetPoint("TOPLEFT", d.reagent, "BOTTOMLEFT", 2, -10);
	yieldLabel:SetText("Yields:");
	d.pigment = CreateItemSlot("MillingFrameYield1", d);
	d.pigment:SetPoint("TOPLEFT", yieldLabel, "BOTTOMLEFT", -2, -3);
	d.rare = CreateItemSlot("MillingFrameYield2", d);
	d.rare:SetPoint("LEFT", d.pigment, "RIGHT", 0, 0);

	-- Bottom bar, same order as the stock window:
	-- [Mill All] [<] [amount] [>] [Milling] [Exit]
	--
	-- Casting Milling on a bag item needs a hardware click, so both mill
	-- buttons are secure macro buttons ("/cast Milling" then "/use bag slot").
	-- Addons can't chain casts the way Create does for crafts (that repeat
	-- happens on the server), so the amount is a run you click through: each
	-- click mills one stack of 5 and the box counts down.
	local function MillButton(name, label)
		local b = CreateFrame("Button", name, frame, "UIPanelButtonTemplate,SecureActionButtonTemplate");
		Size(b, 80, 22);
		b:SetText(label);
		b:RegisterForClicks("LeftButtonUp");
		b:SetAttribute("type", "macro");
		return b;
	end

	local function PrepareMill(self, all)
		if InCombatLockdown() then return; end
		local mills = selectedHerb and MillsAvailable(selectedHerb.id) or 0;

		-- With mod-mass-milling the server repeats the cast, so one click mills
		-- the whole amount; a click during that run stops it.
		if serverRun then
			self:SetAttribute("macrotext", nil);
			SendChatMessage(".massmill stop", "SAY");
			return;
		end

		local wanted = all and mills or math.min(math.max(frame.amount:GetNumber(), 1), mills);
		if serverMill and selectedHerb and wanted > 1 then
			self:SetAttribute("macrotext", nil);
			queued = wanted;
			frame.amount:SetNumber(wanted);
			SendChatMessage(format(".massmill start %d %d", selectedHerb.id, wanted), "SAY");
			return;
		end

		if all then
			queued = mills;
		elseif queued == 0 then
			queued = math.min(math.max(frame.amount:GetNumber(), 1), mills);
		end
		frame.amount:SetNumber(queued > 0 and queued or 1);

		local stack = selectedHerb and FindMillStack(selectedHerb.id);
		if stack and queued > 0 then
			pendingHerb = selectedHerb.id;
			self:SetAttribute("macrotext", format("/cast %s\n/use %d %d", MILLING_NAME, stack.bag, stack.slot));
		else
			pendingHerb = nil;
			queued = 0;
			self:SetAttribute("macrotext", nil);
			UIErrorsFrame:AddMessage("You need a stack of 5 to mill.", 1.0, 0.1, 0.1, 1.0);
		end
	end

	local mill = MillButton("MillingFrameMillButton", MILLING_NAME);
	mill:SetPoint("CENTER", frame, "TOPLEFT", 224, -422);
	mill:SetScript("PreClick", function(self) PrepareMill(self, false); end);
	frame.mill = mill;

	local millAll = MillButton("MillingFrameMillAllButton", CREATE_ALL or "Create All");
	millAll:SetPoint("RIGHT", mill, "LEFT", -86, 0);
	millAll:SetScript("PreClick", function(self) PrepareMill(self, true); end);
	frame.millAll = millAll;

	-- Changing the amount by hand starts a fresh run on the next click.
	-- Not capped by the herbs in your bags: ReagentBankUI can withdraw the rest.
	-- A run is capped when it starts instead.
	local function SetAmount(n, fromBank)
		queued = 0;
		n = math.min(math.max(math.floor(tonumber(n) or 1), 1), 999);
		frame.amount:SetNumber(n);
		frame.amount:ClearFocus();

		local bank = _G.ReagentBankUI;
		if not fromBank and bank and bank.SetTradeSkillPrepareCount and bank.GetActiveRecipeProvider and bank:GetActiveRecipeProvider() then
			bank:SetTradeSkillPrepareCount(n, false);
		end
		UpdateDetail();
	end
	frame.SetAmount = SetAmount;

	local function ArrowButton(name, which)
		local b = CreateFrame("Button", name, frame);
		Size(b, 23, 22);
		b:SetNormalTexture([[Interface\Buttons\UI-SpellbookIcon-]] .. which .. [[-Up]]);
		b:SetPushedTexture([[Interface\Buttons\UI-SpellbookIcon-]] .. which .. [[-Down]]);
		b:SetDisabledTexture([[Interface\Buttons\UI-SpellbookIcon-]] .. which .. [[-Disabled]]);
		b:SetHighlightTexture([[Interface\Buttons\UI-Common-MouseHilight]], "ADD");
		return b;
	end

	local dec = ArrowButton("MillingFrameDecrementButton", "PrevPage");
	dec:SetPoint("LEFT", millAll, "RIGHT", 3, 0);
	dec:SetScript("OnClick", function() SetAmount(frame.amount:GetNumber() - 1); end);

	local inc = ArrowButton("MillingFrameIncrementButton", "NextPage");
	inc:SetPoint("RIGHT", mill, "LEFT", -3, 0);
	inc:SetScript("OnClick", function() SetAmount(frame.amount:GetNumber() + 1); end);

	-- Amount box (TradeSkillInputBox)
	local amount = CreateFrame("EditBox", "MillingFrameInputBox", frame);
	Size(amount, 30, 20);
	amount:SetPoint("LEFT", dec, "RIGHT", 4, 0);
	amount:SetAutoFocus(false);
	amount:SetNumeric(true);
	amount:SetMaxLetters(3);
	amount:SetFontObject(ChatFontNormal);
	amount:SetJustifyH("CENTER");

	local left = AddTexture(amount, "BACKGROUND", [[Interface\Common\Common-Input-Border]], 8, 20, "TOPLEFT", -5, 0);
	left:SetTexCoord(0, 0.0625, 0, 0.625);
	local right = AddTexture(amount, "BACKGROUND", [[Interface\Common\Common-Input-Border]], 8, 20, "RIGHT", 0, 0);
	right:SetTexCoord(0.9375, 1.0, 0, 0.625);
	local middle = amount:CreateTexture(nil, "BACKGROUND");
	middle:SetTexture([[Interface\Common\Common-Input-Border]]);
	middle:SetHeight(20);
	middle:SetPoint("LEFT", left, "RIGHT");
	middle:SetPoint("RIGHT", right, "LEFT");
	middle:SetTexCoord(0.0625, 0.9375, 0, 0.625);

	amount:SetScript("OnEnterPressed", function(self) SetAmount(self:GetNumber()); end);
	amount:SetScript("OnEscapePressed", EditBox_ClearFocus);
	amount:SetScript("OnEditFocusGained", function(self)
		queued = 0;
		EditBox_HighlightText(self);
	end);
	amount:SetScript("OnEditFocusLost", function(self)
		EditBox_ClearHighlight(self);
		if self:GetNumber() < 1 then self:SetNumber(1); end
	end);
	amount:SetScript("OnTextChanged", function(self)
		if self:GetText() == "0" then self:SetText("1"); end
	end);
	amount:SetNumber(1);
	frame.amount = amount;

	local exit = CreateFrame("Button", "MillingFrameCancelButton", frame, "UIPanelButtonTemplate");
	Size(exit, 80, 22);
	exit:SetPoint("CENTER", frame, "TOPLEFT", 305, -422);
	exit:SetText(EXIT or CLOSE);
	exit:SetScript("OnClick", function() HideUIPanel(frame); end);

	frame:SetScript("OnShow", function()
		-- Ask once whether the server has mod-mass-milling.
		if not pingedAt then
			pingedAt = GetTime();
			SendChatMessage(".massmill ping", "SAY");
		end
		PlaySound("igCharacterInfoOpen");
		Refresh();
	end);
	frame:SetScript("OnHide", function()
		-- A server run keeps going with the window closed, like Create All.
		if not serverRun then
			queued = 0;
			frame.amount:SetNumber(1);
		end
		pendingHerb = nil;
		PlaySound("igCharacterInfoClose");
	end);

	UIPanelWindows["MillingFrame"] = { area = "left", pushable = 3, whileDead = 1 };
end

-- ---------------------------------------------------------------------------
-- ReagentBankUI integration (optional)
-- ---------------------------------------------------------------------------

-- Lets ReagentBankUI put its profession controls (Withdraw Needed, Add to AH
-- List, prepare count, auto-deposit leftovers, "+N bank") on this window, the
-- same as it does on the stock trade skill window. One mill = 5 of the herb.
local function RegisterWithReagentBank()
	local bank = _G.ReagentBankUI;
	if not bank or not bank.RegisterRecipeProvider then return; end

	bank:RegisterRecipeProvider({
		name = MILLING_NAME,
		frame = frame,
		reagentButtons = { frame.detailChild.reagent },

		GetRecipe = function()
			if not selectedHerb then
				return nil, "Select a herb first.";
			end
			local name = ItemName(selectedHerb.id, selectedHerb.name);
			return MILLING_NAME .. ": " .. name, {
				{ itemEntry = selectedHerb.id, name = name, requiredPerCraft = MILL_STACK },
			};
		end,

		GetAllReagentEntries = function()
			local entries = {};
			for id in pairs(herbGroup) do tinsert(entries, id); end
			return entries;
		end,

		GetRepeatCount = function()
			return frame.amount:GetNumber();
		end,

		SetRepeatCount = function(n)
			if not frame.amount:HasFocus() then
				frame.SetAmount(n, true);
			end
		end,
	});
end

-- ---------------------------------------------------------------------------
-- Toggle / slash / events
-- ---------------------------------------------------------------------------

function MillingUI_Toggle()
	if InCombatLockdown() then
		UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT or "You can't do that while in combat", 1.0, 0.1, 0.1, 1.0);
		return;
	end
	if frame:IsShown() then
		HideUIPanel(frame);
	else
		ShowUIPanel(frame);
	end
end

SLASH_MILLINGUI1 = "/mill";
SLASH_MILLINGUI2 = "/milling";
SlashCmdList["MILLINGUI"] = MillingUI_Toggle;

local events = CreateFrame("Frame");
events:RegisterEvent("ADDON_LOADED");
events:RegisterEvent("BAG_UPDATE");
events:RegisterEvent("SKILL_LINES_CHANGED");
events:RegisterEvent("LEARNED_SPELL_IN_TAB");
events:RegisterEvent("PLAYER_REGEN_DISABLED");
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED");
events:RegisterEvent("UNIT_SPELLCAST_FAILED");
events:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED");
events:RegisterEvent("CHAT_MSG_SYSTEM");

-- Protocol lines from mod-mass-milling are for us, not for chat. On a server
-- without the module, the ping's "no such command" reply is hidden too.
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, message)
	if type(message) ~= "string" then return false; end
	if message:find("^MASSMILL:") then return true; end
	if pingedAt and GetTime() - pingedAt < 5 and message:find("no such command") then return true; end
	return false;
end);

local STOP_REASONS = {
	interrupted = MILLING_NAME .. " interrupted.",
	no_herbs = "No more stacks of 5 to mill.",
	loot_timeout = "Stopped: take the loot (or turn on Auto Loot) to keep milling.",
};

local function HandleServerMessage(message)
	local kind, a, b, reason = message:match("^MASSMILL:(%u+):?(%d*):?(%d*):?(.*)$");
	if not kind then return; end

	if kind == "PONG" then
		serverMill = true;
	elseif kind == "START" then
		serverRun = tonumber(a);
		queued = tonumber(b) or queued;
		frame.amount:SetNumber(math.max(queued, 1));
	elseif kind == "DONE" or kind == "STOP" then
		serverRun = nil;
		queued = 0;
		frame.amount:SetNumber(1);
		if kind == "STOP" and STOP_REASONS[reason] then
			UIErrorsFrame:AddMessage(STOP_REASONS[reason], 1.0, 0.1, 0.1, 1.0);
		end
	end
	Refresh();
end
events:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 ~= "MillingUI" then return; end
		MillingUIDB = MillingUIDB or {};
		db = MillingUIDB;
		db.collapsed = db.collapsed or {};
		db.milled = db.milled or {};
		db.totalMilled = db.totalMilled or 0;
		CreateMainFrame();
		RegisterWithReagentBank();
		self:UnregisterEvent("ADDON_LOADED");

	elseif event == "PLAYER_REGEN_DISABLED" then
		-- The window holds a secure button, so it can't be hidden once combat
		-- lockdown starts. This event fires just before it does.
		if frame and frame:IsShown() then HideUIPanel(frame); end

	elseif event == "CHAT_MSG_SYSTEM" then
		if frame and type(arg1) == "string" then HandleServerMessage(arg1); end

	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if arg1 ~= "player" or arg2 ~= MILLING_NAME or not db then return; end
		db.totalMilled = db.totalMilled + MILL_STACK;
		if serverRun then
			db.milled[serverRun] = (db.milled[serverRun] or 0) + MILL_STACK;
			queued = math.max(queued - 1, 0);
			frame.amount:SetNumber(math.max(queued, 1));
		elseif pendingHerb then
			db.milled[pendingHerb] = (db.milled[pendingHerb] or 0) + MILL_STACK;
			pendingHerb = nil;
			if queued > 0 then
				queued = queued - 1;
				frame.amount:SetNumber(queued > 0 and queued or 1);
			end
		end
		Refresh();

	elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
		-- The run stays where it was; the next click retries the same mill.
		if arg1 == "player" and arg2 == MILLING_NAME then pendingHerb = nil; end

	else
		Refresh();
	end
end);
