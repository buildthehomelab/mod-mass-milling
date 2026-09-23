# MillingUI

A World of Warcraft 3.3.5a addon that gives Milling its own profession window. It uses the
stock tradeskill frame art, so it looks like part of the default Blizzard UI.

## What it does

- Lists every herb you can mill, grouped under the pigment it gives. Each header shows the
  Inscription rank that herb group needs.
- Colors each herb like a tradeskill recipe (orange, yellow, green or grey) based on your
  Inscription skill. Herbs you can't mill yet show in red.
- Shows `[n]` next to a herb for how many times you can mill it with the stacks in your bags.
- The detail pane shows the reagent count (have/5) and both pigments the herb can give.
- The **Milling** button mills the selected herb. It picks the smallest stack that has 5 or more,
  so broken stacks get used up first.
- Set how many times to mill with the `<` and `>` arrows, or type a number in the box, the same as
  crafting. **Create All** fills in every stack you have.
  - **With the `mod-mass-milling` server module:** one click mills the whole amount back-to-back,
    like Blizzard's Create All. Moving, or clicking again, stops it. Turn on Auto Loot so it
    doesn't wait on the loot window.
  - **Without it:** the game only lets an addon cast a spell on a real click or key press, so each
    click of **Milling** mills one stack of 5 and the box counts down. To go faster, put
    `/click MillingFrameMillButton` in a macro and bind that macro to a key.
- **Have Materials** hides herbs you can't mill right now.
- Keeps per-character counts of how many herbs you've milled, in total and for each herb.
- Shift-click a herb or pigment to link it in chat. Hover over one to see its tooltip.

## Reagent Bank

If ReagentBankUI is installed, its profession controls show on the Milling window the same way they
do on the other profession windows. The controls are Withdraw Needed, Add to AH List, the prepare
count, and Auto-deposit leftovers. The herb slot also shows "+N bank". Each mill needs 5 of the
selected herb, so Withdraw x4 pulls enough for 4 mills (20 herbs, minus what you already carry). The
prepare count and the amount box stay in sync.

## Opening it

- `/mill` or `/milling`
- Or bind a key under Key Bindings → Milling.

## Install

Copy the `MillingUI` folder into `World of Warcraft/Interface/AddOns/`.

## Limits

- The addon only changes what you see. The server still runs the normal Milling rules: you need
  Inscription, the Milling spell, and enough Inscription skill for each herb. Milling can't become
  a separate learnable skill without a server module or a client patch.
- The window closes when you enter combat and can't be opened during combat. It holds a secure
  button, and Blizzard doesn't allow addons to show or hide secure frames in combat.
- Pigment yields in the detail pane (2-4 and 0-1) are the usual ranges. Your server's
  `milling_loot_template` decides the actual drops.
