shader_type canvas_item;
uniform float tier=0.0;
uniform vec4 flame_color:source_color=vec4(1.0,0.6,0.1,1.0);
uniform float motion=1.0;
uniform float simple=0.0;
uniform float promotion=0.0;
uniform float sweep=1.0;
float streak(vec2 p,vec2 size){return exp(-dot(p/size,p/size));}
void fragment(){
 vec2 p=UV-vec2(0.5,0.63);float t=TIME*motion;
 float energy=clamp(tier/6.0,0.0,1.0);
 float spine=streak(p,vec2(0.49,0.009+energy*0.004));
 float halo=streak(p,vec2(0.40,0.070+energy*0.025))*0.24;
 float left=streak(p-vec2(-0.30,0.0),vec2(0.075,0.13))*0.32;
 float right=streak(p-vec2(0.34,0.0),vec2(0.045,0.10))*0.26;
 float wings=streak(vec2(p.x,p.y+p.x*0.10),vec2(0.50,0.018))*0.30;
 float scan=streak(p-vec2(mix(-0.55,0.55,sweep),0.0),vec2(0.016,0.18))*promotion;
 float flare=streak(p,vec2(0.17,0.14))*promotion*0.60;
 float edge=(1.0-smoothstep(0.40,0.5,abs(p.x)))*(1.0-smoothstep(0.35,0.52,abs(p.y)));
 float a=((spine*0.58+halo+left+right+wings)*(0.90+0.10*sin(t*2.2))*(0.50+energy*0.50)+scan+flare)*edge*step(0.5,tier);
 vec3 c=mix(flame_color.rgb,vec3(1.0,0.97,0.85),clamp(spine*0.68+scan,0.0,0.85));
 COLOR=vec4(c,clamp(a,0.0,0.92)*mix(1.0,0.25,simple));
}
