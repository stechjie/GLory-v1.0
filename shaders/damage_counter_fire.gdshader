shader_type canvas_item;
render_mode blend_add;
// Horizontal anamorphic flare: concentrated white core, blue skirt, small ghosts.
// The same sweep drives the letter-face reflection in damage_counter_ink.
uniform float tier=0.0;
uniform vec4 flame_color:source_color=vec4(0.50,0.65,1.0,1.0);
uniform float motion=1.0;
uniform float simple=0.0;
uniform float promotion=0.0;
uniform float sweep=1.0;
uniform vec2 sweep_range=vec2(-0.0776,0.8694);
uniform float focus_y=0.60;
float spot(vec2 p,vec2 width){return exp(-dot(p/width,p/width));}
void fragment(){
 float energy=clamp(tier/6.0,0.0,1.0);
 vec2 focus=vec2(mix(sweep_range.x,sweep_range.y,sweep),focus_y);
 vec2 p=UV-focus;
 vec2 optical=vec2(p.x*2.55357,p.y);
 float core=spot(optical,vec2(0.028,0.050));
 float crown=spot(optical,vec2(0.010,0.14))*0.72;
 float spine=spot(p,vec2(0.57,0.0040));
 float skirt=spot(p,vec2(0.39,0.020))*0.36;
 float halo=spot(optical,vec2(0.22,0.11))*0.27;
 float diagonal=spot(vec2(optical.x+optical.y*0.32,optical.y),vec2(0.009,0.067))*0.24;
 float ghost=spot(p-vec2(-0.24,0.0),vec2(0.011,0.022))*0.16+spot(p-vec2(0.18,0.0),vec2(0.005,0.018))*0.13;
 vec2 crest=UV-vec2(0.35,0.17);
 float crest_release=promotion*(1.0-smoothstep(0.40,0.95,sweep));
 float crest_core=spot(crest,vec2(0.018,0.036))*crest_release;
 float crest_line=spot(crest,vec2(0.28,0.004))*crest_release*0.60;
 float live=(core+crown+spine*0.75+skirt+halo+diagonal+ghost)*promotion+crest_core+crest_line;
 float rest=spot(UV-vec2(0.5,focus_y),vec2(0.44,0.006))*0.045*energy;
 float edge=(1.0-smoothstep(0.40,0.50,abs(UV.x-0.5)))*(1.0-smoothstep(0.38,0.50,abs(UV.y-0.5)));
 vec3 blue=mix(vec3(0.08,0.24,1.0),flame_color.rgb,0.15);
 vec3 hue=mix(blue,vec3(0.83,0.98,1.0),clamp(core*1.7+crown+crest_core*2.0,0.0,1.0));
 COLOR=vec4(hue,clamp(live+rest,0.0,1.0)*edge*mix(1.0,0.15,simple));
}
