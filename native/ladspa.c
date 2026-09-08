/* Native Linux adapters. No allocation, locks, or I/O in the audio callback. */
#include <ladspa.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dynamics.h"
#include "spatial_alc.h"
enum { SPATIAL, DRC, ALC, MIC, BIQUAD, EQ_BIQUAD };
typedef struct {
    unsigned kind, rate, position;
    float *ports[10], controls[5], block[16], ready[16];
    double history[4];
    InzoneSpatialAlc spatial;
    InzoneDrc drc;
    InzoneAlc alc;
} Plugin;
static float control(Plugin *p,int port,float fallback,float lo,float hi){
    float v=p->ports[port]?*p->ports[port]:fallback;
    return isfinite(v)?fmaxf(lo,fminf(hi,v)):fallback;
}
static void configure(Plugin *p,int force){
    float c[5]={0};
    if(p->kind==SPATIAL)c[0]=roundf(control(p,4,1,0,1));
    else if(p->kind==DRC)c[0]=roundf(control(p,4,0,0,2));
    else if(p->kind==MIC)c[0]=roundf(control(p,2,1,0,1));
    else if((p->kind==BIQUAD||p->kind==EQ_BIQUAD)){for(int i=0;i<5;i++)c[i]=control(p,i+2,i==0?1:0,-64,64);}
    else {
        c[0]=roundf(control(p,4,1,0,1));c[1]=control(p,5,-18,-60,0);
        c[2]=control(p,6,1000,1,1000);c[3]=control(p,7,.001f,.0001f,2);
        c[4]=control(p,8,1,.0001f,10);
    }
    if(!force&&!memcmp(c,p->controls,sizeof(c)))return;
    memcpy(p->controls,c,sizeof(c));
    if(p->kind==SPATIAL){
        inzone_spatial_alc_init(&p->spatial,(int)c[0]);p->position=0;
        memset(p->block,0,sizeof(p->block));memset(p->ready,0,sizeof(p->ready));
    } else if((p->kind==BIQUAD||p->kind==EQ_BIQUAD)){memset(p->history,0,sizeof(p->history));
    } else if(p->kind==ALC){
        InzoneAlcParams a={(int)c[0],c[1],c[2],c[3],c[4]};inzone_alc_init(&p->alc,2,p->rate,&a);
    } else {
        InzoneDrcParams d=inzone_drc_preset(p->kind==MIC?(c[0]?3:0):(int)c[0]);
        inzone_drc_init(&p->drc,p->kind==MIC?1:2,p->rate,&d);
    }
}
static LADSPA_Handle instantiate(const LADSPA_Descriptor *d,unsigned long rate){
    if(rate!=48000)return NULL;
    Plugin *p=calloc(1,sizeof(*p));if(!p)return NULL;
    p->kind=(unsigned)(size_t)d->ImplementationData;p->rate=rate;configure(p,1);return p;
}
static void connect(LADSPA_Handle h,unsigned long i,LADSPA_Data *data){if(i<10)((Plugin*)h)->ports[i]=data;}
static void activate(LADSPA_Handle h){configure(h,1);}
static void process(LADSPA_Handle h,unsigned long frames){
    Plugin *p=h;configure(p,0);
    if(p->kind==SPATIAL&&p->ports[5])*p->ports[5]=32;
    for(unsigned long i=0;i<frames;i++){
        float x[2]={p->ports[0][i],(p->kind==MIC||(p->kind==BIQUAD||p->kind==EQ_BIQUAD))?0:p->ports[1][i]};
        for(int ch=0;ch<2;ch++)if(!isfinite(x[ch]))x[ch]=0;
        if(p->kind==SPATIAL){
            unsigned k=2*p->position;
            p->block[k]=x[0];p->block[k+1]=x[1];
            x[0]=p->ready[k];x[1]=p->ready[k+1];
            if(++p->position==8){inzone_spatial_alc_block(&p->spatial,p->block,p->ready);p->position=0;}
        } else if((p->kind==BIQUAD||p->kind==EQ_BIQUAD)){
            double *z=p->history;float *c=p->controls;
            double y;
            if(p->kind==EQ_BIQUAD){
                float v=c[0]*x[0]+c[1]*(float)z[0];v+=c[2]*(float)z[1];v-=c[3]*(float)z[2];v-=c[4]*(float)z[3];y=v;
            }else{
                y=(double)c[1]*z[0]+(double)c[2]*z[1];
                y+=(double)c[0]*(double)x[0];y-=(double)c[4]*z[3];y-=(double)c[3]*z[2];
            }
            z[1]=z[0];z[0]=x[0];z[3]=z[2];z[2]=y;x[0]=(float)y;
        } else if(p->kind==ALC)inzone_alc_process(&p->alc,x,1);
        else inzone_drc_process(&p->drc,x,1);
        if(p->kind==MIC||(p->kind==BIQUAD||p->kind==EQ_BIQUAD))p->ports[1][i]=x[0];
        else {p->ports[2][i]=x[0];p->ports[3][i]=x[1];}
    }
}
static void cleanup(LADSPA_Handle h){free(h);}
#define AI (LADSPA_PORT_AUDIO|LADSPA_PORT_INPUT)
#define AO (LADSPA_PORT_AUDIO|LADSPA_PORT_OUTPUT)
#define CI (LADSPA_PORT_CONTROL|LADSPA_PORT_INPUT)
#define CO (LADSPA_PORT_CONTROL|LADSPA_PORT_OUTPUT)
#define B (LADSPA_HINT_BOUNDED_BELOW|LADSPA_HINT_BOUNDED_ABOVE)
static const LADSPA_PortDescriptor stereo[]={AI,AI,AO,AO,CI,CI,CI,CI,CI};
static const LADSPA_PortDescriptor spatial_ports[]={AI,AI,AO,AO,CI,CO};
static const LADSPA_PortDescriptor biquad_ports[]={AI,AO,CI,CI,CI,CI,CI};
static const char *const biquad_names[]={"Input","Output","b0","b1","b2","a1","a2"};
static const LADSPA_PortRangeHint biquad_hints[]={{0},{0},{B|LADSPA_HINT_DEFAULT_1,-64,64},{B|LADSPA_HINT_DEFAULT_0,-64,64},{B|LADSPA_HINT_DEFAULT_0,-64,64},{B|LADSPA_HINT_DEFAULT_0,-64,64},{B|LADSPA_HINT_DEFAULT_0,-64,64}};
static const LADSPA_PortDescriptor mic_ports[]={AI,AO,CI};
static const char *const spatial_names[]={"Input L","Input R","Output L","Output R","Boost","latency"};
static const char *const drc_names[]={"Input L","Input R","Output L","Output R","Mode"};
static const char *const alc_names[]={"Input L","Input R","Output L","Output R","Enable","Threshold","Ratio","Attack","Release"};
static const char *const mic_names[]={"Input","Output","Enable"};
static const LADSPA_PortRangeHint spatial_hints[]={{0},{0},{0},{0},{B|LADSPA_HINT_INTEGER|LADSPA_HINT_DEFAULT_1,0,1},{B,32,32}};
static const LADSPA_PortRangeHint drc_hints[]={{0},{0},{0},{0},{B|LADSPA_HINT_INTEGER|LADSPA_HINT_DEFAULT_0,0,2}};
static const LADSPA_PortRangeHint alc_hints[]={{0},{0},{0},{0},{B|LADSPA_HINT_INTEGER|LADSPA_HINT_DEFAULT_1,0,1},{B|LADSPA_HINT_DEFAULT_HIGH,-60,0},{B|LADSPA_HINT_DEFAULT_MAXIMUM,1,1000},{B|LADSPA_HINT_LOGARITHMIC|LADSPA_HINT_DEFAULT_LOW,.0001f,2},{B|LADSPA_HINT_DEFAULT_1,.0001f,10}};
static const LADSPA_PortRangeHint mic_hints[]={{0},{0},{B|LADSPA_HINT_INTEGER|LADSPA_HINT_DEFAULT_1,0,1}};
#define DESC(id,label,title,count,ports,names,hints,kind) { .UniqueID=id,.Label=label,.Properties=LADSPA_PROPERTY_HARD_RT_CAPABLE,.Name=title,.Maker="inzone-linux",.Copyright="Local interoperability implementation",.PortCount=count,.PortDescriptors=ports,.PortNames=names,.PortRangeHints=hints,.ImplementationData=(void*)(size_t)kind,.instantiate=instantiate,.connect_port=connect,.activate=activate,.run=process,.cleanup=cleanup }
/* Private local IDs; graph selection uses stable labels and an absolute library path. */
static const LADSPA_Descriptor descriptors[]={
 DESC(59870,"inzone_spatial_alc","INZONE spatial automatic level control",6,spatial_ports,spatial_names,spatial_hints,SPATIAL),
 DESC(59871,"inzone_drc","INZONE game dynamic range control",5,stereo,drc_names,drc_hints,DRC),
 DESC(59872,"inzone_alc","INZONE automatic level control",9,stereo,alc_names,alc_hints,ALC),
 DESC(59873,"inzone_mic_agc","INZONE microphone automatic gain",3,mic_ports,mic_names,mic_hints,MIC),
 DESC(59874,"inzone_biquad","INZONE model biquad (double state)",7,biquad_ports,biquad_names,biquad_hints,BIQUAD),
 DESC(59875,"inzone_eq_biquad","INZONE user EQ biquad (float state)",7,biquad_ports,biquad_names,biquad_hints,EQ_BIQUAD)
};
const LADSPA_Descriptor *ladspa_descriptor(unsigned long i){return i<6?descriptors+i:NULL;}
