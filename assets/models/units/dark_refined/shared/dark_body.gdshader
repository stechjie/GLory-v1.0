// Race-refinement body material (dark, undead), single sided. Same two-band cel model
// as shaders/character_toon.gdshader (which stays untouched and shared), plus what the
// AI atlases need at ~70 px — see race_body.gdshaderinc:
//  - value_lift opens very dark paint toward sqrt() without changing its hue;
//  - one race palette: saturated paint is pulled toward race_hue (dark violet, undead
//    toxic green) so a race reads as one family (2026-10-04 review: colours unified);
//    skin, white hair and steel keep their hue;
//  - an albedo-derived accent mask picks each unit's brightest painted details and lets
//    them glow in the race colour;
//  - pale, unsaturated paint (trim, steel, bone, face) gets a banded highlight;
//  - a race-coloured fresnel rim written as emission, so it reads on the unlit side and
//    in every lighting rig, separating dark silhouettes from dark ground.
// Compatibility/Mobile safe: opaque, no screen reads, no alpha.
// dark_body_two_sided.gdshader is the cull_disabled variant of the same code.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, ambient_light_disabled;

#include "res://assets/models/units/dark_refined/shared/race_body.gdshaderinc"
