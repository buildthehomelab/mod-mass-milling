# Mass Milling

A Milling profession window for WoW 3.3.5a, plus an AzerothCore module that lets it mill a herb over and over from one click, the way Blizzard's
**Create All** repeats a craft.

This repo has two parts:

- **`MillingUI/`**: a client addon that gives Milling its own window in the default tradeskill
  style. It has herbs grouped by pigment, difficulty colors, an amount box and Create All, and
  ReagentBankUI integration. See [MillingUI/README.md](MillingUI/README.md).
- **The server module** (everything else) repeats the Milling cast on the server, so Create All
  doesn't need a click per mill.

The addon works on its own. The module is what makes Create All continuous.

The 3.3.5a client only lets an addon cast a spell from a real click or key press, so an addon
can't chain mills by itself. Crafts get around this because the server repeats them, and this
module does the same for Milling. It's built to be driven by the **MillingUI** addon: with this
module installed, MillingUI's **Create All** (or **Milling** with an amount above 1) mills the
whole amount from one click.

## How it works

- Each mill is a normal Milling cast started by the server. It shows a cast bar, runs the usual
  skill and stack checks, and moving interrupts it.
- The herbs from a mill are only used up when its loot window closes, so each run waits for the
  loot before starting the next cast. With **Auto Loot** on this is instant. Without it, you have
  to take the loot each time, and a run stops if the loot sits there for
  `MassMilling.LootTimeoutSec`.
- It uses the smallest stack of 5 or more first, the same as MillingUI.
- A run stops when:
  - it reaches the amount
  - you run out of stacks of 5
  - you move or the cast is interrupted
  - you click again (`.massmill stop`)
  - you log out

## Commands

| Command | What it does |
| --- | --- |
| `.massmill start <herb entry> <count>` | Mill that herb `count` times. |
| `.massmill stop` | Stop the current run. |
| `.massmill ping` | Replies `MASSMILL:PONG`; MillingUI uses it to find the module. |

Replies for the addon are system messages starting with `MASSMILL:`. MillingUI hides them from
chat.

## Requirements

- AzerothCore wotlk (master). No other module is needed and no SQL is run.
- WoW 3.3.5a (12340) client. The module works without the addon, but only **MillingUI** gives it a
  window and a Create All button.
- Optional: ReagentBankUI, which MillingUI integrates with if it is installed.

## Install

```bash
cd /path/to/azerothcore-wotlk/modules
cp -r /path/to/mod-mass-milling .
cd /path/to/build
cmake ../ -DCMAKE_INSTALL_PREFIX=/path/to/server
make -j$(nproc) install
```

Copy `conf/mod_mass_milling.conf.dist` to `etc/modules/mod_mass_milling.conf`. No SQL is needed.

For the addon, copy the `MillingUI` folder into `World of Warcraft/Interface/AddOns/`.

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `MassMilling.Enable` | `1` | Master switch. |
| `MassMilling.MaxCount` | `200` | Most mills one run can ask for. |
| `MassMilling.DelayMs` | `250` | Pause between taking a mill's loot and the next cast. |
| `MassMilling.LootTimeoutSec` | `30` | How long a run waits for loot to be taken before it stops. |

## Troubleshooting

- **A run stops after one mill.** Without Auto Loot the server waits for you to take the loot of each
  mill before the next cast. Turn on Auto Loot, or take the loot before `MassMilling.LootTimeoutSec`
  runs out.
- **Create All only does one at a time.** The module is not running. MillingUI looks for it with
  `.massmill ping`, so check that the worldserver was rebuilt with the module and that
  `MassMilling.Enable` is `1`.
- **A run stops early.** Moving, an interrupted cast, having no stack of 5 left, or clicking again
  (`.massmill stop`) all end a run. A single run is limited by `MassMilling.MaxCount`.

## Credits

Author: [buildthehomelab](https://github.com/buildthehomelab)

## License

GNU AGPL v3. See [LICENSE](LICENSE).
