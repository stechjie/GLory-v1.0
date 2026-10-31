shader_type spatial;
// Preserve alpha when composited through the transparent battle SubViewport.
render_mode unshaded,cull_disabled,depth_draw_never,blend_premul_alpha;
uniform float progress=0.0;
uniform vec2 origin_uv=vec2(0.5);
uniform vec2 world_size=vec2(4.0,8.0);
uniform float opacity=1.0;
void fragment(){
 vec2 delta=(UV-origin_uv)*world_size;float r=length(delta);
 float radius=progress*length(world_size);
 float wave=exp(-pow((r-radius)/0.16,2.0));
 float echo=exp(-pow((r-radius*0.78)/0.08,2.0))*0.22;
 float core=exp(-r*r*2.5)*pow(1.0-progress,4.0);
 float trail=exp(-pow((r-radius)/0.50,2.0))*0.12;
 float slash=exp(-pow(delta.y/0.08,2.0))*exp(-abs(delta.x)*0.5)*pow(1.0-progress,2.0);
 float edges=smoothstep(0.0,0.045,UV.x)*smoothstep(0.0,0.045,1.0-UV.x)*smoothstep(0.0,0.025,UV.y)*smoothstep(0.0,0.025,1.0-UV.y);
 vec3 hue=mix(vec3(1.0,0.42,0.05),vec3(1.0,0.94,0.65),clamp(wave+core,0.0,1.0));
 ALBEDO=hue;
 ALPHA=clamp((wave+echo+trail+core+slash)*pow(1.0-progress,0.6),0.0,0.8)*edges*opacity;
 if(ALPHA<0.008){discard;}
}
