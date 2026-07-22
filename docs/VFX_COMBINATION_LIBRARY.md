# Glory VFX Combination Library

This library defines the reusable authored combinations for the isolated VFX v2 preview. It does not replace formal combat skills.

| Combination | Stages | Primary use | PNG requirement |
|---|---|---|---|
| ProjectileDirect | Cast muzzle -> thin projectile -> directional trail -> impact | unit ranged attacks, Silence Bolt | optional authored projectile/impact |
| ProjectileElemental | irregular core -> shell/ribbon -> trail -> dissolve -> impact | fireball, ice bolt, poison dart, soul bolt | elemental core or hit decal when available |
| SlashImpact | directional slash arc -> impact flash -> debris -> ground residue | melee attacks and boss slashes | slash atlas recommended |
| MeteorStrike | ground warning -> falling projectile -> contact flash -> shockwave -> smoke/debris | element_meteor | meteor and smoke flipbook recommended |
| BeamLink | caster core -> tracked beam/ribbons -> target endpoint -> persistent fade | Lightning Arc, Doom link | beam texture optional |
| PortalArrival | ground portal -> rising orb/summon -> arrival burst -> smoke residue | summon and teleport skills | portal texture optional |
| ShieldStatus | shield shell -> hit ripple -> break shards -> fade | barrier, holy shield | emblem/impact texture optional |
| StatusReadable | head-anchored emblem -> restrained status particles -> remaining-time fade | silence, poison, stun | required readable status PNG |
| AreaBurst | center flash -> main ring -> delayed ring -> directional debris -> dust -> residue | shockwave, roar, boss impact | ring/flipbook optional |

## V2 templates currently exposed

* Silence Bolt: `silence_bolt_v2.tres`
* Poison Dart: `poison_dart_v2.tres`
* Meteor Strike: `meteor_strike_v2.tres`
* Slash Impact: `slash_impact_v2.tres`
* Portal Arrival: `portal_arrival_v2.tres`

The templates use Binbun reference scenes where a matching authored effect exists, and existing Starter/painted layers for muzzle, impact, and smoke. Their stage timings are intentionally staggered so every layer is readable in the 1280x720 battle camera.

## Planned mappings

Boss: Apocalypse Charge -> AreaBurst + BeamLink; Element Meteor -> MeteorStrike; Mirror Clone -> PortalArrival + Afterimage; Holy Purify -> ShieldStatus + AreaBurst; Thunder Core -> BeamLink; Twin Gatekeeper -> BarrierShield + BeamLink; Blood Rage -> AreaBurst + StatusReadable; Soul Eater -> BeamLink + StatusReadable; Berserk Calamity -> SlashImpact + RoarCone.

Units: four race colors share ProjectileDirect/Elemental and SlashImpact, while status skills use StatusReadable. Mother Spirit uses PortalArrival with a large book summon layer. Mercenaries reuse ProjectileDirect, BeamLink and PortalArrival according to their skill data.

## Rules

1. No square placeholder geometry in production combinations.
2. Projectiles are thin and direction-aligned; explosions are reserved for impact stages.
3. Status icons stay head-anchored until the gameplay status remaining time reaches zero.
4. Every recipe must remain mobile-budgeted and independently previewable before battle integration.
