#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <QuartzCore/QuartzCore.h>

// App侧 = 哑中继 v2.6.0：双层捕获（零文件操作，沙盒免疫）
//  L1 UIApplication sendEvent —— 常规 App 按键路径（抖音等已验证）
//  L2 IOHIDEvent HID 分发层 —— 游戏外设映射在更底层直接吃键（和平精英），在此截获
// 两层统一 200ms 去重 → notify_post("com.user.unikey.key.<HID usage+2000>")
// SB 侧监听 2000-2600 执行 unikey.conf 绑定动作

// ---- IOKit HID 私有 API（常量/签名均经 vendor 头文件与 IOKit.tbd 核实）----
// kIOHIDEventTypeKeyboard = 3
// kIOHIDEventFieldKeyboardUsagePage = 3<<16|0 = 0x30000
// kIOHIDEventFieldKeyboardUsage     = 3<<16|1 = 0x30001
// kIOHIDEventFieldKeyboardDown      = 3<<16|2 = 0x30002
// kIOHIDEventFieldKeyboardRepeat    = 3<<16|3 = 0x30003
// void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef)
// void IOHIDEventSystemConnectionDispatchEvent(IOHIDEventSystemConnectionRef, IOHIDEventRef)
typedef struct __IOHIDEvent *UKHIDEventRef;
unsigned int IOHIDEventGetType(UKHIDEventRef event);
int IOHIDEventGetIntegerValue(UKHIDEventRef event, unsigned int field);
void IOHIDEventSystemClientDispatchEvent(void *client, UKHIDEventRef event);
void IOHIDEventSystemConnectionDispatchEvent(void *connection, UKHIDEventRef event);

static long g_lastCode = 0;
static CFTimeInterval g_lastTime = 0;

static void UKPost(long code) {
    @try {
        if (code <= 0) return;
        CFTimeInterval now = CACurrentMediaTime();
        if (code == g_lastCode && (now - g_lastTime) < 0.2) return;
        g_lastCode = code;
        g_lastTime = now;
        notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%ld", code] UTF8String]);
    } @catch (NSException *e) { }
}

// L2 检查：键盘事件（type=3）按下且非重复 → 发通知（usage+2000 与 UIEvent 约定一致）
static void UKInspectHID(UKHIDEventRef ev) {
    @try {
        if (!ev) return;
        if (IOHIDEventGetType(ev) != 3) return;
        int usage  = IOHIDEventGetIntegerValue(ev, 0x30001);
        int down   = IOHIDEventGetIntegerValue(ev, 0x30002);
        int repeat = IOHIDEventGetIntegerValue(ev, 0x30003);
        if (down > 0 && usage > 0 && repeat == 0) UKPost(2000 + usage);
    } @catch (NSException *e) { }
}

%hookf(void, IOHIDEventSystemClientDispatchEvent, void *client, UKHIDEventRef event) {
    UKInspectHID(event);
    %orig;
}

%hookf(void, IOHIDEventSystemConnectionDispatchEvent, void *connection, UKHIDEventRef event) {
    UKInspectHID(event);
    %orig;
}

// L1：常规 UIEvent 路径（原逻辑，去重收敛到 UKPost）
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
    NSLog(@"[UniKeyApp] 2.6.0 relay loaded in %@", bid);
}
