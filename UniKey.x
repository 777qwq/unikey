#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <time.h>

static void UKLog(NSString *msg) {
    @try {
        FILE *f = fopen("/var/mobile/unikey.log", "a");
        if (!f) return;
        time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
        fprintf(f, "[UK %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
        fclose(f);
    } @catch (NSException *e) { }
}

static id SafeMsg(id obj, SEL sel) {
    if (!obj || !sel) return nil;
    @try {
        if (![obj respondsToSelector:sel]) return nil;
        return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) { return nil; }
}

// 深挖一个按键事件的全部可用信息
static void DumpKeyEvent(UIEvent *event) {
    @try {
        // 1) UIPress 数组
        id presses = SafeMsg(event, sel_registerName("allPresses"));
        if (![presses isKindOfClass:[NSSet class]]) presses = [event allTouches]; // fallback
        if ([presses isKindOfClass:[NSSet class]]) {
            for (id press in presses) {
                @try {
                    id typeObj = SafeMsg(press, sel_registerName("type"));
                    long ptype = -1;
                    if ([typeObj isKindOfClass:[NSNumber class]]) ptype = [typeObj longValue];
                    else if (typeObj) ptype = -2; /* non-numeric type */
                    id phase = SafeMsg(press, sel_registerName("phase"));
                    long pphase = [phase isKindOfClass:[NSNumber class]] ? [phase longValue] : -1;
                    UKLog([NSString stringWithFormat:@"  press type=%ld(0x%lx) phase=%ld", ptype, ptype, pphase]);
                } @catch (NSException *e) { }
            }
        }
        // 2) 修饰键/输入串/键码（各私有属性 SafeMsg 探测）
        NSString *report = @"";
        const char *sels[] = {"input", "_inputString", "modifierFlags", "_modifierFlags",
                              "hidUsage", "_hidUsage", "keyCode", "_keyCode", "_keyboardInputMode",
                              "keyboardInputMode", "_characters", "_unmodifiedInput", NULL};
        for (int i = 0; sels[i]; i++) {
            id v = SafeMsg(event, sel_registerName(sels[i]));
            if (v) {
                NSString *s = [NSString stringWithFormat:@"%@", v];
                if (s.length > 80) s = [s substringToIndex:80];
                report = [report stringByAppendingFormat:@" %@=%@", @(sels[i]), s];
            }
        }
        if (report.length) UKLog([NSString stringWithFormat:@"  detail:%@", report]);
    } @catch (NSException *e) { }
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        UIEventType type = event.type;
        if (type == 4) { // UIPhysicalKeyboardEvent，过滤hover刷屏
            UKLog(@"KEY EVENT:");
            DumpKeyEvent(event);
        }
    } @catch (NSException *e) { }
    %orig;
}

%end

%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    UKLog(@"unikey 0.2 loaded (deep recon)");
}
