#include "InzoneDBus.h"

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>

struct service_context {
    inzone_dbus_handler handler;
    void *context;
};

static volatile sig_atomic_t service_stopping = 0;

static const char *method_signature(const char *method)
{
    if (!method) return NULL;
    if (strcmp(method, "GetState") == 0) return "";
    if (strcmp(method, "ActivateProfile") == 0 ||
        strcmp(method, "DeleteProfile") == 0 ||
        strcmp(method, "RemoveApplication") == 0) return "s";
    if (strcmp(method, "SetProfileOptions") == 0 ||
        strcmp(method, "CreateProfile") == 0 ||
        strcmp(method, "RenameProfile") == 0 ||
        strcmp(method, "ApplyPreset") == 0) return "ss";
    if (strcmp(method, "SetDeviceField") == 0 ||
        strcmp(method, "SetHostField") == 0) return "si";
    if (strcmp(method, "BindApplication") == 0) return "ssi";
    if (strcmp(method, "SetAutomationEnabled") == 0) return "b";
    return NULL;
}

static int set_error(char **error_message, int result, const char *message)
{
    if (error_message) *error_message = strdup(message ? message : strerror(-result));
    return result;
}

static int handle_request(sd_bus_message *message, void *data, sd_bus_error *error)
{
    struct service_context *service = data;
    const char *method = sd_bus_message_get_member(message);
    const char *signature = method_signature(method);
    const char *first = "";
    const char *second = "";
    int32_t value = 0;
    int boolean_value = 0;
    int result;
    if (!signature) return 0;
    if (strcmp(signature, "ss") == 0) {
        result = sd_bus_message_read(message, signature, &first, &second);
    } else if (strcmp(signature, "si") == 0) {
        result = sd_bus_message_read(message, signature, &first, &value);
    } else if (strcmp(signature, "ssi") == 0) {
        result = sd_bus_message_read(message, signature, &first, &second, &value);
    } else if (strcmp(signature, "s") == 0) {
        result = sd_bus_message_read(message, signature, &first);
    } else if (strcmp(signature, "b") == 0) {
        result = sd_bus_message_read(message, signature, &boolean_value);
        value = boolean_value != 0;
    } else {
        result = 0;
    }
    if (result < 0) return result;

    char *response = NULL;
    char *error_message = NULL;
    result = service->handler(method, first, second, value, &response, &error_message, service->context);
    if (result != 0 || !response) {
        const char *name = result == 1 ? "dev.zeroday0619.Error.InvalidRequest"
                                      : "dev.zeroday0619.Error.OperationFailed";
        sd_bus_error_set(error, name, error_message ? error_message : "The operation failed.");
        free(response);
        free(error_message);
        return -EINVAL;
    }
    result = sd_bus_reply_method_return(message, "s", response);
    if (result >= 0 && strcmp(method, "GetState") != 0) {
        /* A signal supplements polling without holding a HID device lock. */
        sd_bus_emit_signal(sd_bus_message_get_bus(message), INZONE_DBUS_PATH,
                           INZONE_DBUS_INTERFACE, "StateChanged", "s", response);
    }
    free(response);
    free(error_message);
    return result;
}

static const sd_bus_vtable service_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("GetState", "", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ActivateProfile", "s", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("SetProfileOptions", "ss", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("SetDeviceField", "si", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("SetHostField", "si", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("CreateProfile", "ss", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("RenameProfile", "ss", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("DeleteProfile", "s", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ApplyPreset", "ss", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("BindApplication", "ssi", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("RemoveApplication", "s", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("SetAutomationEnabled", "b", "s", handle_request, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_SIGNAL("StateChanged", "s", 0),
    SD_BUS_VTABLE_END
};

static void stop_service(int signal_number)
{
    (void)signal_number;
    service_stopping = 1;
}

int inzone_dbus_serve(inzone_dbus_handler handler, void *context, char **error_message)
{
    if (error_message) *error_message = NULL;
    if (!handler) return set_error(error_message, -EINVAL, "A request handler is required.");
    sd_bus *bus = NULL;
    sd_bus_slot *slot = NULL;
    struct service_context service = {handler, context};
    int result = sd_bus_open_user(&bus);
    if (result < 0) goto finish;
    result = sd_bus_add_object_vtable(bus, &slot, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                     service_vtable, &service);
    if (result < 0) goto finish;
    result = sd_bus_request_name(bus, INZONE_DBUS_NAME, 0);
    if (result < 0) goto finish;

    struct sigaction action = {.sa_handler = stop_service};
    struct sigaction previous_term;
    struct sigaction previous_interrupt;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, &previous_term);
    sigaction(SIGINT, &action, &previous_interrupt);
    service_stopping = 0;
    while (!service_stopping) {
        result = sd_bus_process(bus, NULL);
        if (result < 0) break;
        if (result > 0) continue;
        result = sd_bus_wait(bus, 1000000);
        if (result == -EINTR) continue;
        if (result < 0) break;
    }
    sigaction(SIGTERM, &previous_term, NULL);
    sigaction(SIGINT, &previous_interrupt, NULL);
    if (service_stopping) result = 0;
finish:
    if (result < 0) set_error(error_message, result, NULL);
    sd_bus_slot_unref(slot);
    sd_bus_flush_close_unref(bus);
    return result < 0 ? result : 0;
}

int inzone_dbus_call(const char *method, const char *first, const char *second,
                    int32_t value, char **response, char **error_message)
{
    if (response) *response = NULL;
    if (error_message) *error_message = NULL;
    const char *signature = method_signature(method);
    if (!response || !signature) return set_error(error_message, -EINVAL, "Unknown D-Bus method.");
    if (!first) first = "";
    if (!second) second = "";
    sd_bus *bus = NULL;
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    int result = sd_bus_open_user(&bus);
    if (result < 0) goto finish;
    result = sd_bus_set_method_call_timeout(bus, 90000000);
    if (result < 0) goto finish;
    if (strcmp(signature, "ss") == 0) {
        result = sd_bus_call_method(bus, INZONE_DBUS_NAME, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                   method, &error, &reply, signature, first, second);
    } else if (strcmp(signature, "si") == 0) {
        result = sd_bus_call_method(bus, INZONE_DBUS_NAME, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                   method, &error, &reply, signature, first, value);
    } else if (strcmp(signature, "ssi") == 0) {
        result = sd_bus_call_method(bus, INZONE_DBUS_NAME, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                   method, &error, &reply, signature, first, second, value);
    } else if (strcmp(signature, "s") == 0) {
        result = sd_bus_call_method(bus, INZONE_DBUS_NAME, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                   method, &error, &reply, signature, first);
    } else if (strcmp(signature, "b") == 0) {
        result = sd_bus_call_method(bus, INZONE_DBUS_NAME, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                   method, &error, &reply, signature, (int)(value != 0));
    } else {
        result = sd_bus_call_method(bus, INZONE_DBUS_NAME, INZONE_DBUS_PATH, INZONE_DBUS_INTERFACE,
                                   method, &error, &reply, "");
    }
    if (result < 0) goto finish;
    const char *text = NULL;
    result = sd_bus_message_read(reply, "s", &text);
    if (result < 0) goto finish;
    if (result == 0 || !text) { result = -EBADMSG; goto finish; }
    *response = strdup(text);
    result = *response ? 0 : -ENOMEM;
finish:
    if (result < 0) set_error(error_message, result, error.message);
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
    sd_bus_flush_close_unref(bus);
    return result;
}

void inzone_dbus_free(char *value)
{
    free(value);
}
