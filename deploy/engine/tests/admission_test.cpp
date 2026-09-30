#include "thirdparty/enet/enet/dtls_admission.h"
#include <array>
#include <cassert>
#include <iostream>
int main() {
    std::array<uint8_t, 64> p{};
    p[0]=22; p[1]=254; p[2]=253; p[13]=1;
    assert(glory_dtls_can_start(p.data(),p.size()));
    for(size_t n=0;n<14;n++) assert(!glory_dtls_can_start(p.data(),n));
    for(int t=0;t<256;t++) {p[0]=t; assert(glory_dtls_can_start(p.data(),p.size())==(t==22));}
    p[0]=22;
    for(int v=0;v<256;v++) {p[2]=v; assert(glory_dtls_can_start(p.data(),p.size())==(v==253||v==255));}
    p[2]=253;
    for(int e=1;e<256;e++) {p[4]=e; assert(!glory_dtls_can_start(p.data(),p.size()));}
    p[4]=0; p[3]=1; assert(!glory_dtls_can_start(p.data(),p.size())); p[3]=0;
    for(int t=0;t<256;t++) {p[13]=t; assert(glory_dtls_can_start(p.data(),p.size())==(t==1));}
    p[13]=1; p[1]=255; assert(!glory_dtls_can_start(p.data(),p.size()));
    std::cout << "admission matrix passed\n";
}
