/*
 * Mass milling: repeat Milling for a player until a count is reached.
 *
 * The 3.3.5 client only lets an addon cast a spell from a hardware event, so an
 * addon can't chain mills. Blizzard's Create All gets around that for crafts by
 * repeating on the server; this does the same for Milling. `.massmill start
 * <herb> <count>` queues a run, and every player update the run either casts the
 * next Milling (a normal, non-triggered cast with its cast bar and checks) or
 * waits for the last mill's loot to be taken, since the herbs are only destroyed
 * when that loot window is released.
 *
 * Replies meant for MillingUI are system messages starting with "MASSMILL:":
 *   MASSMILL:PONG
 *   MASSMILL:START:<herb>:<count>
 *   MASSMILL:DONE:<herb>:<milled>
 *   MASSMILL:STOP:<herb>:<milled>:<reason>
 * where reason is one of cancelled, interrupted, no_herbs, loot_timeout or
 * cast_failed_<SpellCastResult>.
 */

#include "Bag.h"
#include "Chat.h"
#include "CommandScript.h"
#include "Config.h"
#include "Item.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "Spell.h"
#include "SpellInfo.h"
#include "SpellMgr.h"

#include <algorithm>
#include <mutex>
#include <string>
#include <unordered_map>

using namespace Acore::ChatCommands;

namespace
{
constexpr uint32 SPELL_MILLING = 51005;
constexpr uint32 MILL_STACK = 5;

bool g_enabled = true;
uint32 g_maxCount = 200;
uint32 g_delayMs = 250;
uint32 g_lootTimeoutMs = 30000;

enum class Phase
{
    WaitingToCast,  // timer counts down to the next cast
    Casting,        // our Milling cast is in progress
    WaitingForLoot  // cast finished, the loot window is still open
};

struct Run
{
    uint32 herbEntry = 0;
    uint32 remaining = 0;
    uint32 milled = 0;
    Phase phase = Phase::WaitingToCast;
    uint32 timerMs = 0;
};

// Runs are touched from map threads (player updates, spell hooks) and from
// command handling. Recursive because casting can call back into our hooks.
std::recursive_mutex g_lock;
std::unordered_map<ObjectGuid::LowType, Run> g_runs;

void SendProtocol(Player* player, std::string const& message)
{
    ChatHandler(player->GetSession()).SendSysMessage("MASSMILL:" + message);
}

void EndRun(Player* player, bool finished, std::string const& reason = "")
{
    std::lock_guard<std::recursive_mutex> guard(g_lock);

    auto itr = g_runs.find(player->GetGUID().GetCounter());
    if (itr == g_runs.end())
        return;

    Run const run = itr->second;
    g_runs.erase(itr);

    if (finished)
        SendProtocol(player, "DONE:" + std::to_string(run.herbEntry) + ":" + std::to_string(run.milled));
    else
        SendProtocol(player, "STOP:" + std::to_string(run.herbEntry) + ":" + std::to_string(run.milled) + ":" + reason);
}

// Smallest stack of 5 or more, so broken stacks get used up first (same rule
// as MillingUI). Skips items being traded or still holding an open mill's loot.
Item* FindMillStack(Player* player, uint32 herbEntry)
{
    Item* best = nullptr;

    auto consider = [&](Item* item)
    {
        if (!item || item->GetEntry() != herbEntry || item->IsInTrade() || item->m_lootGenerated)
            return;

        if (item->GetCount() < MILL_STACK)
            return;

        if (!best || item->GetCount() < best->GetCount())
            best = item;
    };

    for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
        consider(player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot));

    for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
        if (Bag* bag = player->GetBagByPos(bagSlot))
            for (uint32 slot = 0; slot < bag->GetBagSize(); ++slot)
                consider(bag->GetItemByPos(static_cast<uint8>(slot)));

    return best;
}

bool IsCastingMilling(Player* player)
{
    Spell const* spell = player->GetCurrentSpell(CURRENT_GENERIC_SPELL);
    return spell && spell->GetSpellInfo()->Id == SPELL_MILLING;
}

void CastNextMill(Player* player, Run& run)
{
    Item* herb = FindMillStack(player, run.herbEntry);
    if (!herb)
    {
        EndRun(player, false, "no_herbs");
        return;
    }

    SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(SPELL_MILLING);
    if (!spellInfo)
    {
        EndRun(player, false, "cast_failed_no_spell");
        return;
    }

    SpellCastTargets targets;
    targets.SetItemTarget(herb);

    // Set before casting: a zero cast time would reach OnSpellCast right away.
    run.phase = Phase::Casting;

    SpellCastResult result = player->CastSpell(targets, spellInfo, nullptr, TRIGGERED_NONE);
    if (result != SPELL_CAST_OK)
        EndRun(player, false, "cast_failed_" + std::to_string(uint32(result)));
}
}

class MassMillingWorldScript : public WorldScript
{
public:
    MassMillingWorldScript() : WorldScript("MassMillingWorldScript", {
        WORLDHOOK_ON_AFTER_CONFIG_LOAD
    })
    {
    }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        g_enabled = sConfigMgr->GetOption<bool>("MassMilling.Enable", true);
        g_maxCount = std::max<uint32>(1, sConfigMgr->GetOption<uint32>("MassMilling.MaxCount", 200));
        g_delayMs = sConfigMgr->GetOption<uint32>("MassMilling.DelayMs", 250);
        g_lootTimeoutMs = std::max<uint32>(1, sConfigMgr->GetOption<uint32>("MassMilling.LootTimeoutSec", 30)) * IN_MILLISECONDS;
    }
};

class MassMillingPlayerScript : public PlayerScript
{
public:
    MassMillingPlayerScript() : PlayerScript("MassMillingPlayerScript", {
        PLAYERHOOK_ON_UPDATE,
        PLAYERHOOK_ON_LOGOUT
    })
    {
    }

    void OnPlayerUpdate(Player* player, uint32 diff) override
    {
        std::lock_guard<std::recursive_mutex> guard(g_lock);

        auto itr = g_runs.find(player->GetGUID().GetCounter());
        if (itr == g_runs.end())
            return;

        Run& run = itr->second;

        switch (run.phase)
        {
            case Phase::Casting:
                // OnSpellCast moves a finished cast on; if our cast is gone
                // without that, it was interrupted (moved, pushed back, failed).
                if (!IsCastingMilling(player))
                    EndRun(player, false, "interrupted");
                break;

            case Phase::WaitingForLoot:
                if (player->GetLootGUID().IsEmpty())
                {
                    if (run.remaining == 0)
                    {
                        EndRun(player, true);
                        return;
                    }

                    run.phase = Phase::WaitingToCast;
                    run.timerMs = g_delayMs;
                }
                else if ((run.timerMs += diff) >= g_lootTimeoutMs)
                {
                    EndRun(player, false, "loot_timeout");
                }
                break;

            case Phase::WaitingToCast:
                if (run.timerMs > diff)
                {
                    run.timerMs -= diff;
                    break;
                }

                run.timerMs = 0;

                // Let whatever the player is casting finish first.
                if (player->IsNonMeleeSpellCast(false) || !player->GetLootGUID().IsEmpty())
                    break;

                CastNextMill(player, run);
                break;
        }
    }

    void OnPlayerLogout(Player* player) override
    {
        std::lock_guard<std::recursive_mutex> guard(g_lock);
        g_runs.erase(player->GetGUID().GetCounter());
    }
};

class MassMillingSpellScript : public AllSpellScript
{
public:
    MassMillingSpellScript() : AllSpellScript("MassMillingSpellScript", {
        ALLSPELLHOOK_ON_CAST
    })
    {
    }

    // Called once a cast has gone off, before its loot window is released.
    void OnSpellCast(Spell* /*spell*/, Unit* caster, SpellInfo const* spellInfo, bool /*skipCheck*/) override
    {
        if (spellInfo->Id != SPELL_MILLING || !caster || !caster->IsPlayer())
            return;

        std::lock_guard<std::recursive_mutex> guard(g_lock);

        auto itr = g_runs.find(caster->GetGUID().GetCounter());
        if (itr == g_runs.end() || itr->second.phase != Phase::Casting)
            return;

        Run& run = itr->second;
        run.milled++;
        run.remaining--;
        run.phase = Phase::WaitingForLoot;
        run.timerMs = 0;
    }
};

class MassMillingCommandScript : public CommandScript
{
public:
    MassMillingCommandScript() : CommandScript("MassMillingCommandScript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable massMillTable =
        {
            { "ping",  HandlePing,  SEC_PLAYER, Console::No },
            { "start", HandleStart, SEC_PLAYER, Console::No },
            { "stop",  HandleStop,  SEC_PLAYER, Console::No },
        };

        static ChatCommandTable commandTable =
        {
            { "massmill", massMillTable },
        };

        return commandTable;
    }

    static bool HandlePing(ChatHandler* handler)
    {
        Player* player = handler->GetPlayer();
        if (!player || !g_enabled)
            return false;

        SendProtocol(player, "PONG");
        return true;
    }

    static bool HandleStart(ChatHandler* handler, uint32 herbEntry, uint32 count)
    {
        Player* player = handler->GetPlayer();
        if (!player)
            return false;

        if (!g_enabled)
        {
            handler->SendSysMessage("Mass milling is disabled on this server.");
            handler->SetSentErrorMessage(true);
            return false;
        }

        if (!player->HasSpell(SPELL_MILLING))
        {
            handler->SendSysMessage("You don't know Milling.");
            handler->SetSentErrorMessage(true);
            return false;
        }

        ItemTemplate const* proto = sObjectMgr->GetItemTemplate(herbEntry);
        if (!proto || !proto->HasFlag(ITEM_FLAG_IS_MILLABLE))
        {
            handler->SendSysMessage("That item can't be milled.");
            handler->SetSentErrorMessage(true);
            return false;
        }

        count = std::min(std::max<uint32>(count, 1), g_maxCount);

        std::lock_guard<std::recursive_mutex> guard(g_lock);

        // A new run replaces whatever was running.
        g_runs.erase(player->GetGUID().GetCounter());

        Run run;
        run.herbEntry = herbEntry;
        run.remaining = count;
        run.phase = Phase::WaitingToCast;
        run.timerMs = 0;
        g_runs[player->GetGUID().GetCounter()] = run;

        SendProtocol(player, "START:" + std::to_string(herbEntry) + ":" + std::to_string(count));
        return true;
    }

    static bool HandleStop(ChatHandler* handler)
    {
        Player* player = handler->GetPlayer();
        if (!player)
            return false;

        std::lock_guard<std::recursive_mutex> guard(g_lock);

        auto itr = g_runs.find(player->GetGUID().GetCounter());
        if (itr == g_runs.end())
            return true;

        if (itr->second.phase == Phase::Casting && IsCastingMilling(player))
            player->InterruptSpell(CURRENT_GENERIC_SPELL, false);

        EndRun(player, false, "cancelled");
        return true;
    }
};

void AddMassMillingScripts()
{
    new MassMillingWorldScript();
    new MassMillingPlayerScript();
    new MassMillingSpellScript();
    new MassMillingCommandScript();
}
