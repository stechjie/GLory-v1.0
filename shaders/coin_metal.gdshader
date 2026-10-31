shader_type spatial;
render_mode unshaded,cull_disabled;
void fragment(){
 vec2 p=(UV-vec2(0.5))*2.0;
 float r=length(p);
 float rim=1.0-smoothstep(0.035,0.07,abs(r-0.84));
 float inner=1.0-smoothstep(0.018,0.04,abs(r-0.62));
 float mark=(1.0-smoothstep(0.10,0.15,abs(p.x)))*(1.0-smoothstep(0.30,0.36,abs(p.y)));
 float facing=abs(dot(normalize(NORMAL),normalize(VIEW)));
 float glint=pow(facing,14.0);
 vec3 gold=mix(vec3(0.90,0.54,0.09),vec3(1.0,0.88,0.40),rim);
 gold=mix(gold,vec3(0.58,0.30,0.025),max(inner*0.55,mark*0.48));
 gold=mix(gold,vec3(1.0,0.97,0.76),glint*0.72);
 if(r>0.97){gold=vec3(0.82,0.47,0.06);}
 ALBEDO=gold;
 EMISSION=gold*0.20;
}
