shader_type spatial;
// FrameRonin #115 _draw_refraction_ring: three segmented rims, optical ticks,
// two delayed echoes. Ported to world distance fields, clipped by lane geometry.
// Transparent SubViewport composition; no screen-texture sampling or other-lane warp.
render_mode unshaded,cull_disabled,depth_draw_never,blend_premul_alpha,fog_disabled;
uniform float progress=0.0;
uniform vec2 origin_uv=vec2(0.5);
uniform vec2 world_size=vec2(4.0,8.0);
uniform float opacity=1.0;
uniform bool detail=true;
float bell(float value,float center,float width){float d=(value-center)/width;return exp(-d*d);}
float arcs(float angle,float ring_index,float time){
 float spin=time*(0.12+ring_index*0.04);
 float quarter=mod(angle-spin+6.2831853,6.2831853)/1.5707963;
 float arc_index=floor(quarter);
 float local_angle=fract(quarter)*1.5707963;
 float span=0.62+mod(arc_index+ring_index,3.0)*0.11;
 return smoothstep(0.0,0.04,local_angle)*(1.0-smoothstep(span-0.04,span,local_angle));
}
void fragment(){
 vec2 delta=(UV-origin_uv)*world_size;
 float r=length(delta);
 float angle=atan(delta.y,delta.x);
 float time=progress*1.60;
 float expansion=smoothstep(0.04,1.02,time);
 float impact=bell(time,0.58,0.20);
 float envelope=smoothstep(0.0,0.05,time)*(1.0-smoothstep(0.66,1.58,time));
 vec2 far_corner=max(origin_uv,vec2(1.0)-origin_uv)*world_size;
 float reach=length(far_corner)+0.12;
 float main_radius=mix(0.055,reach,expansion);
 float rim=0.0;float halo=0.0;
 for(int i=0;i<3;i++){
  if(!detail && i>0){continue;}
  float index=float(i);
  float radius=main_radius-index*(0.08+expansion*0.032);
  float arc=arcs(angle,index,time);
  rim+=bell(r,radius,0.022+index*0.008)*arc*(0.82-index*0.14);
  halo+=bell(r,radius,0.085)*arc*0.16;
 }
 // The nearest of the source's twelve optical ticks, evaluated without 12 loops.
 float tick_angle=floor((angle-0.10)/0.5235988+0.5)*0.5235988+0.10;
 vec2 direction=vec2(cos(tick_angle),sin(tick_angle));
 vec2 tangent=vec2(-direction.y,direction.x);
 float tick_r=dot(delta,direction)-main_radius;
 float tick_side=dot(delta,tangent)-tick_r*0.18;
 float ticks=bell(tick_side,0.0,0.018)*smoothstep(-0.01,0.02,tick_r)*(1.0-smoothstep(0.14,0.24,tick_r))*(0.35+impact*0.65);
 float echoes=0.0;
 for(int i=0;i<2;i++){
  float delayed=smoothstep(0.10+float(i)*0.12,1.10+float(i)*0.12,time);
  float radius=reach*delayed*0.80;
  echoes+=bell(r,radius,0.018)*(0.16+impact*0.12)*arcs(angle,float(i),time);
 }
 float core=bell(r,0.0,0.18)*pow(1.0-progress,5.0);
 float edges=smoothstep(0.0,0.035,UV.x)*smoothstep(0.0,0.035,1.0-UV.x)*smoothstep(0.0,0.02,UV.y)*smoothstep(0.0,0.02,1.0-UV.y);
 float density=rim+halo+ticks+echoes+core;
 ALBEDO=mix(vec3(1.0,0.56,0.12),vec3(1.0,0.97,0.76),clamp(rim+core,0.0,1.0));
 ALPHA=clamp(density,0.0,0.90)*envelope*edges*opacity;
 if(ALPHA<0.008){discard;}
}
