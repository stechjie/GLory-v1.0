// Compile against the exact patched engine header:
// clang++ -std=c++17 -Wall -Wextra -Werror -I ENGINE_SOURCE this_file.cpp -o test
#include "platform/ios/godot_duo_geometry.h"
#include <cassert>
#include <cstdio>
#include <limits>
#include <random>
using namespace GloryIOSGeometry;

static bool near(double a, double b) { return std::abs(a-b) < 1e-8; }
static void valid(Rect result, Rect bounds, const std::vector<Rect>& obstacles, double scale) {
	if (result.empty()) return;
	assert(result.x >= bounds.x && result.y >= bounds.y);
	assert(result.right() <= bounds.right() && result.bottom() <= bounds.bottom());
	for (const auto &r : obstacles) assert(intersection(result,r).empty());
	assert(near(result.x*scale,std::round(result.x*scale)));
	assert(near(result.y*scale,std::round(result.y*scale)));
	assert(near(result.right()*scale,std::round(result.right()*scale)));
	assert(near(result.bottom()*scale,std::round(result.bottom()*scale)));
}
static double brute(const Rect& bounds, const std::vector<Rect>& obstacles) {
	double best=0;
	for(int x=0;x<bounds.width;++x) for(int r=x+1;r<=bounds.width;++r)
	for(int y=0;y<bounds.height;++y) for(int d=y+1;d<=bounds.height;++d) {
		Rect c{double(x),double(y),double(r-x),double(d-y)};
		bool ok=true;
		for(auto blocked:obstacles) if(!intersection(c,blocked).empty()) ok=false;
		if(ok) best=std::max(best,c.area());
	}
	return best;
}
int main() {
	int named=0;
	{ auto r=choose({0,0,951,669},{0,47,21,3},{},3); assert(near(r.x,3)&&near(r.y,0)&&near(r.width,901)&&near(r.height,648)); ++named; }
	{ auto r=choose({0,0,951,669},{},{{455.5,0,40,669}},3); valid(r,{0,0,951,669},{{455.5,0,40,669}},3); assert(r.right()<=455.5 || r.x>=495.5); ++named; }
	{ auto r=choose({0,0,669,951},{},{{0,455.5,669,40}},3); valid(r,{0,0,669,951},{{0,455.5,669,40}},3); assert(r.bottom()<=455.5 || r.y>=495.5); ++named; }
	{ auto r=choose({0,0,100,60},{},{{45,0,10,60}},1,{55,0,45,60}); assert(r.x==55); ++named; }
	{ auto r=choose({0,0,100,60},{},{{45,0,10,60}},1,{0,0,45,60}); assert(r.x==0); ++named; }
	{ auto r=choose({0,0,100,60},{},{{-10,-10,25,25}},3); valid(r,{0,0,100,60},{{-10,-10,25,25}},3); assert(r.area()==85*60); ++named; }
	{ auto r=choose({0,0,100,60},{},{{45,0,10,60},{0,0,15,20},{55,40,45,20}},3); valid(r,{0,0,100,60},{{45,0,10,60},{0,0,15,20},{55,40,45,20}},3); ++named; }
	{ auto r=choose({0,0,100,60},{},{{-1,-1,102,62}},3); assert(r.empty()); ++named; }
	{ auto r=choose({0,0,100,60},{},{{0,0,0,60}},3); assert(r.width==100); ++named; }
	{ auto r=choose({10,20,100,60},{1,2,3,4},{},2); assert(r.x==14&&r.y==21&&r.width==94&&r.height==56); ++named; }
	{ assert(choose({0,0,0,60},{},{},3).empty()); ++named; }
	{ assert(choose({0,0,100,60},{0,60,0,50},{},3).empty()); ++named; }
	{ assert(choose({0,0,100,60},{},{},0).empty()); ++named; }
	{ assert(choose({0,0,100,60},{},{{0,0,-1,20}},3).empty()); ++named; }
	{ assert(choose({0,0,100,60},{},{{std::numeric_limits<double>::quiet_NaN(),0,1,20}},3).empty()); ++named; }
	{ assert(choose({0,0,100,60},{std::numeric_limits<double>::infinity(),0,0,0},{},3).empty()); ++named; }
	{ auto r=choose({0.2,0.2,0.1,0.1},{},{},3); assert(r.empty()); ++named; }
	{ auto r=choose({0,0,100,60},{},{{100,0,10,60},{-10,0,10,60}},3); assert(r.width==100); ++named; }
	{ auto r=choose({0,0,100,60},{},{{0,0,50,60},{50,0,50,60}},3); assert(r.empty()); ++named; }
	{ auto r=choose({0,0,100,60},{},{{20,10,20,20},{60,25,30,10}},3); valid(r,{0,0,100,60},{{20,10,20,20},{60,25,30,10}},3); ++named; }
	std::mt19937 rng(0xD0272);
	for(int attempt=0;attempt<500;++attempt) {
		Rect b{0,0,12,10}; std::vector<Rect> obstacles;
		for(int n=0;n<int(rng()%5);++n) {
			obstacles.push_back({double(int(rng()%18)-3),double(int(rng()%16)-3),
				double(rng()%8),double(rng()%8)});
		}
		auto r=choose(b,{},obstacles,1);
		valid(r,b,obstacles,1);
		assert(near(r.area(),brute(b,obstacles)));
		std::reverse(obstacles.begin(),obstacles.end());
		assert(near(choose(b,{},obstacles,1).area(),r.area()));
	}
	for (int attempt=0; attempt<1000; ++attempt) {
		const double scale = (attempt % 2) ? 2.0 : 3.0;
		Rect b{0,0,100.25,60.75}; std::vector<Rect> obstacles;
		for (int n=0;n<int(rng()%6);++n) {
			obstacles.push_back({double(int(rng()%1200)-100)/10.0,double(int(rng()%800)-100)/10.0,
				double(rng()%400)/10.0,double(rng()%400)/10.0});
		}
		valid(choose(b,{},obstacles,scale),b,obstacles,scale);
	}
	std::printf("PASS: %d named boundary cases; 500 independent exhaustive-grid comparisons + reverse-order checks; 1000 fractional 2x/3x containment checks\n",named);
}
