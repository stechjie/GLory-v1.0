shader_type canvas_item;
uniform float tier = 0.0;
uniform vec4 flame_color : source_color = vec4(1.0,0.6,0.1,1.0);
uniform float motion = 1.0;
uniform float simple = 0.0;
void fragment(){
 vec2 p=UV; float t=TIME*motion;
 float tongues=sin(p.x*43.0+t*7.0)*0.07+sin(p.x*77.0-t*5.0)*0.035;
 float height=0.20+tier*0.065;
 float rise=1.0-p.y;
 float edge=smoothstep(0.0,0.09,p.x)*smoothstep(0.0,0.09,1.0-p.x);
 float base=1.0-smoothstep(height+0.04,height+0.16,rise+tongues);
 float low=smoothstep(0.0,0.15,rise);
 float gaps=0.55+0.45*sin(p.x*57.0+t*3.0+rise*9.0);
 float a=base*low*edge*mix(gaps,0.78,simple)*0.65;
 vec3 c=mix(flame_color.rgb,vec3(1.0,0.94,0.76),pow(1.0-rise,4.0)*0.55);
 if(tier>5.5){c=mix(vec3(0.50,0.20,0.95),c,base);}
 COLOR=vec4(c,a*step(0.5,tier));
}
