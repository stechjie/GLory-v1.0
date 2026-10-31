shader_type spatial;
render_mode cull_disabled;
void fragment(){
 vec2 p=(UV-vec2(0.5))*2.0;
 float r=length(p);
 float rim=1.0-smoothstep(0.035,0.07,abs(r-0.84));
 float inner=1.0-smoothstep(0.018,0.04,abs(r-0.62));
 float mark=(1.0-smoothstep(0.10,0.15,abs(p.x)))*(1.0-smoothstep(0.30,0.36,abs(p.y)));
 vec3 gold=mix(vec3(0.72,0.32,0.035),vec3(1.0,0.78,0.24),0.65+rim*0.35);
 gold=mix(gold,vec3(0.48,0.20,0.025),max(inner*0.7,mark*0.65));
 if(r>0.97){gold=vec3(0.52,0.25,0.035);}
 ALBEDO=gold;
 METALLIC=0.45;
 ROUGHNESS=0.28;
 EMISSION=gold*0.65;
}
