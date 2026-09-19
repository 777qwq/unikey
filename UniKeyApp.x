#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#include <QuartzCore/QuartzCore.h>

// App侧 = 哑中继 v2.6.1：双层捕获（零文件操作，沙盒免疫）
//  L1 UIApplication sendEvent —— 常规 App 按键路径（抖音等已验证）
//  L2 IOHIDEvent HID 分发层 —— 游戏外设映射在更底层直接吃键，在此截获
// 2.6.1 关键修复：IOKit 符号全部改 dlsym 运行时解析 + MSHookFunction 手动挂钩
//  （2.6.0 链接期引用 IOKit → 未加载 IOKit 的进程里整个 dylib 加载失败 → L1 陪葬 → 零通知）
// 两层统一 200ms 去重 → notify_post("com.user.unikey.key.<HID usage+2000>")
// SB 侧监听 2000-2600 执行 unikey.conf 绑定动作

// ---- HID 私有 API（常量/签名经 vendor IOHIDEventTypes.h 与 IOKit.tbd 核实）----
// kIOHIDEventTypeKeyboard = 3
// kIOHIDEventFieldKeyboardUsagePage = 0x30000 / Usage = 0x30001
// kIOHIDEventFieldKeyboardDown = 0x30002 / Repeat = 0x30003
// void MSHookFunction(void *symbol, void *replace, void **result)  // ellekit 提供
typedef struct __IOHIDEvent *UKHIDEventRef;
void MSHookFunction(void *symbol, void *replace, void **result);

static unsigned int (*uk_evGetType)(UKHIDEventRef);
static int (*uk_evGetInt)(UKHIDEventRef, unsigned int);
static void (*uk_clientOrig)(void *, UKHIDEventRef);
static void (*uk_connOrig)(void *, UKHIDEventRef);

static long g_lastCode = 0;
static CFTimeInterval g_lastTime = 0;

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
    if (uk_evGetType(ev) != 3) return; // 仅键盘事件
    if (uk_evGetInt(ev, 0x30003) != 0) return; // 跳过重复
    int down = uk_evGetInt(ev, 0x30002);
    int usage = uk_evGetInt(ev, 0x30001);
    if (down > 0 && usage > 0) UKPost(2000 + usage);
}

static void uk_hook_client(void *client, UKHIDEventRef ev) {
    UKInspectHID(ev);
    uk_clientOrig(client, ev);
}

static void uk_hook_conn(void *conn, UKHIDEventRef ev) {
    UKInspectHID(ev);
    uk_connOrig(conn, ev);
}

static void UKInstallHIDHooks(void) {
    @try {
        uk_evGetType = (unsigned int (*)(UKHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        uk_evGetInt  = (int (*)(UKHIDEventRef, unsigned int))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        void *dc = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        void *dn = dlsym(RTLD_DEFAULT, "IOHIDEventSystemConnectionDispatchEvent");
        if (!uk_evGetType || !uk_evGetInt) {
            NSLog(@"[UniKeyApp] HID accessors missing, L2 skipped");
            return;
        }
        if (dc) MSHookFunction(dc, (void *)uk_hook_client, (void **)&uk_clientOrig);
        if (dn) MSHookFunction(dn, (void *)uk_hook_conn, (void **)&uk_connOrig);
        NSLog(@"[UniKeyApp] L2 HID hooks: client=%p conn=%p", dc, dn);
    } @catch (NSException *e) { }
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
                        if (!enc || !(enc[0]=='q'||enc[0]=='i'||enc[0]=='I'||enc[0]=='l')) continue;
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
    NSLog(@"[UniKeyApp] 2.6.1 relay loaded in %@", bid);
    // 延迟挂 L2：等 IOKit 就绪，且不阻塞进程启动（构造函数延迟执行铁律）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UKInstallHIDHooks();
    });
}
