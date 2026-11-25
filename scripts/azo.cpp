// Native port of the alkegi/libazo block decoder. See AZO-LICENSE.txt.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
struct Range {
    const uint8_t *input;
    size_t size, pos=0;
    uint32_t low=0, high=UINT32_MAX, tag=0;
    Range(const uint8_t *p, size_t n): input(p),size(n) {
        for (int i=0;i<32;++i) tag=(tag<<1)|bit();
    }
    unsigned bit() {
        if (pos > size*8+64) throw std::runtime_error("truncated range");
        size_t offset=pos++;
        return offset/8<size ? (input[offset/8]>>(7-offset%8))&1 : 0;
    }
    void rescale() {
        constexpr uint32_t msb=0x80000000, next=0x40000000;
        while ((low&msb)==(high&msb)) {
            low<<=1; high=(high<<1)|1; tag=(tag<<1)|bit();
        }
        while ((low&next) && !(high&next)) {
            low=(low<<1)&~msb; high=(high<<1)|1|msb; tag=((tag<<1)|bit())^msb;
        }
    }
    uint64_t step(unsigned bits) const {
        if (high<low || tag<low || tag>high) throw std::runtime_error("range");
        return std::max<uint64_t>(1, (uint64_t(high)-low+1)>>bits);
    }
    unsigned binary(unsigned probability, unsigned bits) {
        uint64_t boundary=low+step(bits)*probability;
        unsigned value=tag>=boundary;
        if(value) low=boundary; else high=boundary-1;
        rescale(); return value;
    }
    unsigned uniform(unsigned bits) {
        if(!bits) return 0;
        uint64_t unit=step(bits), value=std::min<uint64_t>((tag-low)/unit,(uint64_t(1)<<bits)-1);
        high=low+unit*(value+1)-1; low+=unit*value;
        rescale(); return value;
    }
};
void adapt(unsigned &p, unsigned bit, unsigned total, unsigned rate) {
    if(bit) p-=p>>rate; else p+=(total-p)>>rate;
}
struct History {
    std::array<unsigned,256> probs;
    unsigned state=0;
    History(){probs.fill(2048);}
    unsigned next(Range& r) {
        auto &p=probs[state]; unsigned b=r.binary(p,12);
        adapt(p,b,4096,6); state=((state<<1)|b)&255;
        return b;
    }
};
struct Tree {
    std::vector<unsigned> p;
    explicit Tree(unsigned n):p(n,512){}
    unsigned next(Range &r) {
        unsigned node=1;
        while(node<p.size()) {
            unsigned b=r.binary(p[node],10);
            adapt(p[node],b,1024,4);node=node*2+b;
        }
        return node-p.size();
    }
};
struct Predictor {
    std::vector<Tree> fine,coarse;
    std::vector<int> score;
    unsigned shift;
    Predictor(unsigned n,unsigned alphabet,unsigned s):
        fine(n,Tree(alphabet)),coarse(n>>s,Tree(alphabet)),score(n,0),shift(s){}
    unsigned next(Range& r,unsigned context) {
        auto &a=fine.at(context).p,&b=coarse.at(context>>shift).p;
        uint32_t pa=1,pb=1;unsigned node=1;
        while(node<a.size()) {
            unsigned value=r.binary(score[context]>=0?a[node]:b[node],10);
            adapt(a[node],value,1024,4); adapt(b[node],value,1024,4);
            if((pa|pb)&0xffc00000u) {pa>>=10;pb>>=10;}
            pa*=value?1024-a[node]:a[node];pb*=value?1024-b[node]:b[node];
            node=node*2+value;
        }
        score[context]+=(pa>pb)-(pb>pa);
        return node-a.size();
    }
};
struct Table {
    std::array<uint32_t,128> base{},bits{};
    Table(unsigned first,unsigned start,unsigned step) {
        base[0]=first;
        for(unsigned i=1;i<base.size();i++) {
            bits[i]=i<start?0:(i-start)/step;
            base[i]=base[i-1]+(1u<<bits[i-1]);
        }
    }
    unsigned value(Range &r,unsigned i) const {return base.at(i)+r.uniform(bits.at(i));}
};
template<size_t N> unsigned promote(std::array<unsigned,N>& a,unsigned i) {
    unsigned n=a.at(i);
    std::move_backward(a.begin(),a.begin()+i,a.begin()+i+1);a[0]=n;
    return n;
}
template<size_t N> void push(std::array<unsigned,N>& a,unsigned v) {
    std::move_backward(a.begin(),a.end()-1,a.end());a[0]=v;
}
}
extern "C" int azo_block(const uint8_t *input,size_t n,uint8_t *dst,size_t length) {
    if (!length || !n || length>32*1024*1024) return -1;
    try {
        Range r(input,n);
        Predictor literal(256,256,5), lengths(128,128,4);
        History isMatch,reuse,oldDistance,oldMatch;
        Tree matchSlot(2),distanceSlot(2),newId(128),distanceCode(128);
        Table distances(1,16,4),sizes(2,32,8);
        std::array<unsigned,2> recentD{1,2},recentM{0,1};
        std::array<unsigned,128> lastSize{},lastStart{};
        for(size_t j=0;j<128;j++) lastSize[j]=2+j;
        dst[0]=literal.next(r,0);
        for(unsigned i=1;i<length;) {
            if(!isMatch.next(r)) {dst[i]=literal.next(r,dst[i-1]);++i;continue;}
            unsigned dist,len;
            if(reuse.next(r)) {
                unsigned id;
                if(oldMatch.next(r)) id=promote(recentM,matchSlot.next(r));
                else {id=newId.next(r);push(recentM,id);}
                dist=i-promote(lastStart,id);len=promote(lastSize,id);
            } else {
                if(oldDistance.next(r)) dist=promote(recentD,distanceSlot.next(r));
                else {dist=distances.value(r,distanceCode.next(r));push(recentD,dist);}
                auto code=std::upper_bound(distances.base.begin(),distances.base.end(),dist)-distances.base.begin()-1;
                len=sizes.value(r,lengths.next(r,code));
                push(lastSize,len);push(lastStart,i);
            }
            if(!dist || dist>i || !len || len>length-i) return -1;
            for(unsigned j=0;j<len;j++,i++) dst[i]=dst[i-dist];
        }
        return (r.pos+7)/8>=n?0:-1;
    } catch (...) {return -1;}
}
