#ifndef INZONE_DBUS_H
#define INZONE_DBUS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define INZONE_DBUS_NAME "dev.zeroday0619"
#define INZONE_DBUS_PATH "/dev/zeroday0619"
#define INZONE_DBUS_INTERFACE "dev.zeroday0619.Control1"

/* Callback strings are borrowed; returned strings must be allocated with malloc. */
typedef int32_t (*inzone_dbus_handler)(const char *method, const char *first,
                                     const char *second, int32_t value,
                                     char **response, char **error_message,
                                     void *context);

/* Separate connections allow concurrent GUI workers without sharing bus state. */
int inzone_dbus_call(const char *method, const char *first, const char *second,
                    int32_t value, char **response, char **error_message);
int inzone_dbus_serve(inzone_dbus_handler handler, void *context, char **error_message);
void inzone_dbus_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
