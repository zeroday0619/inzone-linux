#ifndef INZONE_SPATIAL_ALC_H
#define INZONE_SPATIAL_ALC_H
#include <stdint.h>
typedef struct {double peak,gain,history[24][2];} InzoneSpatialAlc;
void inzone_spatial_alc_init(InzoneSpatialAlc*,int);
void inzone_spatial_alc_block(InzoneSpatialAlc*,const float*,float*);
#endif
