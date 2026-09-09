#ifndef INZONE_LADSPA_H
#define INZONE_LADSPA_H

#include <ladspa.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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
void *inzone_dsp_memmove(void *destination, const void *source, size_t count)
    __asm__("memmove") __attribute__((swift_attr("@_noLocks")));

/* File access is restricted to LADSPA instantiation. Audio callbacks never
 * perform file I/O or inspect process environment state.
 */
int inzone_dsp_open(const char *path, int flags) __asm__("open");
int inzone_dsp_openat(int directory, const char *path, int flags) __asm__("openat");
ssize_t inzone_dsp_read(int file, void *destination, size_t count) __asm__("read");
int inzone_dsp_close(int file) __asm__("close");
int inzone_dsp_fstat(int file, struct stat *status) __asm__("fstat");
int *inzone_dsp_errno_location(void) __asm__("__errno_location");
char *inzone_dsp_getenv(const char *name) __asm__("getenv");

int inzone_dsp_debug_open(const char *path);

static inline void inzone_dsp_debug_write(int file, const char *message, size_t count) {
    while (count > 0) {
        ssize_t result = write(file, message, count);
        if (result > 0) {
            message += result;
            count -= (size_t)result;
        } else if (result < 0 && errno == EINTR) {
            continue;
        } else {
            return;
        }
    }
}

enum {
    INZONE_DSP_DIRECTORY_FLAGS = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
    INZONE_DSP_FILE_FLAGS = O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
    INZONE_DSP_FILE_TYPE_MASK = S_IFMT,
    INZONE_DSP_REGULAR_FILE = S_IFREG,
    INZONE_DSP_INTERRUPTED = EINTR,
};

#endif
