shader_type canvas_item;
uniform vec2 extent=vec2(226.0,62.0);
uniform vec2 ink_y=vec2(12.0,47.0);
uniform vec2 scan_range=vec2(-22.0,249.0);
uniform vec4 accent:source_color=vec4(0.50,0.65,1.0,1.0);
uniform float promotion=0.0;
uniform float sweep=1.0;
varying vec2 glyph_position;
varying float vertex_alpha;
void vertex(){glyph_position=VERTEX;vertex_alpha=COLOR.a;}
void fragment(){
 vec4 glyph=texture(TEXTURE,UV);
 float y=clamp((glyph_position.y-ink_y.x)/max(ink_y.y-ink_y.x,1.0),0.0,1.0);
 vec3 face=mix(vec3(0.84,0.94,1.0),vec3(0.54,0.67,0.98),smoothstep(0.0,0.50,y));
 face=mix(face,vec3(0.50,0.28,0.83),smoothstep(0.50,1.0,y));
 face+=vec3(0.09,0.08,0.08)*exp(-pow((y-0.18)/0.055,2.0));
 face=mix(face,face*0.55+accent.rgb*0.45,0.20);
 float light=exp(-pow((glyph_position.x-mix(scan_range.x,scan_range.y,sweep))/(extent.x*0.085),2.0))*promotion;
 face=mix(face,vec3(1.0),light*0.95);
 COLOR=vec4(face,glyph.a*vertex_alpha);
}
