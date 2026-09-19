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

// App侧 = 哑中继 v2.6.2：双层捕获 + 诊断直通（零文件操作，沙盒免疫）
//  L1 UIApplication sendEvent —— 常规 App 按键路径（抖音已验证）
//  L2 IOHIDEvent HID 层三路挂钩：
//    a) IOHIDEventSystemClientDispatchEvent（分发路径）
//    b) IOHIDEventSystemConnectionDispatchEvent（连接分发路径）
//    c) IOHIDEventSystemClientRegisterEventCallback 包裹（回调注册路径，GameController 系）
//  IOKit 镜像加载瞬间安装（_dyld_register_func_for_add_image），不赌加载时序
//  诊断通知：9990=已挂钩 9991=IOKit超时未加载 9992=进程内见到键盘事件 9994=回调包裹生效
// 统一 200ms 去重 → notify_post("com.user.unikey.key.<HID usage+2000>")

// kIOHIDEventTypeKeyboard=3; Usage=0x30001; Down=0x30002; Repeat=0x30003
// typedef void(*IOHIDEventSystemClientEventCallback)(void* target, void* refcon, IOHIDEventQueueRef queue, IOHIDEventRef event)
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
static BOOL g_sawKb = NO;    // 首个键盘事件诊断（每进程一次）
static BOOL g_sawReg = NO;   // 首次回调包裹诊断

static void UKDiag(int code) {
    @try { notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%d", code] UTF8String]); } @catch (NSException *e) { }
}

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
    if (uk_evGetType(ev) != 3) return; // 仅键盘
    if (!g_sawKb) { g_sawKb = YES; UKDiag(9992); }
    int repeat = uk_evGetInt(ev, 0x30003);
    if (repeat != 0) return;
    int down = uk_evGetInt(ev, 0x30002);
    int usage = uk_evGetInt(ev, 0x30001);
    if (down > 0 && usage > 0) UKPost(2000 + usage);
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
        if (!g_sawReg) { g_sawReg = YES; UKDiag(9994); }
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
        UKDiag(9990);
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
    NSLog(@"[UniKeyApp] 2.6.2 relay loaded in %@", bid);
    // IOKit 已加载则注册即触发；未加载则等加载瞬间（先于任何回调注册）
    _dyld_register_func_for_add_image(UKImageAdded);
    // 兜底：10 秒后仍未挂钩 = IOKit 始终未加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!g_hidState) UKDiag(9991);
    });
}
