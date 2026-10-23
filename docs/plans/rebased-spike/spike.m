// Throwaway spike for the Rebased overlay (docs/plans/20261007-rebased-overlay-spec.md).
// Boots Rebased's JVM inside a foreign NSApplication, binds the plugin bridge, keeps the IDE project frame
// on a host "slot", and runs the Task 0 checks in auto mode, printing one RESULT line per check.
// Usage: spike <stateDir> <projectDir> [quit-mode: will|should]
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <jni.h>
#include <mach/mach.h>
#ifdef WITH_GHOSTTY
#include "ghostty.h"
#endif

static NSString *const kApp = @"/Applications/Rebased.app";
static CFAbsoluteTime gStart;
static NSString *gStateDir, *gProject, *gQuitMode;
static JavaVM *gVM;
static jobject gBridge;  // global ref
static jmethodID gApply;

static void LogLine(NSString *s) {
    fprintf(stderr, "[spike %6.2fs] %s\n", CFAbsoluteTimeGetCurrent() - gStart, s.UTF8String);
}

static void Result(NSString *name, BOOL pass, NSString *detail) {
    LogLine([NSString stringWithFormat:@"RESULT %@ %@ %@", name, pass ? @"pass" : @"fail", detail]);
}

static NSArray<NSString *> *BuildOptions(NSString **mainClass) {
    NSString *contents = [kApp stringByAppendingPathComponent:@"Contents"];
    NSData *data = [NSData dataWithContentsOfFile:[contents stringByAppendingPathComponent:@"Resources/product-info.json"]];
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *launch = nil;
    for (NSDictionary *l in info[@"launch"]) if ([l[@"os"] isEqual:@"macOS"]) launch = l;
    *mainClass = launch[@"mainClass"];

    NSMutableArray *opts = [NSMutableArray array];
    [opts addObject:[NSString stringWithFormat:@"-XX:ErrorFile=%@/java_error_in_spike_%%p.log", gStateDir]];
    [opts addObject:[NSString stringWithFormat:@"-XX:HeapDumpPath=%@/java_error_in_spike.hprof", gStateDir]];
    NSString *vmFile = [contents stringByAppendingPathComponent:@"bin/rebased.vmoptions"];
    for (NSString *line in [[NSString stringWithContentsOfFile:vmFile encoding:NSUTF8StringEncoding error:nil]
                            componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (t.length && ![t hasPrefix:@"#"]) [opts addObject:t];
    }
    for (NSString *a in launch[@"additionalJvmArguments"])
        [opts addObject:[[a stringByReplacingOccurrencesOfString:@"$APP_PACKAGE" withString:kApp]
                         stringByReplacingOccurrencesOfString:@"$USER_HOME" withString:NSHomeDirectory()]];
    NSMutableArray *cp = [NSMutableArray array];
    for (NSString *jar in launch[@"bootClassPathJarNames"])
        [cp addObject:[contents stringByAppendingPathComponent:[@"lib" stringByAppendingPathComponent:jar]]];
    [opts addObject:[@"-Djava.class.path=" stringByAppendingString:[cp componentsJoinedByString:@":"]]];
    [opts addObject:@"-Dide.native.launcher=true"];
    [opts addObject:[@"-Dsun.java.command=" stringByAppendingString:*mainClass]];
    for (NSString *kind in @[@"config", @"system", @"plugins", @"log"])
        [opts addObject:[NSString stringWithFormat:@"-Didea.%@.path=%@/%@", kind, gStateDir, kind]];
    if ([gQuitMode isEqual:@"menu"]) {
        // IntelliJ draws its menu inside its frame and never touches NSApp.mainMenu.
        [opts addObject:@"-DjbScreenMenuBar.enabled=false"];
        [opts addObject:@"-Dapple.laf.useScreenMenuBar=false"];
        [opts addObject:@"-Dagterm.spike.keys=true"];
    }
    return opts;
}

static void BootJVM(void) {
    NSString *mainClass = nil;
    NSArray *opts = BuildOptions(&mainClass);
    NSString *libjvm = [kApp stringByAppendingPathComponent:@"Contents/jbr/Contents/Home/lib/server/libjvm.dylib"];
    void *h = dlopen(libjvm.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { LogLine([NSString stringWithFormat:@"KILL dlopen: %s", dlerror()]); return; }
    typedef jint (*CreateFn)(JavaVM **, void **, void *);
    CreateFn create = (CreateFn)dlsym(h, "JNI_CreateJavaVM");
    JavaVMOption *jopts = calloc(opts.count, sizeof(JavaVMOption));
    for (NSUInteger i = 0; i < opts.count; i++) jopts[i].optionString = strdup([opts[i] UTF8String]);
    JavaVMInitArgs args = { .version = JNI_VERSION_21, .nOptions = (jint)opts.count, .options = jopts,
                            .ignoreUnrecognized = JNI_FALSE };
    JavaVM *vm = NULL; JNIEnv *env = NULL;
    jint rc = create(&vm, (void **)&env, &args);
    if (rc != JNI_OK) { LogLine([NSString stringWithFormat:@"KILL JNI_CreateJavaVM rc=%d", rc]); return; }
    gVM = vm;
    LogLine(@"JVM created");
    NSString *slashed = [mainClass stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    jclass cls = (*env)->FindClass(env, slashed.UTF8String);
    jmethodID m = (*env)->GetStaticMethodID(env, cls, "main", "([Ljava/lang/String;)V");
    jobjectArray jargs = (*env)->NewObjectArray(env, 0, (*env)->FindClass(env, "java/lang/String"), NULL);
    (*env)->CallStaticVoidMethod(env, cls, m, jargs);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
    LogLine(@"main returned");
    (*vm)->DetachCurrentThread(vm);  // never DestroyJavaVM: HotSpot cannot be created twice
}

static JNIEnv *Env(void) {
    JNIEnv *env = NULL;
    if ((*gVM)->GetEnv(gVM, (void **)&env, JNI_VERSION_21) == JNI_EDETACHED)
        (*gVM)->AttachCurrentThreadAsDaemon(gVM, (void **)&env, NULL);
    return env;
}

static NSString *JString(JNIEnv *env, jstring s) {
    if (!s) return @"";
    const char *c = (*env)->GetStringUTFChars(env, s, NULL);
    NSString *r = [NSString stringWithUTF8String:c];
    (*env)->ReleaseStringUTFChars(env, s, c);
    return r;
}

static NSString *BridgeCall(NSString *cmd, NSString *arg) {
    if (!gBridge) return @"no bridge";
    JNIEnv *env = Env();
    jstring c = (*env)->NewStringUTF(env, cmd.UTF8String), a = (*env)->NewStringUTF(env, arg.UTF8String);
    jobject r = (*env)->CallObjectMethod(env, gBridge, gApply, c, a);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); return @"exception"; }
    NSString *out = JString(env, (jstring)r);
    (*env)->DeleteLocalRef(env, c); (*env)->DeleteLocalRef(env, a);
    if (r) (*env)->DeleteLocalRef(env, r);
    return out;
}

@interface Host : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSWindow *ide;
@property NSMutableSet<NSNumber *> *seen;
@property BOOL fitting, revealed;
@property NSInteger ideChanges, visibleOffSlot, eventsSeen;
@property CFAbsoluteTime bornAt;
@property NSTimer *quiet;
@property NSString *lastDialog;
@property NSInteger hostFinds, keysSeen, keysAtStart;
@property id monitor;
- (void)hostEvent:(NSString *)kind payload:(NSString *)payload;
@end

static Host *gHost;

static void JNICALL HostEventNative(JNIEnv *env, jclass cls, jstring kind, jstring payload) {
    NSString *k = JString(env, kind), *p = JString(env, payload);
    dispatch_async(dispatch_get_main_queue(), ^{ [gHost hostEvent:k payload:p]; });
}

@implementation Host
- (NSRect)slot {
    NSRect h = self.window.frame;
    return NSMakeRect(h.origin.x + 40, h.origin.y + 70, h.size.width - 80, h.size.height - 140);
}

- (void)after:(double)sec do:(dispatch_block_t)b {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.seen = [NSMutableSet set];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1300, 850)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"HOST (pretend agterm)";
    self.window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification object:self.window queue:nil
        usingBlock:^(NSNotification *note) { [self fit]; }];

    // Catch AWT windows in the same run-loop turn they are ordered in, before Core Animation commits.
    CFRunLoopObserverRef obs = CFRunLoopObserverCreateWithHandler(NULL,
        kCFRunLoopBeforeWaiting | kCFRunLoopBeforeSources | kCFRunLoopAfterWaiting, true, -1,
        ^(CFRunLoopObserverRef o, CFRunLoopActivity a) { [self scanWindows]; });
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);

    NSThread *t = [[NSThread alloc] initWithBlock:^{ BootJVM(); }];
    t.stackSize = 8 << 20;
    [t start];
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        if ([self bindBridge]) [timer invalidate];
    }];
    [self after:180 do:^{ LogLine(@"KILL overall timeout"); exit(3); }];
}

- (void)scanWindows {
    for (NSWindow *w in NSApp.windows) {
        if (w == self.window || !w.isVisible || ![w.className hasPrefix:@"AWT"]) continue;
        NSNumber *k = @(w.windowNumber);
        if ([self.seen containsObject:k]) continue;
        [self.seen addObject:k];
        BOOL frameLike = (w.styleMask & NSWindowStyleMaskMiniaturizable) != 0;
        // A frame stays invisible until the host adopts it and its size settles; dialogs and popups do not.
        if (frameLike && w != self.ide) w.alphaValue = 0;
        LogLine([NSString stringWithFormat:@"born %@ #%ld \"%@\" mask 0x%lx %@ -> alpha %.0f", w.className,
                 (long)w.windowNumber, w.title, (unsigned long)w.styleMask, NSStringFromRect(w.frame), w.alphaValue]);
    }
}

- (BOOL)bindBridge {
    if (!gVM) return NO;
    JNIEnv *env = Env();
    jclass sys = (*env)->FindClass(env, "java/lang/System");
    jobject props = (*env)->CallStaticObjectMethod(env, sys,
        (*env)->GetStaticMethodID(env, sys, "getProperties", "()Ljava/util/Properties;"));
    jclass ht = (*env)->FindClass(env, "java/util/Hashtable");
    jstring key = (*env)->NewStringUTF(env, "agterm.rebased.bridge");
    jobject bridge = (*env)->CallObjectMethod(env, props,
        (*env)->GetMethodID(env, ht, "get", "(Ljava/lang/Object;)Ljava/lang/Object;"), key);
    if (!bridge) return NO;
    jclass bcls = (*env)->GetObjectClass(env, bridge);
    JNINativeMethod nm = { "hostEvent", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)HostEventNative };
    if ((*env)->RegisterNatives(env, bcls, &nm, 1) != 0) {
        (*env)->ExceptionDescribe(env);
        Result(@"bridge", NO, @"RegisterNatives failed");
        return YES;
    }
    gBridge = (*env)->NewGlobalRef(env, bridge);
    gApply = (*env)->GetMethodID(env, (*env)->FindClass(env, "java/util/function/BiFunction"), "apply",
                                 "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    LogLine([NSString stringWithFormat:@"bridge bound, hello -> %@", BridgeCall(@"hello", @"")]);
    return YES;
}

- (void)hostEvent:(NSString *)kind payload:(NSString *)payload {
    self.eventsSeen++;
    if ([kind isEqual:@"key"]) { self.keysSeen++; LogLine([NSString stringWithFormat:@"IDE key %@", payload]); return; }
    NSArray *f = [payload componentsSeparatedByString:@"\t"];
    LogLine([NSString stringWithFormat:@"event %@ %@", kind, [payload stringByReplacingOccurrencesOfString:@"\t" withString:@" "]]);
    if ([kind isEqual:@"ready"]) {
        Result(@"bridge", YES, @"`ready` arrived through the RegisterNatives-bound hostEvent after `hello`");
        Result(@"zip-plugin", YES, @"the zip-packaged plugin loaded: its bridge object was published");
        LogLine([NSString stringWithFormat:@"open -> %@", BridgeCall(@"open", gProject)]);
    } else if ([kind isEqual:@"frameOpened"] && !self.ide) {
        NSWindow *w = [NSApp windowWithWindowNumber:[f[1] integerValue]];
        if (!w) { Result(@"frame-owner", NO, @"frameOpened names no window"); return; }
        [self adopt:w];
        if ([gQuitMode isEqual:@"menu"]) [self after:4 do:^{ [self runMenuChecks]; }];
        else [self after:4 do:^{ [self runChecks]; }];
    } else if ([kind isEqual:@"windowOpened"]) {
        NSWindow *w = [NSApp windowWithWindowNumber:[f[0] integerValue]];
        if ([f[1] isEqual:@"welcome"]) {
            [w orderOut:nil];  // never shown in the slot
            LogLine(@"ordered out the Welcome frame");
        } else if ([f[1] hasPrefix:@"frame"]) {
            LogLine(@"a frame with no project after 5 s");
        } else if (w && self.ide.isVisible && !w.parentWindow) {
            [self.window addChildWindow:w ordered:NSWindowAbove];
            if ([f[1] isEqual:@"dialog"]) self.lastDialog = f[0];
            LogLine([NSString stringWithFormat:@"attached %@ %@", f[1], w.className]);
        }
    }
}

- (void)adopt:(NSWindow *)ide {
    self.ide = ide;
    self.bornAt = CFAbsoluteTimeGetCurrent();
    ide.alphaValue = 0;
    for (NSWindowButton b = NSWindowCloseButton; b <= NSWindowZoomButton; b++) [ide standardWindowButton:b].hidden = YES;
    ide.titleVisibility = NSWindowTitleHidden;
    ide.titlebarAppearsTransparent = YES;
    ide.collectionBehavior = (ide.collectionBehavior & ~NSWindowCollectionBehaviorFullScreenPrimary)
                             | NSWindowCollectionBehaviorFullScreenNone;
    [self.window addChildWindow:ide ordered:NSWindowAbove];
    [self fit];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidMoveNotification])
        [nc addObserverForName:name object:ide queue:nil usingBlock:^(NSNotification *note) { [self ideMoved:name]; }];
    [nc addObserverForName:NSWindowDidMiniaturizeNotification object:ide queue:nil usingBlock:^(NSNotification *note) {
        LogLine(@"ide miniaturized, undoing");
        [self.ide deminiaturize:nil];
        if (!self.ide.parentWindow) [self.window addChildWindow:self.ide ordered:NSWindowAbove];
        [self fit];
    }];
    [self armReveal];
    LogLine([NSString stringWithFormat:@"adopted #%ld %@", (long)ide.windowNumber, NSStringFromRect(ide.frame)]);
}

- (void)fit {
    if (!self.ide) return;
    self.fitting = YES;
    [self.ide setFrame:[self slot] display:YES];
    self.fitting = NO;
}

- (void)ideMoved:(NSString *)what {
    if (self.fitting) return;
    self.ideChanges++;
    BOOL off = !NSEqualRects(self.ide.frame, [self slot]);
    if (off && self.ide.alphaValue > 0 && self.ide.isVisible) self.visibleOffSlot++;
    LogLine([NSString stringWithFormat:@"ide-initiated %@ to %@ alpha %.0f, snapping back", what,
             NSStringFromRect(self.ide.frame), self.ide.alphaValue]);
    [self fit];
    if (!self.revealed) [self armReveal];
}

- (void)armReveal {
    [self.quiet invalidate];
    self.quiet = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:NO block:^(NSTimer *t) {
        self.revealed = YES;
        self.ide.alphaValue = 1;
        LogLine([NSString stringWithFormat:@"revealed %.2fs after adoption, %ld IDE changes absorbed while invisible",
                 CFAbsoluteTimeGetCurrent() - self.bornAt, (long)self.ideChanges]);
    }];
}

- (BOOL)onSlot { return NSEqualRects(self.ide.frame, [self slot]) && !self.ide.isMiniaturized && self.ide.isVisible; }

- (void)runChecks {
    NSInteger absorbed = self.ideChanges;
    __block NSMutableArray *ownerNotes = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"%ld IDE changes absorbed before reveal", (long)absorbed]];
    __block BOOL ownerOK = self.revealed && [self onSlot] && self.visibleOffSlot == 0;
    NSArray *steps = @[@"selfResize", @"zoom", @"minimize"];
    double t = 0;
    for (NSString *s in steps) {
        [self after:t do:^{ LogLine([NSString stringWithFormat:@"%@ -> %@", s, BridgeCall(s, @"")]); }];
        [self after:t + 2.5 do:^{
            BOOL ok = [self onSlot];
            ownerOK = ownerOK && ok;
            [ownerNotes addObject:[NSString stringWithFormat:@"%@ %@", s, ok ? @"back on slot" : NSStringFromRect(self.ide.frame)]];
        }];
        t += 3;
    }
    [self after:t do:^{ [self.ide toggleFullScreen:nil]; }];
    [self after:t + 2.5 do:^{
        BOOL ok = [self onSlot] && !(self.ide.styleMask & NSWindowStyleMaskFullScreen);
        ownerOK = ownerOK && ok;
        [ownerNotes addObject:[NSString stringWithFormat:@"IDE full screen %@", ok ? @"refused" : @"entered"]];
        [ownerNotes addObject:[NSString stringWithFormat:@"%ld visible off-slot moments", (long)self.visibleOffSlot]];
        Result(@"frame-owner", ownerOK, [ownerNotes componentsJoinedByString:@"; "]);
    }];
    t += 3;

    [self after:t do:^{ LogLine([NSString stringWithFormat:@"hide -> %@", BridgeCall(@"hide", @"")]); }];
    [self after:t + 2 do:^{
        NSString *hidden = [NSString stringWithFormat:@"after hide visible=%d parent=%d", self.ide.isVisible,
                            self.ide.parentWindow != nil];
        LogLine(hidden);
        LogLine([NSString stringWithFormat:@"show -> %@", BridgeCall(@"show", @"")]);
        NSInteger number = self.ide.windowNumber;
        [self after:2 do:^{
            NSWindow *now = [NSApp windowWithWindowNumber:number];
            BOOL reattached = NO;
            if (self.ide.isVisible && !self.ide.parentWindow) {
                [self.window addChildWindow:self.ide ordered:NSWindowAbove];
                reattached = YES;
            }
            [self fit];
            [self.ide makeKeyAndOrderFront:nil];
            [self after:1 do:^{
                BOOL ok = now == self.ide && self.ide.isVisible && self.ide.parentWindow == self.window
                          && NSApp.keyWindow == self.ide && [self onSlot];
                Result(@"hide-show", ok, [NSString stringWithFormat:@"%@; after show same NSWindow=%d visible=%d "
                       "re-attach needed=%d key=%@", hidden, now == self.ide, self.ide.isVisible, reattached,
                       NSApp.keyWindow.className]);
            }];
        }];
    }];
    t += 6;

    [self after:t do:^{ [self.window toggleFullScreen:nil]; }];
    [self after:t + 3 do:^{
        BOOL fs = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
        BOOL ok = fs && self.ide.parentWindow == self.window && self.ide.isOnActiveSpace && [self onSlot];
        NSString *in = [NSString stringWithFormat:@"in: host fs=%d child=%d activeSpace=%d onSlot=%d", fs,
                        self.ide.parentWindow == self.window, self.ide.isOnActiveSpace, [self onSlot]];
        [self.window toggleFullScreen:nil];
        [self after:3 do:^{
            BOOL out = !(self.window.styleMask & NSWindowStyleMaskFullScreen) && self.ide.isOnActiveSpace && [self onSlot];
            Result(@"full-screen", ok && out, [NSString stringWithFormat:@"%@; out: activeSpace=%d onSlot=%d", in,
                   self.ide.isOnActiveSpace, [self onSlot]]);
        }];
    }];
    t += 7;

    [self after:t do:^{ LogLine([NSString stringWithFormat:@"dialog -> %@", BridgeCall(@"dialog", @"")]); }];
    [self after:t + 2 do:^{
        NSWindow *d = self.lastDialog ? [NSApp windowWithWindowNumber:self.lastDialog.integerValue] : nil;
        LogLine([NSString stringWithFormat:@"EXTRA dialog-attach: dialog=%@ parent-is-host=%d", d.className,
                 d.parentWindow == self.window]);
        LogLine([NSString stringWithFormat:@"closeDialogs -> %@", BridgeCall(@"closeDialogs", @"")]);
    }];
    t += 3;

    NSString *file = [gProject stringByAppendingPathComponent:@"a.txt"];
    [self after:t do:^{ LogLine([NSString stringWithFormat:@"edit -> %@", BridgeCall(@"edit", file)]); }];
    [self after:t + 1.5 do:^{
        NSString *disk = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
        LogLine([NSString stringWithFormat:@"before quit, edit on disk already: %d", [disk hasPrefix:@"EDIT"]]);
        [NSApp terminate:nil];
    }];
}

static NSString *MenuName(void) {
    return NSApp.mainMenu.itemArray.count > 1 ? NSApp.mainMenu.itemArray[1].title : @"?";
}

- (void)hostFind:(id)sender { LogLine(@"HOST menu Cmd-F fired"); self.hostFinds++; }

- (void)sendCmdF {
    NSWindow *w = NSApp.keyWindow;
    NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil characters:@"f"
        charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
    NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil characters:@"f"
        charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
    [NSApp postEvent:up atStart:NO];
    [NSApp postEvent:down atStart:YES];
}

- (void)runMenuChecks {
    [self.ide makeKeyAndOrderFront:nil];
    [self after:2 do:^{
        LogLine([NSString stringWithFormat:@"IDE key=%d, main menu \"%@\" (host's is HOST-MENU)", NSApp.keyWindow == self.ide, MenuName()]);
        self.keysAtStart = self.keysSeen;
        [self sendCmdF];
    }];
    [self after:4 do:^{
        LogLine([NSString stringWithFormat:@"no routing: host Cmd-F fired %ld, IDE saw %ld keys", (long)self.hostFinds,
                 (long)(self.keysSeen - self.keysAtStart)]);
        // Route every key to the IDE window ahead of the menu while it is key.
        self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            NSWindow *key = NSApp.keyWindow;
            if (![key.className hasPrefix:@"AWT"]) return e;  // any IDE window: frame, dialog, popup
            [key sendEvent:e];
            return nil;
        }];
        self.hostFinds = 0; self.keysAtStart = self.keysSeen;
        [self sendCmdF];
    }];
    [self after:6 do:^{
        LogLine([NSString stringWithFormat:@"routed: host Cmd-F fired %ld, IDE saw %ld keys", (long)self.hostFinds,
                 (long)(self.keysSeen - self.keysAtStart)]);
        LogLine([NSString stringWithFormat:@"main menu now \"%@\"", MenuName()]);
        LogLine([NSString stringWithFormat:@"menuInfo -> %@", BridgeCall(@"menuInfo", @"")]);
        [NSApp terminate:nil];
    }];
}

- (void)saveAtQuit:(NSString *)where {
    NSString *file = [gProject stringByAppendingPathComponent:@"a.txt"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSString *r = BridgeCall(@"saveAll", @"");
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    NSString *disk = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    BOOL saved = [disk hasPrefix:@"EDIT"];
    Result(@"save-at-quit", [r hasPrefix:@"ok"] && saved && dt < 2,
           [NSString stringWithFormat:@"called from %@ on a blocked main thread: %@ in %.2fs, edit on disk %d",
            where, r, dt, saved]);
    LogLine([NSString stringWithFormat:@"SUMMARY events=%ld", (long)self.eventsSeen]);
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (![gQuitMode isEqual:@"should"]) return NSTerminateNow;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self saveAtQuit:@"applicationShouldTerminate+terminateLater"];
        [NSApp replyToApplicationShouldTerminate:YES];
    });
    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    if ([gQuitMode isEqual:@"will"]) [self saveAtQuit:@"applicationWillTerminate"];
    if ([gQuitMode isEqual:@"menu"]) LogLine(@"SUMMARY menu run done");
    LogLine(@"host terminating");
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return NO; }
@end

// AWT inserts its items into the installed main menu and aborts on an empty one, as any real host has one.
static NSMenu *BuildMenu(void) {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Spike" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    NSMenuItem *hostItem = [[NSMenuItem alloc] initWithTitle:@"HOST-MENU" action:nil keyEquivalent:@""];
    hostItem.submenu = [[NSMenu alloc] initWithTitle:@"HOST-MENU"];
    [hostItem.submenu addItemWithTitle:@"Host Find" action:@selector(hostFind:) keyEquivalent:@"f"].target = gHost;
    [bar addItem:hostItem];
    return bar;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gStart = CFAbsoluteTimeGetCurrent();
        gStateDir = [NSString stringWithUTF8String:argv[1]];
        gProject = [NSString stringWithUTF8String:argv[2]];
        gQuitMode = argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"will";
#ifdef WITH_GHOSTTY
        LogLine([NSString stringWithFormat:@"ghostty_init rc=%d", ghostty_init((uintptr_t)argc, (char **)argv)]);
#endif
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        gHost = [Host new];
        NSApp.mainMenu = BuildMenu();
        NSApp.delegate = gHost;
        [NSApp run];
    }
}
