#ifndef AGTERM_REBASED_JNI_H
#define AGTERM_REBASED_JNI_H

#include <stdbool.h>

typedef void (*rb_event_callback)(const char *kind, const char *payload);

// Errors and replies remain valid until the next shim call on the same thread. NULL means success
// for start/registration; bridge_call returns the plugin reply ("ok...") or an error.
const char *rb_start(const char *libjvm, const char *const *options, int count, const char *main_class);
const char *rb_bridge_call(const char *command, const char *argument);
const char *rb_register_events(rb_event_callback callback);
bool rb_jvm_created(void);
void rb_test_set_started_once(bool started);

#endif
