shader_type spatial;
render_mode depth_draw_opaque,cull_back,ambient_light_disabled;
varying vec4 paint;
void vertex(){paint=COLOR;}
void fragment(){
 ALBEDO=paint.rgb;
 ROUGHNESS=0.55;
 SPECULAR=0.0;
 EMISSION=ALBEDO*vec3(0.82,0.81,0.79)+paint.rgb*paint.a*0.20;
}
void light(){
 float peak=max(LIGHT_COLOR.r,max(LIGHT_COLOR.g,LIGHT_COLOR.b));
 vec3 tint=mix(vec3(1.0),LIGHT_COLOR/max(peak,0.001),0.35)*clamp(peak*1.5,0.0,1.0);
 float ndl=max(dot(NORMAL,LIGHT),0.0)*ATTENUATION;
 float band=mix(ndl,smoothstep(0.25,0.42,ndl),0.55);
 DIFFUSE_LIGHT+=ALBEDO*tint*band*0.30;
 float spec=pow(max(dot(NORMAL,normalize(LIGHT+VIEW)),0.0),24.0);
 SPECULAR_LIGHT+=vec3(0.10)*smoothstep(0.55,0.70,spec)*ATTENUATION;
}
