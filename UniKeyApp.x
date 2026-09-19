#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <mach-o/dyld.h>
#include <QuartzCore/QuartzCore.h>

// UniKey 2.9.0 定版（App侧）：双层捕获，零日志、零诊断
//  L1 UIApplication sendEvent —— 常规 App 按键路径（抖音/主屏已验证）
//  L2 IOHIDEvent HID 层三路挂钩：
//    a) IOHIDEventSystemClientDispatchEvent（分发路径）
//    b) IOHIDEventSystemConnectionDispatchEvent（连接分发路径）
//    c) IOHIDEventSystemClientRegisterEventCallback 包裹（回调注册路径）
//  IOKit 镜像加载瞬间安装（_dyld_register_func_for_add_image），不赌加载时序
//  200ms 去重 → notify_post("com.user.unikey.key.<HID usage+2000>")

// kIOHIDEventTypeKeyboard=3; Usage=0x30001; Down=0x30002; Repeat=0x30003
// void IOHIDEventSystemClientRegisterEventCallback(client, callback, target, refcon)
typedef struct __IOHIDEvent *UKHIDEventRef;
void MSHookFunction(void *symbol, void *replace, void **result);

static unsigned int (*uk_evGetType)(UKHIDEventRef);
static int (*uk_evGetInt)(UKHIDEventRef, unsigned int);
static void (*uk_clientDispatch)(void *, UKHIDEventRef);
static void (*uk_connDispatch)(void *, UKHIDEventRef);
typedef void (*UKEventCallback)(void *target, void *refcon, void *queue, UKHIDEventRef event);
typedef void (*UKRegisterFn)(void *client, UKEventCallback cb, void *target, void *refcon);
static UKRegisterFn uk_origRegister;

static long g_lastCode = 0;
static CFTimeInterval g_lastTime = 0;
static int g_hidState = 0;   // 0=未装 1=已装

static void UKPost(long code) {
    @try {
        if (code <= 0) return;
        CFTimeInterval now = CACurrentMediaTime();
        if (code == g_lastCode && (now - g_lastTime) < 0.2) return;
        g_lastCode = code; g_lastTime = now;
        notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%ld", code] UTF8String]);
    } @catch (NSException *e) { }
}

static void UKInspectHID(UKHIDEventRef ev) {
    if (!ev || !uk_evGetType || !uk_evGetInt) return;
    unsigned int t = uk_evGetType(ev);
    if (t == 11) return; // digitizer/触摸：高频，直接滤掉
    if (t == 3) { // 键盘
        int repeat = uk_evGetInt(ev, 0x30003);
        if (repeat != 0) return;
        int down = uk_evGetInt(ev, 0x30002);
        int usage = uk_evGetInt(ev, 0x30001);
        if (down > 0 && usage > 0) UKPost(2000 + usage);
        return;
    }
    // 其余类型（旋转/滚轮/手柄等）忽略
}

// ---- L2 挂钩体（覆盖三路收包/分发）----
static void uk_hook_client(void *client, UKHIDEventRef ev) { UKInspectHID(ev); uk_clientDispatch(client, ev); }
static void uk_hook_conn(void *conn, UKHIDEventRef ev) { UKInspectHID(ev); uk_connDispatch(conn, ev); }

typedef struct { UKEventCallback cb; void *target; void *refcon; } UKCbCtx;
static void uk_wrapped_cb(void *target, void *refcon, void *queue, UKHIDEventRef ev) {
    UKCbCtx *ctx = (UKCbCtx *)target;
    UKInspectHID(ev);
    if (ctx && ctx->cb) ctx->cb(ctx->target, ctx->refcon, queue, ev);
}
static void uk_hook_register(void *client, UKEventCallback cb, void *target, void *refcon) {
    UKCbCtx *ctx = (UKCbCtx *)malloc(sizeof(UKCbCtx));
    if (ctx && cb && uk_origRegister) {
        ctx->cb = cb; ctx->target = target; ctx->refcon = refcon;
        uk_origRegister(client, uk_wrapped_cb, ctx, NULL);
        return;
    }
    free(ctx);
    if (uk_origRegister) uk_origRegister(client, cb, target, refcon);
}

static void UKInstallHIDHooks(void) {
    if (g_hidState) return;
    @try {
        uk_evGetType = (unsigned int (*)(UKHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        uk_evGetInt = (int (*)(UKHIDEventRef, unsigned int))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        void *dc = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        void *dn = dlsym(RTLD_DEFAULT, "IOHIDEventSystemConnectionDispatchEvent");
        void *rc = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
        if (!uk_evGetType || !uk_evGetInt || !dc || !dn) return; // IOKit 未就绪，等下次
        MSHookFunction(dc, (void *)uk_hook_client, (void **)&uk_clientDispatch);
        MSHookFunction(dn, (void *)uk_hook_conn, (void **)&uk_connDispatch);
        if (rc && uk_origRegister == NULL) MSHookFunction(rc, (void *)uk_hook_register, (void **)&uk_origRegister);
        g_hidState = 1;
    } @catch (NSException *e) { }
}

static void UKImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (dladdr((void *)mh, &info) && info.dli_fname && strstr(info.dli_fname, "/IOKit")) {
        dispatch_async(dispatch_get_main_queue(), ^{ UKInstallHIDHooks(); });
    }
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event.type == 4) {
            id presses = ((id(*)(id, SEL))objc_msgSend)(event, sel_registerName("allPresses"));
            if ([presses isKindOfClass:[NSSet class]]) {
                for (id press in presses) {
                    @try {
                        Method m = class_getInstanceMethod(object_getClass(press), sel_registerName("type"));
                        if (!m) continue;
                        const char *enc = method_getTypeEncoding(m);
                        if (!enc || !(enc[0]=='i'||enc[0]=='I'||enc[0]=='l'||enc[0]=='q'||enc[0]=='Q')) continue;
                        long ptype = ((long(*)(id, SEL))objc_msgSend)(press, sel_registerName("type"));
                        long pphase = -1;
                        Method pm = class_getInstanceMethod(object_getClass(press), sel_registerName("phase"));
                        if (pm) {
                            const char *penc = method_getTypeEncoding(pm);
                            if (penc && (penc[0]=='q'||penc[0]=='i')) pphase = ((long(*)(id, SEL))objc_msgSend)(press, sel_registerName("phase"));
                        }
                        if (ptype > 0 && pphase == 0) UKPost(ptype);
                    } @catch (NSException *e) { }
                }
            }
        }
    } @catch (NSException *e) { }
    %orig;
}

%end

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid || [bid isEqualToString:@"com.apple.springboard"]) return;
    // IOKit 已加载则注册即触发；未加载则等加载瞬间（先于任何回调注册）
    _dyld_register_func_for_add_image(UKImageAdded);
}
