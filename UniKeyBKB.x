#import <Foundation/Foundation.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <stdlib.h>

// BackBoard 侧 v2.7.0：系统级键盘监视
// backboardd = 全系统 HID 事件第一站：外设盒子游戏模式在 App 进程内不发键盘事件
// （佳影守护进程在系统层吃键再注入触摸），只能在源头截获。
// 仅 HID 三路钩（与 UniKeyApp L2 相同代码，已在多 App 验证稳定），无 UIEvent 钩。
// 键盘 usage → 2000+usage（F5=2062，与 UIEvent 路径约定一致）
// 手柄按键 → 2600+btn；诊断：9996 = backboardd 装载成功
// 注意：backboardd 崩溃 = 安全模式，本文件保持极简，禁止新增文件/网络操作

// kIOHIDEventTypeKeyboard=3 / Button=2 / Digitizer=11
// Usage=0x30001 Down=0x30002 Repeat=0x30003
// ButtonDown=0x20004 ButtonNumber=0x20001
// void MSHookFunction(void *symbol, void *replace, void **result)  // ellekit 提供
typedef struct __IOHIDEvent *UKHIDEventRef;
static void (*uk_hookfn)(void *, void *, void **); // MSHookFunction 运行时解析

static unsigned int (*uk_evGetType)(UKHIDEventRef);
static int (*uk_evGetInt)(UKHIDEventRef, unsigned int);
static void (*uk_clientDispatch)(void *, UKHIDEventRef);
static void (*uk_connDispatch)(void *, UKHIDEventRef);
typedef void (*UKEventCallback)(void *target, void *refcon, void *queue, UKHIDEventRef event);
typedef void (*UKRegisterFn)(void *client, UKEventCallback cb, void *target, void *refcon);
static UKRegisterFn uk_origRegister;

static long g_lastCode = 0;
static double g_lastTime = 0;
static int g_hidState = 0;
static BOOL g_sawReg = NO;
static BOOL g_isDaemon = NO; // 运行于 ldysdaemon（佳影守护进程）
static BOOL g_sawKb = NO;   // BKB首次见到键盘事件 → 9997

static void UKDiag(int code) {
    @try { notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%d", code] UTF8String]); } @catch (NSException *e) { }
}

static void UKPost(long code) {
    @try {
        if (code <= 0) return;
        double now = (double)mach_absolute_time() / 1000000000.0; // arm64 iOS = ns
        if (code == g_lastCode && (now - g_lastTime) < 0.2) return;
        g_lastCode = code; g_lastTime = now;
        notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%ld", code] UTF8String]);
    } @catch (NSException *e) { }
}

static unsigned int g_seenTypes = 0; // 每类型一次性诊断位图

static void UKInspectHID(UKHIDEventRef ev) {
    if (!ev || !uk_evGetType || !uk_evGetInt) return;
    unsigned int t = uk_evGetType(ev);
    if (t == 11) return; // digitizer/触摸：高频
    if (t < 32 && !(g_seenTypes & (1u << t))) {
        g_seenTypes |= (1u << t);
        notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%lu", 3000UL + (unsigned long)t] UTF8String]);
    }
    if (t == 3) { // 键盘
        if (!g_sawKb) { g_sawKb = YES; UKDiag(g_isDaemon ? 9988 : 9997); }
        int repeat = uk_evGetInt(ev, 0x30003);
        if (repeat != 0) return;
        int down = uk_evGetInt(ev, 0x30002);
        int usage = uk_evGetInt(ev, 0x30001);
        if (down > 0 && usage > 0) UKPost(2000 + usage);
        return;
    }
    if (t == 2) { // Button/手柄：诊断期不滤 down，看看到底有哪些键号
        int btn = uk_evGetInt(ev, 0x20001);
        if (btn > 0) UKPost(2600 + btn);
        return;
    }
}

// ---- 钩子体：分发/连接分发路径 ----
static void uk_hook_client(void *client, UKHIDEventRef ev) { UKInspectHID(ev); uk_clientDispatch(client, ev); }
static void uk_hook_conn(void *conn, UKHIDEventRef ev) { UKInspectHID(ev); uk_connDispatch(conn, ev); }

typedef struct { UKEventCallback cb; void *target; void *refcon; } UKCbCtx;

static void UKCbFwd(void *target, void *refcon, void *queue, UKHIDEventRef ev) {
    UKCbCtx *ctx = (UKCbCtx *)target;
    if (ctx && ctx->cb) ctx->cb(ctx->target, ctx->refcon, queue, ev);
}

static void uk_wrapped_cb(void *target, void *refcon, void *queue, UKHIDEventRef ev) {
    @try { UKInspectHID(ev); } @catch (NSException *e) { }
    UKCbFwd(target, refcon, queue, ev);
}

static void uk_hook_register(void *client, UKEventCallback cb, void *target, void *refcon) {
    @try {
        if (cb) {
            UKCbCtx *ctx = (UKCbCtx *)malloc(sizeof(UKCbCtx));
            if (ctx) {
                ctx->cb = cb; ctx->target = target; ctx->refcon = refcon;
                g_sawReg = YES;
                uk_origRegister(client, uk_wrapped_cb, ctx, NULL);
                return;
            }
        }
        uk_origRegister(client, cb, target, refcon);
    } @catch (NSException *e) { }
}

static void UKInstallHIDHooks(void) {
    if (g_hidState) return;
    uk_evGetType = (unsigned int (*)(UKHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    uk_evGetInt = (int (*)(UKHIDEventRef, unsigned int))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    void *dc = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    void *dn = dlsym(RTLD_DEFAULT, "IOHIDEventSystemConnectionDispatchEvent");
    void *rc = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
    if (!uk_evGetType || !uk_evGetInt || !dc || !dn) { NSLog(@"[UniKeyBKB] dlsym incomplete"); return; }
    uk_hookfn = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!uk_hookfn) { NSLog(@"[UniKeyBKB] no substrate in this process"); return; }
    uk_hookfn(dc, (void *)uk_hook_client, (void **)&uk_clientDispatch);
    uk_hookfn(dn, (void *)uk_hook_conn, (void **)&uk_connDispatch);
    if (rc) uk_hookfn(rc, (void *)uk_hook_register, (void **)&uk_origRegister);
    g_hidState = 1;
    NSString *pn = NSProcessInfo.processInfo.processName ?: @"";
    g_isDaemon = [pn isEqualToString:@"ldysdaemon"];
    NSLog(@"[UniKeyBKB] installed in %@ dc=%p dn=%p rc=%p reg=%d", pn, dc, dn, rc, g_sawReg);
    UKDiag(g_isDaemon ? 9989 : 9996);
}

static void UKImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (dladdr((void *)mh, &info) && info.dli_fname && strstr(info.dli_fname, "/IOKit")) {
        // 全局队列：backboardd 有主队列，ldysdaemon 没有
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            UKInstallHIDHooks();
        });
    }
}

%ctor {
    // 注册即对已加载镜像逐个回调（IOKit 已加载则立即触发）；晚加载也会被捕获
    _dyld_register_func_for_add_image(UKImageAdded);
    // 兜底重试
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        UKInstallHIDHooks();
    });
}
