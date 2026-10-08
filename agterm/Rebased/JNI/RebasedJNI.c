#include "RebasedJNI.h"
#include "jni.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static JavaVM *jvm;
static bool starting;
static bool started_once;
static rb_event_callback event_callback;
static _Thread_local char reply[4096];

static const char *answer(const char *text) {
    snprintf(reply, sizeof(reply), "%s", text ? text : "Rebased JNI error");
    return reply;
}

bool rb_jvm_created(void) {
    pthread_mutex_lock(&state_lock);
    bool created = jvm != NULL;
    pthread_mutex_unlock(&state_lock);
    return created;
}

void rb_test_set_started_once(bool started) {
    pthread_mutex_lock(&state_lock);
    if (!jvm && !starting) started_once = started;
    pthread_mutex_unlock(&state_lock);
}

// JNI's Modified UTF-8 would corrupt supplementary characters in project paths.
static jstring java_string(JNIEnv *env, const char *text) {
    CFStringRef value = CFStringCreateWithCString(NULL, text ? text : "", kCFStringEncodingUTF8);
    if (!value) return NULL;
    CFIndex length = CFStringGetLength(value);
    UniChar *characters = malloc((size_t)(length + 1) * sizeof(UniChar));
    if (!characters) { CFRelease(value); return NULL; }
    CFStringGetCharacters(value, CFRangeMake(0, length), characters);
    jstring result = (*env)->NewString(env, (const jchar *)characters, (jsize)length);
    free(characters);
    CFRelease(value);
    return result;
}

static char *utf8(JNIEnv *env, jstring value) {
    if (!value) return strdup("");
    const jchar *characters = (*env)->GetStringChars(env, value, NULL);
    if (!characters) return NULL;
    CFStringRef string = CFStringCreateWithCharacters(NULL, characters, (*env)->GetStringLength(env, value));
    (*env)->ReleaseStringChars(env, value, characters);
    if (!string) return NULL;
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
    char *result = malloc((size_t)capacity);
    if (result && !CFStringGetCString(string, result, capacity, kCFStringEncodingUTF8)) { free(result); result = NULL; }
    CFRelease(string);
    return result;
}

static const char *exception_error(JNIEnv *env, const char *context) {
    jthrowable exception = (*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    char *detail = NULL;
    if (exception) {
        jclass type = (*env)->GetObjectClass(env, exception);
        jmethodID method = type ? (*env)->GetMethodID(env, type, "toString", "()Ljava/lang/String;") : NULL;
        jstring description = method ? (*env)->CallObjectMethod(env, exception, method) : NULL;
        if (!(*env)->ExceptionCheck(env)) detail = utf8(env, description);
        (*env)->ExceptionClear(env);
        if (description) (*env)->DeleteLocalRef(env, description);
        if (type) (*env)->DeleteLocalRef(env, type);
        (*env)->DeleteLocalRef(env, exception);
    }
    snprintf(reply, sizeof(reply), "%s%s%s", context, detail ? ": " : "", detail ? detail : "");
    free(detail);
    return reply;
}

typedef jint (*create_jvm)(JavaVM **, void **, void *);
struct start_request {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    bool done;
    char error[4096];
    create_jvm create;
    JavaVMOption *options;
    int count;
    char *main_class;
};

static void finish_start(struct start_request *request, const char *error) {
    for (int index = 0; index < request->count; index++) free(request->options[index].optionString);
    free(request->options);
    free(request->main_class);
    pthread_mutex_lock(&request->lock);
    if (error) snprintf(request->error, sizeof(request->error), "%s", error);
    request->done = true;
    pthread_cond_signal(&request->ready);
    pthread_mutex_unlock(&request->lock);
}

static void *start_main(void *context) {
    struct start_request *request = context;
    JavaVM *created = NULL;
    JNIEnv *env = NULL;
    JavaVMInitArgs args = { .version = JNI_VERSION_21, .nOptions = request->count, .options = request->options, .ignoreUnrecognized = JNI_FALSE };
    jint result = request->create(&created, (void **)&env, &args);
    if (result != JNI_OK) {
        char error[128];
        snprintf(error, sizeof(error), "JNI_CreateJavaVM failed: %d", result);
        finish_start(request, error);
        return NULL;
    }
    pthread_mutex_lock(&state_lock);
    jvm = created;
    started_once = true;
    pthread_mutex_unlock(&state_lock);

    jclass main = (*env)->FindClass(env, request->main_class);
    jmethodID method = main ? (*env)->GetStaticMethodID(env, main, "main", "([Ljava/lang/String;)V") : NULL;
    jclass strings = method ? (*env)->FindClass(env, "java/lang/String") : NULL;
    jobjectArray arguments = strings ? (*env)->NewObjectArray(env, 0, strings, NULL) : NULL;
    if (!arguments || (*env)->ExceptionCheck(env)) {
        finish_start(request, exception_error(env, "Cannot resolve Rebased main"));
        (*created)->DetachCurrentThread(created);
        return NULL;
    }
    finish_start(request, NULL);
    (*env)->CallStaticVoidMethod(env, main, method, arguments);
    if ((*env)->ExceptionCheck(env)) {
        const char *error = exception_error(env, "Rebased main failed");
        pthread_mutex_lock(&state_lock);
        rb_event_callback callback = event_callback;
        pthread_mutex_unlock(&state_lock);
        if (callback) callback("failed", error);
    }
    (*created)->DetachCurrentThread(created);
    return NULL;
}

const char *rb_start(const char *libjvm, const char *const *options, int count, const char *main_class) {
    if (!libjvm || !main_class || count < 0 || (count && !options)) return answer("Invalid Rebased JVM startup arguments");
    pthread_mutex_lock(&state_lock);
    if (starting || started_once) {
        const char *error = starting ? "Rebased JVM is already starting" : "Rebased JVM has already been created";
        pthread_mutex_unlock(&state_lock);
        return answer(error);
    }
    starting = true;
    pthread_mutex_unlock(&state_lock);

    const char *error = NULL;
    void *library = dlopen(libjvm, RTLD_NOW | RTLD_GLOBAL);
    struct start_request *request = NULL;
    if (!library) { snprintf(reply, sizeof(reply), "dlopen %s: %s", libjvm, dlerror()); error = reply; goto done; }
    dlerror();
    create_jvm create = (create_jvm)dlsym(library, "JNI_CreateJavaVM");
    const char *symbol_error = dlerror();
    if (!create || symbol_error) { snprintf(reply, sizeof(reply), "JNI_CreateJavaVM: %s", symbol_error ? symbol_error : "symbol missing"); error = reply; goto done; }
    request = calloc(1, sizeof(*request));
    if (!request) { error = answer("Cannot allocate Rebased JVM startup"); goto done; }
    pthread_mutex_init(&request->lock, NULL);
    pthread_cond_init(&request->ready, NULL);
    request->create = create;
    request->main_class = strdup(main_class);
    request->options = calloc((size_t)(count + 1), sizeof(JavaVMOption));
    if (!request->main_class || !request->options) { error = answer("Cannot allocate Rebased JVM arguments"); goto cleanup; }
    for (char *cursor = request->main_class; *cursor; cursor++) if (*cursor == '.') *cursor = '/';
    for (int index = 0; index < count; index++) {
        if (!options[index] || !(request->options[index].optionString = strdup(options[index]))) {
            error = answer("Invalid or unallocatable Rebased JVM option"); goto cleanup;
        }
        request->count++;
    }
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    int thread_error = pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    if (!thread_error) thread_error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (!thread_error) thread_error = pthread_create(&thread, &attributes, start_main, request);
    pthread_attr_destroy(&attributes);
    if (thread_error) { snprintf(reply, sizeof(reply), "Cannot start Rebased JVM thread: %s", strerror(thread_error)); error = reply; goto cleanup; }
    pthread_mutex_lock(&request->lock);
    while (!request->done) pthread_cond_wait(&request->ready, &request->lock);
    if (request->error[0]) error = answer(request->error);
    pthread_mutex_unlock(&request->lock);
    pthread_cond_destroy(&request->ready);
    pthread_mutex_destroy(&request->lock);
    free(request);
    request = NULL;
    goto done;
cleanup:
    for (int index = 0; index < request->count; index++) free(request->options[index].optionString);
    free(request->options);
    free(request->main_class);
    pthread_cond_destroy(&request->ready);
    pthread_mutex_destroy(&request->lock);
    free(request);
done:
    if (library && !rb_jvm_created()) dlclose(library);
    // HotSpot keeps executing from this image for the process lifetime; never DestroyJavaVM or dlclose it.
    pthread_mutex_lock(&state_lock);
    starting = false;
    pthread_mutex_unlock(&state_lock);
    return error;
}

static JNIEnv *attach(JavaVM **vm, bool *attached) {
    pthread_mutex_lock(&state_lock);
    *vm = jvm;
    pthread_mutex_unlock(&state_lock);
    *attached = false;
    if (!*vm) { answer("Rebased JVM has not started"); return NULL; }
    JNIEnv *env = NULL;
    jint result = (**vm)->GetEnv(*vm, (void **)&env, JNI_VERSION_21);
    if (result == JNI_EDETACHED) {
        result = (**vm)->AttachCurrentThreadAsDaemon(*vm, (void **)&env, NULL);
        *attached = result == JNI_OK;
    }
    if (result != JNI_OK) { answer("Cannot attach to the Rebased JVM"); return NULL; }
    if ((*env)->PushLocalFrame(env, 16) != JNI_OK) {
        exception_error(env, "Cannot allocate Rebased JNI local frame");
        if (*attached) (**vm)->DetachCurrentThread(*vm);
        return NULL;
    }
    return env;
}

static void detach(JNIEnv *env, JavaVM *vm, bool attached) {
    (*env)->PopLocalFrame(env, NULL);
    if (attached) (*vm)->DetachCurrentThread(vm);
}

static jobject bridge(JNIEnv *env) {
    jclass system = (*env)->FindClass(env, "java/lang/System");
    jmethodID get = system ? (*env)->GetStaticMethodID(env, system, "getProperties", "()Ljava/util/Properties;") : NULL;
    jobject properties = get ? (*env)->CallStaticObjectMethod(env, system, get) : NULL;
    jclass table = properties ? (*env)->FindClass(env, "java/util/Hashtable") : NULL;
    jmethodID lookup = table ? (*env)->GetMethodID(env, table, "get", "(Ljava/lang/Object;)Ljava/lang/Object;") : NULL;
    jstring key = lookup ? (*env)->NewStringUTF(env, "agterm.rebased.bridge") : NULL;
    jobject result = key ? (*env)->CallObjectMethod(env, properties, lookup, key) : NULL;
    if ((*env)->ExceptionCheck(env)) { exception_error(env, "Cannot read Rebased bridge"); return NULL; }
    if (!result) answer("Rebased bridge is not ready");
    return result;
}

static const char *call_bridge(JNIEnv *env, jobject object, const char *command, const char *argument) {
    jclass type = (*env)->FindClass(env, "java/util/function/BiFunction");
    jmethodID apply = type ? (*env)->GetMethodID(env, type, "apply", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") : NULL;
    jstring cmd = apply ? java_string(env, command) : NULL;
    jstring arg = cmd ? java_string(env, argument) : NULL;
    jstring result = arg ? (*env)->CallObjectMethod(env, object, apply, cmd, arg) : NULL;
    if ((*env)->ExceptionCheck(env)) return exception_error(env, "Rebased bridge call failed");
    if (!result) return answer("Rebased bridge returned no result");
    char *text = utf8(env, result);
    answer(text);
    free(text);
    return reply;
}

const char *rb_bridge_call(const char *command, const char *argument) {
    if (!command) return answer("Rebased bridge command is missing");
    JavaVM *vm;
    bool attached;
    JNIEnv *env = attach(&vm, &attached);
    if (!env) return reply;
    jobject object = bridge(env);
    if (object) call_bridge(env, object, command, argument);
    detach(env, vm, attached);
    return reply;
}

static void host_event(JNIEnv *env, jclass type, jstring kind, jstring payload) {
    (void)type;
    pthread_mutex_lock(&state_lock);
    rb_event_callback callback = event_callback;
    pthread_mutex_unlock(&state_lock);
    char *name = utf8(env, kind), *body = utf8(env, payload);
    if (callback && name && body) callback(name, body);
    free(name);
    free(body);
}

const char *rb_register_events(rb_event_callback callback) {
    pthread_mutex_lock(&state_lock);
    event_callback = callback;
    pthread_mutex_unlock(&state_lock);
    JavaVM *vm;
    bool attached;
    JNIEnv *env = attach(&vm, &attached);
    if (!env) return reply;
    jobject object = bridge(env);
    if (!object) { detach(env, vm, attached); return reply; }
    jclass type = (*env)->GetObjectClass(env, object);
    JNINativeMethod method = { "hostEvent", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)host_event };
    const char *error = NULL;
    if (!type || (*env)->RegisterNatives(env, type, &method, 1) != JNI_OK) {
        error = exception_error(env, "Cannot register Rebased events");
    } else {
        // The plugin buffers ready until the host has registered its native, then hello drains that queue.
        call_bridge(env, object, "hello", "");
        if (strcmp(reply, "ok") != 0) error = reply;
    }
    detach(env, vm, attached);
    return error;
}
