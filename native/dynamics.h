#ifndef INZONE_DYNAMICS_H
#define INZONE_DYNAMICS_H
#include <stddef.h>
typedef struct { int enable; float threshold,ratio,attack,release; } InzoneAlcParams;
/* Native parameter order differs from the YAML presentation. */
typedef struct { int enable; float upper,lower,gate; float uratio,uattack,urelease; float lratio,lattack,lrelease; float sratio,sattack,srelease; } InzoneDrcParams;
typedef struct { int channels,rate; InzoneAlcParams params; float decay,threshold,attack,release,env[2],gain[2]; } InzoneAlc;
typedef struct { int channels,rate; InzoneDrcParams params; float decay,upper,lower,gate,ua,ur,la,lr,sa,sr,gate_gain,env[2],gain[2]; int region[2]; } InzoneDrc;
void inzone_alc_init(InzoneAlc*,int,int,const InzoneAlcParams*);
void inzone_alc_process(InzoneAlc*,float*,size_t);
void inzone_drc_init(InzoneDrc*,int,int,const InzoneDrcParams*);
void inzone_drc_process(InzoneDrc*,float*,size_t);
InzoneDrcParams inzone_drc_preset(int);
#endif
