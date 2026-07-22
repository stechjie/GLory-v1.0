# Glory VFX v2 package library

This directory is an isolated preview/reference library. It does not replace V1 modules or connect to formal combat skills.

## Included source packages

- Binbun `GodotLootVFX.zip`: loot floating and ground layers.
- Binbun `StatusFXFree.zip`: status overlay/shatter, aura, bubble, ice, heal and sleep shader layers.
- Binbun `ElementalMagicFXFree.zip`: cast, projectile and area stages with noise, tail, streak and spiral controls.
- Binbun `BattleFXFree.zip`: charge, slash, swing, claw and shield stages.
- Binbun `GodotBeamVFXFree.zip`: endpoint-following beam with core, outer, flare, particles and end impact.
- Binbun `PortalVFX.zip`: warped/dithered portal with layered depth and inward motion.
- `Starter_Vfx.zip`: hit, explosion, fire, muzzle, smoke and loot reference scenes.
- `Demo.zip`: magic-orb flash, Fresnel, noise, dithering and light-pulse reference scenes.

The six Binbun packages are already flattened under `binbun_reference/assets/`. Starter and Demo are preserved under `reference_packages/` with their internal `res://` paths rewritten for this isolated library.

## Preview policy

The V2 panel exposes each source as an isolated preview. Recipes may combine approved source stages, but no item in this directory is automatically injected into V1 battle logic.
