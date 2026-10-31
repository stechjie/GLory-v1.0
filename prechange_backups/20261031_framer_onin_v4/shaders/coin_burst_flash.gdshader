shader_type spatial;
// Preserve alpha when composited through the transparent battle SubViewport.
render_mode unshaded,cull_disabled,depth_draw_never,blend_premul_alpha;
uniform float progress=0.0;
uniform float opacity=1.0;
void fragment(){
 vec2 p=(UV-vec2(0.5))*2.0;float r=length(p);
 float core=exp(-r*r/(0.025+progress*0.09))*pow(1.0-progress,3.0);
 float ring=exp(-pow((r-progress*0.95)/0.035,2.0))*(1.0-progress);
 float rays=pow(max(0.0,cos(atan(p.y,p.x)*7.0+r*3.0)),18.0)*exp(-r*2.8)*(1.0-progress);
 float beam=exp(-pow(p.y/0.018,2.0))*exp(-p.x*p.x*3.0)*(1.0-progress);
 vec3 hue=mix(vec3(1.0,0.46,0.05),vec3(1.0,0.95,0.64),clamp(core*2.0+beam,0.0,1.0));
 ALBEDO=hue;
 ALPHA=clamp(core+ring*0.45+rays*0.48+beam*0.65,0.0,1.0)*opacity;
 if(ALPHA<0.008){discard;}
}
