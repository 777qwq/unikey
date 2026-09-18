#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <QuartzCore/QuartzCore.h>

// App侧 = 哑中继：按键 → Darwin通知（零文件操作，沙盒免疫）
// SB侧监听 com.user.unikey.key.<键码> 并执行绑定动作

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
                        if (ptype > 0 && pphase == 0) {
                            static long lastType = 0;
                            static CFTimeInterval lastTime = 0;
                            CFTimeInterval now = CACurrentMediaTime();
                            if (ptype == lastType && (now - lastTime) < 0.2) continue;
                            lastType = ptype; lastTime = now;
                            notify_post([[NSString stringWithFormat:@"com.user.unikey.key.%ld", ptype] UTF8String]);
                        }
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
    NSLog(@"[UniKeyApp] 2.3.0 relay loaded in %@", bid);
}
