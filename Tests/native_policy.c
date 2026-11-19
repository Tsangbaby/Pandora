#include "PDNativePolicy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned count;
#define CHECK(x) do { count++; if(!(x)){fprintf(stderr,"POLICY FAIL line %d\n",__LINE__);return 1;} } while(0)
int main(void){
 PDHostMapping m; memset(&m,0x5a,sizeof(m)); PDHostMapping before=m;
 CHECK(!PDMakeHostMapping(0,0,390,844,NAN,10,100,200,&m));
 CHECK(!memcmp(&before,&m,sizeof(m)));
 CHECK(!PDMakeHostMapping(0,0,0,844,10,10,100,200,&m));
 CHECK(!PDMakeHostMapping(0,0,390,844,0,0,780,1688,&m));
 CHECK(!PDMakeHostMapping(0,0,390,844,0,0,195,844,&m));
 CHECK(!PDMakeHostMapping(0,0,390,844,0,0,195,422,NULL));
 for(int i=2;i<=10;i++)for(int x=-12;x<=12;x+=6)for(int y=0;y<=200;y+=50){
  double scale=i/10.0,tw=390*scale,th=844*scale;
  CHECK(PDMakeHostMapping(0,0,390,844,x,y,tw,th,&m));
  CHECK(fabs(m.a-scale)<1e-12&&fabs(m.d-scale)<1e-12);
  CHECK(fabs((195+m.tx-tw/2)-x)<1e-9&&fabs((422+m.ty-th/2)-y)<1e-9);
  for(int j=0;j<3;j++){
   double px=j*195,py=j*422;
   double visualX=195+m.tx+(px-195)*m.a,visualY=422+m.ty+(py-422)*m.d;
   CHECK(fabs(visualX-(x+scale*px))<1e-9&&fabs(visualY-(y+scale*py))<1e-9);
   CHECK(fabs((visualX-x)/scale-px)<1e-8&&fabs((visualY-y)/scale-py)<1e-8);
  }
 }
 const uint32_t words[4]={0x90058ec1,0x91192021,0xaa1303e0,0x9768e570};
 // This synthetic fixture is replaced below with independently encoded ADRP.
 uint32_t actual[4];memcpy(actual,words,sizeof(actual));
 uint64_t method=0x19ac7b1ec,key=0x19be53648,pc=method+212;
 int64_t pages=(int64_t)((key&~(uint64_t)4095)-(pc&~(uint64_t)4095))/4096;
 uint32_t imm=(uint32_t)pages&0x1fffff;
 actual[0]=0x90000001|((imm&3)<<29)|((imm>>2)<<5);
 actual[1]=0x91000021|((uint32_t)(key&4095)<<10);
 uint64_t result=0;
 CHECK(PDDecodeAssociationKey(method,actual,&result)&&result==key);
 for(int i=0;i<4;i++){
  uint32_t bad[4];memcpy(bad,actual,sizeof(bad));bad[i]=0;
  CHECK(!PDDecodeAssociationKey(method,bad,&result));
 }
 CHECK(!PDDecodeAssociationKey(UINT64_MAX,actual,&result));
 CHECK(!PDDecodeAssociationKey(method,NULL,&result));
 CHECK(!PDDecodeAssociationKey(method,actual,NULL));
 actual[0]=0x90000001;actual[1]=0x91000021;
 CHECK(PDDecodeAssociationKey(0,actual,&result)&&result==0);
 actual[0]=0xf0ffffe1; // negative ADRP that would underflow at address zero.
 CHECK(!PDDecodeAssociationKey(0,actual,&result));
 printf("PANDORA_NATIVE_POLICY_TESTS checks=%u failures=0\n",count);return 0;
}
