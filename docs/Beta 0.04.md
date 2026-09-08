# Beta 0.04

## Project

- Godot 4.6 clean rewrite stored in `G:\My Drive\Glory v0.1\Beta 0.04`.
- Older folders and documents are reference only. Do not overwrite them.
- Mem0 is used only as external development memory, not as game runtime.

## Core Loop

- 5x5 preparation board.
- Combat converts initial board positions into a 2D moving battlefield with range, movement speed, targeting, status effects, and no mana bar.
- PVP rounds use real online opponent board. If no online opponent exists, those rounds become PVE.
- Round 21 is the final round. If neither formation HP is zero at round 21, both sides summon one formation ally based on formation HP and enter the final battle.

## Rounds

- PVP rounds: 6, 12, 18, 21. In single player these become PVE.
- Final round: 21. This is not an extra round after 21; round 21 itself is the final battle.
- Boss rounds: 5, 10, 15, 20. Boss rounds also spawn 5 random PVE monsters using PVE growth.
- PVE fills all remaining rounds.
- Treasure draws occur after rounds 4, 8, 12, 16, 20.

## Economy

- Start formation HP: 50.
- Start gold: 10.
- Base interest: floor(gold before interest * 10%), no cap.
- PVE kill gold: every two completed PVE battles increases kill reward by 1.
- PVP normal kill reward: 1 star = tier, 2 stars = tier + 2, 3 stars = tier + 3.
- PVP mercenary kill reward: round(cost * 0.5).
- Boss win rewards: round 5 = 10, round 10 = 15, round 15 = 25, round 20 = 40.
- Boss loss reward: base - floor(base * boss remaining HP percent).
- Merchant post-battle gold: 1 star +1, 2 stars +2, 3 stars +3.
- Golden altar: -1 formation HP, +5 gold, max 3 times each round, unavailable when formation HP <= 10.

## Units

- Normal unit cap: 7. Treasure can raise it to 8.
- Max star: 3.
- Star scaling: HP, ATK, DEF scale by 1.5 per star step.
- Mercenaries occupy board cells, do not count toward normal unit cap, do not receive treasure effects, do not count for synergies, cannot star up, and have no quantity cap.
- Formation allies do not count toward cap, do not count for synergies, and do not receive treasure effects.

## Battle Resolution

- No short timeout.
- At 10 seconds, battle decay starts. Every 6 seconds all living normal units, mercenaries, formation allies, summons, and clones decay:
  - current HP *= 0.8
  - max HP *= 0.8
  - ATK *= 0.8
  - DEF *= 0.8
- Decay does not affect attack speed, move speed, crit, crit damage, range, or cooldowns.
- Hard timeout at 3 minutes:
  1. Higher living total power wins.
  2. Power = current HP + ATK * 2 + DEF * 5.
  3. If tied, higher formation HP wins.
  4. If still tied, player/host wins.

## Synergies

- God: death cleanses a random ally; God 3 lifesteal 6%; God 7 splash 15% to two nearby enemies.
- Dark: every 3 enemy deaths gives dark units +6% damage; Dark 2 damage +8%; Dark 5 debuff strength +25%; Dark 7 debuff duration +50%.
- Undead: every 20 total deaths summons a 40% stat clone; Undead 4 poison damage +20%; Undead 7 thresholds become *0.75.
- Human: every third attack is a guaranteed crit using unit crit damage; Human 2 gives 8% max HP shield; Human 7 last normal unit heals 50% and gains 200% berserk.

## Treasure

- Max owned treasures: 5.
- Draw shows 3 choices. If no choice is made within 8 seconds, a random unowned treasure is granted from all unowned treasures.
- Treasure refresh costs: 5, 10, 20, 40, reset each draw. Money set makes shop and treasure refresh free.
- Treasures affect only self normal units unless the effect is explicitly economy or formation HP.

## Final Formation Allies

- 1-10 HP: Flame Claw.
- 11-20 HP: Soul Chain.
- 21-30 HP: Abyss Beast.
- 31-40 HP: Hell Inferno.
- 41-50 HP: Eternal Night.
- Formation ally spawns at the front of its side.
- Formation building body stats are deleted from Beta 0.04.

## Current Implementation Notes

- Battle simulator currently supports moving 2D combat, range checks, attack speed, shields, defense reduction, dodge, poison, bleed, slow, attack down, silence, stun, interrupt, damage reduction, decay, and hard timeout scoring.
- Implemented synergy combat hooks include Human 2 shield, Human 7 last-stand heal/berserk, Human guaranteed third-hit crit, God 3 lifesteal, God 7 splash, Dark 2/5/7 damage and debuff modifiers, Dark kill stacks, Undead 4 poison bonus, Undead 7 mother threshold scaling, and Mother unique death execute.
- Race relation system is currently disabled through `RaceRelationService.ENABLED = false`: no progress, stat modifiers, board bars, glow, particles, links, or detail text are active. Implementation is retained for later re-enabling.
- Prep race synergies are summarized as one race-logo row per present race with a dynamic current/maximum threshold count. Long-pressing the logo shows every threshold and effect; reached entries are bright and unreached entries are dimmed without explicit active/inactive labels.
- Implemented unit skill hooks include major God, Dark, Undead, Human ordinary combat skills, including healing, cleanse, bless, judgement, global blast, silence, fear, stun, black hole, poison, parasite clone, defense down, self explosion, reflect armor, mother execute, human interrupt, combo, group heal, and sword stun.
- Implemented Boss hooks include meteor, overload counter, mirror clone, holy purify, rage stack, blood rage, soul devour, twin revive queue, and apocalypse charge simplified as shield plus global true damage on cast.
- Refined Boss combat hooks: boss skill damage now scales with boss growth, Mirror Lord fills all missing HP threshold clones, Apocalypse charges for 2 seconds and is interrupted if its charge shield breaks, Blood Demon lifesteals after blood rage, and Rage Beast stops stacking at max stacks.
- Implemented treasure combat hooks include defense set HP/DEF/dodge, attack set lowest-HP targeting, control set extra random debuff after a new debuff, blood pact self-bleed plus ATK, and elemental attack treasures.
- Implemented final formation ally battle integration: round 21 itself is marked final when both formation HP values remain above zero, and both sides summon formation allies based on formation HP. Formation allies ignore treasure effects and kill rewards.
- Implemented battle kill reward recording for PVP/final: normal unit kills use star/tier reward, mercenary kills use round(cost * 0.5), formation ally kills give 0.
- Implemented formation ally combat hooks: Flame Claw burn, Soul Chain root/attack down, Abyss Beast lifesteal bite, Hell Inferno AoE burn, and Eternal Night opening AoE/debuff/clones.
- Implemented battle result UI display for kill gold and recent kill records.
- Improved battle settlement/log UI: battle screen now shows live unit counts, formation HP/gold context, expected reward breakdown, formation HP change preview, and recent combat events including kill reward logs.
- Implemented first treasure cooldown/linkage pass: shockwave, corrosive needle, interrupt chain, frenzy assault, element set 20% AoE max-HP proc, and paralysis shackles ice-vulnerability linkage.
- Implemented second treasure/linkage pass: lifesteal emblem, blood covenant fire bonus, rich path attack gold and +4% interest, burst core kill explosion, toxic burst poison linkage, and phoenix temporary revive for 3 seconds.
- Implemented expanded treasure linkage pass: individual defense/opening control treasures, binding weight cooldown slow, frenzy stacks on attacking and being attacked, oppression counter, fraud fate dodge gold, iron maiden counter bleed/armor break, money magic/lucky envelope post-battle gold, and speed-bonus status routing.
- Implemented remaining treasure hooks: formation heal post-battle +1 HP, soul counter death retaliation, wail resonance death debuff, and golden altar prep action button with -1 HP/+5 gold up to 3 uses per round.
- Implemented PVP opponent snapshot layer: local board serialization, opponent snapshot validation, PVP enemy construction from snapshot, and PVP-to-PVE fallback when no online opponent snapshot exists.
- Implemented LAN transport scaffold with Godot ENet: menu host/join buttons, default localhost join, board snapshot RPC exchange, prep-screen network status, and manual sync button.
- Improved real PVP lobby flow: main menu now has editable host/IP and port, ENet sessions track local/opponent Ready, prep screen has Ready toggle, and PVP requires connection, opponent snapshot, and both Ready before using the online opponent board.
- Added host-authoritative PVP settlement sync: host broadcasts the final PVP result, clients convert it to their local perspective before rewards are applied, preventing random combat divergence between players.
- Implemented mercenary combat skill pass: bubble dream, shell guard baseline reduction hook, balance judge, gold charge, holy song, twin strike, king aura, arrow rain, blood rampage, steel order, time slow, and death hunt.
- Still pending deeper pass: production relay/NAT strategy, reconnect UX, and full two-instance manual network QA on target machines.

