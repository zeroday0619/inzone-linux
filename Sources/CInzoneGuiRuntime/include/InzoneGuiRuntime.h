#ifndef INZONE_GUI_RUNTIME_H
#define INZONE_GUI_RUNTIME_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void inzone_gui_configure(bool smoke_test, const char *screenshot_path,
                          const char *diagnostics_path, bool platform_argument);

#ifdef __cplusplus
}
#endif

#endif
