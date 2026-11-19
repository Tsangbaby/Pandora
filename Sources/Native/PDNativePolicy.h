#ifndef PD_NATIVE_POLICY_H
#define PD_NATIVE_POLICY_H
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

typedef struct { double a,b,c,d,tx,ty; } PDHostMapping;
static inline bool PDMakeHostMapping(double bx,double by,double bw,double bh,
                                    double x,double y,double w,double h,PDHostMapping *out) {
    if (!out || !isfinite(bx) || !isfinite(by) || !isfinite(bw) || !isfinite(bh) ||
        !isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h) || bw<=0 || bh<=0 || w<=0 || h<=0) return false;
    double sx=w/bw,sy=h/bh;
    if (!isfinite(sx) || !isfinite(sy) || sx<=0 || sx>1.001 || fabs(sx-sy)>0.0001) return false;
    PDHostMapping result={sx,0,0,sy,x+w/2-(bx+bw/2),y+h/2-(by+bh/2)};
    if (!isfinite(result.tx) || !isfinite(result.ty)) return false;
    *out=result; return true;
}

// Decode ONLY the reviewed ADRP x1 / ADD x1,x1 / MOV x0,x19 / BL sequence.
static inline bool PDDecodeAssociationKey(uint64_t method,const uint32_t words[4],uint64_t *out) {
    if (!words || !out || method>UINT64_MAX-212 ||
        (words[0]&0x9f00001f)!=0x90000001 || (words[1]&0xffc003ff)!=0x91000021 ||
        words[2]!=0xaa1303e0 || (words[3]&0xfc000000)!=0x94000000) return false;
    int64_t pages=(int64_t)((((uint64_t)words[0]>>5)&0x7ffff)<<2 | ((words[0]>>29)&3));
    if (pages&(1<<20)) pages-=1<<21;
    int64_t delta=pages*4096;
    uint64_t page=(method+212)&~(uint64_t)4095;
    if ((delta<0 && page<(uint64_t)(-delta)) || (delta>=0 && page>UINT64_MAX-(uint64_t)delta)) return false;
    uint64_t key=delta<0?page-(uint64_t)(-delta):page+(uint64_t)delta;
    uint64_t immediate=(words[1]>>10)&0xfff;
    if (key>UINT64_MAX-immediate) return false;
    *out=key+immediate; return true;
}
#endif
