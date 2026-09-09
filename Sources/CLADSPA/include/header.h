#ifndef INZONE_LADSPA_H
#define INZONE_LADSPA_H

#include <ladspa.h>
#include <stdlib.h>

/* These declarations preserve the C calling convention for the existing libm
 * functions. Their no-lock contract is trusted at the foreign-function boundary;
 * Swift verifies the calling DSP code, not the implementation of libm. The
 * plugin binds external symbols eagerly before any audio callback executes.
 */
float inzone_dsp_expf(float value) __asm__("expf") __attribute__((swift_attr("@_noLocks")));
float inzone_dsp_powf(float base, float exponent) __asm__("powf") __attribute__((swift_attr("@_noLocks")));
float inzone_dsp_fabsf(float value) __asm__("fabsf") __attribute__((swift_attr("@_noLocks")));
float inzone_dsp_fminf(float left, float right) __asm__("fminf") __attribute__((swift_attr("@_noLocks")));
float inzone_dsp_fmaxf(float left, float right) __asm__("fmaxf") __attribute__((swift_attr("@_noLocks")));
float inzone_dsp_roundf(float value) __asm__("roundf") __attribute__((swift_attr("@_noLocks")));
double inzone_dsp_exp(double value) __asm__("exp") __attribute__((swift_attr("@_noLocks")));
double inzone_dsp_pow(double base, double exponent) __asm__("pow") __attribute__((swift_attr("@_noLocks")));
double inzone_dsp_fmin(double left, double right) __asm__("fmin") __attribute__((swift_attr("@_noLocks")));
double inzone_dsp_fmax(double left, double right) __asm__("fmax") __attribute__((swift_attr("@_noLocks")));

#endif
