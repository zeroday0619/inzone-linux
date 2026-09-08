/* Reimplemented from pinned INZONEVirtualizer ALC/DRC machine-code behavior.
 * No original DLL or Windows APIs are needed at runtime. Compile without FMA.
 */
#include "dynamics.h"
#include <math.h>
#include <string.h>
static float coeff(int rate,float time){return time==0.0f?0.0f:expf(-1.0f/((float)rate*time));}
static float envelope(float previous,float sample,float decay){float value=fabsf(sample);return (previous<=value?0.0f:decay)*(previous-value)+value;}
void inzone_alc_init(InzoneAlc *s,int channels,int rate,const InzoneAlcParams *p){
    memset(s,0,sizeof(*s));s->channels=channels;s->rate=rate;s->params=*p;
    s->decay=coeff(rate,.01f);s->threshold=powf(10.0f,p->threshold/20.0f);
    s->attack=coeff(rate,p->attack);s->release=coeff(rate,p->release);s->gain[0]=s->gain[1]=1.0f;
}
void inzone_alc_process(InzoneAlc *s,float *samples,size_t frames){
    if(!s->params.enable){memset(s->env,0,sizeof(s->env));s->gain[0]=s->gain[1]=1.0f;return;}
    for(size_t i=0;i<frames;i++)for(int ch=0;ch<s->channels;ch++){
        float x=samples[i*s->channels+ch];float env=envelope(s->env[ch],x,s->decay);
        float target=env>=s->threshold?powf(s->threshold/env,(s->params.ratio-1.0f)/s->params.ratio):1.0f;
        float gain=(s->gain[ch]-target)*(target>=s->gain[ch]?s->release:s->attack)+target;
        s->env[ch]=env;s->gain[ch]=gain;samples[i*s->channels+ch]=gain*x;
    }
}
InzoneDrcParams inzone_drc_preset(int mode){
    if(mode==3)return (InzoneDrcParams){1,-12,-44,-64,2,.01f,.2f,2,.01f,.2f,3,.01f,.2f};
    if(mode==2)return (InzoneDrcParams){1,-15,-35,-50,5,.015f,.05f,5,.005f,.1f,2.2f,.03f,.05f};
    return (InzoneDrcParams){mode!=0,-15,-35,-50,2.5f,.015f,.05f,2.5f,.005f,.1f,1.9f,.03f,.05f};
}
void inzone_drc_init(InzoneDrc *s,int channels,int rate,const InzoneDrcParams *p){
    memset(s,0,sizeof(*s));s->channels=channels;s->rate=rate;s->params=*p;s->decay=coeff(rate,.01f);
    s->upper=powf(10.0f,p->upper/20.0f);s->lower=fminf(s->upper,powf(10.0f,p->lower/20.0f));s->gate=fminf(s->lower,powf(10.0f,p->gate/20.0f));
    s->ua=coeff(rate,p->uattack);s->ur=coeff(rate,p->urelease);s->la=coeff(rate,p->lattack);s->lr=coeff(rate,p->lrelease);s->sa=coeff(rate,p->sattack);s->sr=coeff(rate,p->srelease);
    s->gate_gain=powf(s->lower/s->gate,(p->lratio-1.0f)/p->lratio);
}
void inzone_drc_process(InzoneDrc *s,float *samples,size_t frames){
    if(!s->params.enable){memset(s->env,0,sizeof(s->env));memset(s->gain,0,sizeof(s->gain));memset(s->region,0,sizeof(s->region));return;}
    for(size_t i=0;i<frames;i++)for(int ch=0;ch<s->channels;ch++){
        float x=samples[i*s->channels+ch],env=envelope(s->env[ch],x,s->decay),target;
        int region=s->region[ch];
        if(env<=s->gate){region=0;target=powf(env/s->gate,s->params.sratio-1.0f)*s->gate_gain;}
        else if(env<=s->lower){region=1;target=powf(s->lower/env,(s->params.lratio-1.0f)/s->params.lratio);}
        else if(env<=s->upper){target=1.0f;} /* Native retains the last region here. */
        else {region=2;target=powf(s->upper/env,(s->params.uratio-1.0f)/s->params.uratio);}
        float previous=s->gain[ch],smooth=0;
        if(region==0||(region==1&&previous<1.0f))smooth=previous>target?s->sr:s->sa;
        else if(region==1)smooth=previous>target?s->la:s->lr;
        else if(region==2)smooth=previous>target?s->ua:s->ur;
        float gain=(previous-target)*smooth+target;
        s->env[ch]=env;s->gain[ch]=gain;s->region[ch]=region;
        samples[i*s->channels+ch]=fminf(1.0f,fmaxf(-1.0f,x*gain));
    }
}
