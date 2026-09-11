# Postmaster

A co-pilot for EverQuest's **Courier of Favor** quest line — the one that ends with the
**Featherweight Satchel of the Courier**.

Postmaster runs the whole thing: the two prerequisite quests, all eighteen mail deliveries around the
old world, and the final hand-in. One click runs an entire leg unattended, travel included.

**Live servers only.**

---

## What you get out of it

- **Featherweight Satchel of the Courier** — a 20-slot bag at 100% weight reduction.
- **Hyredel Swiftstride** — your own parcel NPC in your neighborhood.

The satchel is Lore *and* Heirloom, which means you can hold one in inventory and one in the shared
bank at the same time. Postmaster tells you when a second is available, so a lot of people end up with
40 slots rather than 20.

## Installing

Extract into your MacroQuest `lua` folder so you end up with:

```
lua/postmaster/init.lua
lua/postmaster/assets/...
```

Then run it:

```
/lua run postmaster
```

## Using it

The window walks you through four phases in order, and opens each section as you reach it.

1. **Travel** — gets you to Sunrise Hills, including the Guild Lobby neighborhood gate.
2. **The Nonad Brothers** — the tonic run to Qeynos and the nested tax-collection quest.
3. **Postmaster's Challenge** — eighteen letters, grouped into four trips by destination city.
   One click runs a whole city's worth: every pickup, then the delivery run.
4. **Final Hail** — collect the reward.

Turn on **Full Auto** in the Postmaster's Challenge section and it chains every remaining trip on a
single click, then finishes at Aric and hails Lysric. A genuine failure stops it immediately; it does
not blunder onwards.

There's a **Deliveries** tab showing all eighteen with who has them and where they go, a **Settings**
tab with eight themes and optional sound and speech, and a **Help** tab.

## Worth knowing before you start

- **Letters are temporary.** They vanish on death and after roughly thirty minutes logged out. Don't
  carry them somewhere risky.
- **If a delivery fails, retry it with the script's own button** while it still holds the letter.
  Handing one in manually is what breaks tracking — the game gives a script no way to find out you did
  that. There's a "Mark done" button per delivery if it happens anyway.
- **The Tax Collection Box has to sit in a main inventory slot**, never inside a bag, or the quest
  won't register what you collect.
- **High Keep is genuinely dangerous at low level.** Its gnoll pack has killed characters that had a
  speed buff running. A pet to soak the aggro is what actually works.
- **Evil races**: if your faction is bad enough that a quest NPC won't talk to you, Postmaster will use
  a shroud plus Sneak and Hide to get you close enough safely. It also keeps a speed buff up for
  everyone, because the run is long.

## Requirements

- **MQ2Nav** with a mesh for the zones involved, and **MQ2EasyFind** for the long hops.
- **MQ2MoveUtils** for the stealth positioning (only used if your faction needs it).
- **MQTextToSpeech** is optional — spoken announcements simply stay off without it.

## Commands

| | |
|---|---|
| `/postmaster` | hide or show the window |
| `/postmaster travel` | travel to Sunrise Hills |
| `/postmaster nonad` | run the next Nonad Brothers step |
| `/postmaster pm` | run the next delivery batch |
| `/postmaster lysric` | hail Lysric for the reward |
| `/postmaster reset` | clear all tracked progress |

---

Made by **RedFrog**. Bug reports and quirks from your own server are welcome — this quest crosses a lot
of old zones, and field reports are how the awkward corners get found.
