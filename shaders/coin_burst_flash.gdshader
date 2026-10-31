shader_type spatial;
// FrameRonin expansion_signature.gdshader, adapted for this transparent SubViewport.
// Geometry/colors come from selected presets 81/85; instance fade is one-shot.
render_mode unshaded,blend_premul_alpha,depth_draw_never,cull_disabled,fog_disabled;
uniform float opacity=1.0;
uniform float seconds=0.0;
void fragment(){
 ALBEDO=COLOR.rgb;
 // UV.x marks pressure rings: release them before the coins spread.
 float ring_release=1.0-smoothstep(0.025,0.13,seconds);
 ALPHA=COLOR.a*opacity*mix(1.0,ring_release,UV.x);
 if(ALPHA<0.01){discard;}
}
