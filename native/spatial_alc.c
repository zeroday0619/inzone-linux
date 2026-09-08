/* Original spatial ALC: 8-frame stereo detector, 24-frame lookahead, Q31 log approximation. */
#include "spatial_alc.h"
#include <float.h>
#include <math.h>
#include <string.h>
static double native_log8(double value){
    static const int32_t table[12]={0,-186064426,-372130999,-558195425,-744261998,-930326424,-1116390849,-1302457422,-1488521848,-1674588421,-1860652847,-2046717273};
    int positive=0;
    while(value>=1.0){value*=.5;positive++;}
    int64_t wide=(int64_t)(value*2147483648.0);
    int32_t q=(int32_t)(wide>INT32_MAX?INT32_MAX:(wide<INT32_MIN?INT32_MIN:wide));
    int shift=0;
    while(q<0x40000000&&shift<11){q=(int32_t)((uint32_t)q*2u);shift++;}
    if(shift==11)q=INT32_MAX;
    int64_t x=(int32_t)((uint32_t)q+0x80000000u);
    int64_t square=(int32_t)((x*x)>>31);
    int64_t cube=(int32_t)((square*x)>>31);
    int64_t polynomial=((cube*0x2aaaaaaaLL)>>31)-(square>>1)+x;
    int32_t result=(int32_t)((uint32_t)(polynomial>>3)+(uint32_t)table[shift]);
    return (double)result*0x1p-31+(double)positive*0.08664339756999312;
}
void inzone_spatial_alc_init(InzoneSpatialAlc *s,int boost){memset(s,0,sizeof(*s));s->gain=pow(10.0,(double)boost/20.0);}
void inzone_spatial_alc_block(InzoneSpatialAlc *s,const float *input,float *output){
    double current[8][2],peak=0;
    for(int i=0;i<8;i++)for(int ch=0;ch<2;ch++){
        double x=(double)input[2*i+ch]*s->gain;
        if(fabs(x)<FLT_MIN)x=0;
        current[i][ch]=x;if(fabs(x)>peak)peak=fabs(x);
    }
    double change=peak-s->peak;
    if(change>0)s->peak+=change*((double)0x67d2ec9b*0x1p-31);
    else s->peak*=(double)0x7ac6b85a*0x1p-31;
    double logpeak=native_log8(s->peak);
    double gain=logpeak>0?exp(-logpeak*8):1.0;
    for(int i=0;i<8;i++)for(int ch=0;ch<2;ch++){
        double x=fmin(1.0,fmax(-1.0,s->history[i][ch]*gain));
        if(fabs(x)<FLT_MIN)x=0;
        output[2*i+ch]=(float)x;
    }
    memmove(s->history,s->history+8,16*sizeof(s->history[0]));
    memcpy(s->history+16,current,sizeof(current));
}
