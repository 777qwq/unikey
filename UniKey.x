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

// 返回类型编码检查：'@'=对象, 整型族=数字, 其他=跳过
typedef enum { RET_UNKNOWN, RET_OBJECT, RET_INT } RetKind;
static RetKind RetKindOf(id obj, SEL sel) {
    @try {
        if (!obj || !sel) return RET_UNKNOWN;
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        if (!m) return RET_UNKNOWN;
        const char *enc = method_getTypeEncoding(m);
        if (!enc || !enc[0]) return RET_UNKNOWN;
        char r = enc[0];
        if (r == '@') return RET_OBJECT;
        if (r=='q'||r=='Q'||r=='i'||r=='I'||r=='l'||r=='L'||r=='c'||r=='C'||r=='s'||r=='S'||r=='B') return RET_INT;
        return RET_UNKNOWN;
    } @catch (NSException *e) { return RET_UNKNOWN; }
}

// 只对返回对象的 selector 使用
static id SafeMsgObj(id obj, SEL sel) {
    @try {
        if (RetKindOf(obj, sel) != RET_OBJECT) return nil;
        return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) { return nil; }
}

// 对返回整型的 selector 使用 typed msgSend
static long SafeMsgInt(id obj, SEL sel) {
    @try {
        if (RetKindOf(obj, sel) != RET_INT) return -1;
        return ((long(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) { return -1; }
}

static void DumpKeyEvent(UIEvent *event) {
    @try {
        // 1) UIPress 列表（对象安全）
        id presses = SafeMsgObj(event, sel_registerName("allPresses"));
        if ([presses isKindOfClass:[NSSet class]]) {
            for (id press in presses) {
                @try {
                    long ptype = SafeMsgInt(press, sel_registerName("type"));
                    long pphase = SafeMsgInt(press, sel_registerName("phase"));
                    if (ptype >= 0) UKLog([NSString stringWithFormat:@"  press type=%ld(usage=0x%lx) phase=%ld", ptype, ptype & 0xFFFF, pphase]);
                } @catch (NSException *e) { }
            }
        }
        // 2) 修饰键与输入串（先查返回类型再调用）
        long mf = SafeMsgInt(event, NSSelectorFromString(@"_modifierFlags"));
        if (mf >= 0) UKLog([NSString stringWithFormat:@"  _modifierFlags=%ld(0x%lx)", mf, mf]);
        long mf2 = SafeMsgInt(event, sel_registerName("modifierFlags"));
        if (mf2 >= 0 && mf2 != mf) UKLog([NSString stringWithFormat:@"  modifierFlags=%ld(0x%lx)", mf2, mf2]);
        id input = SafeMsgObj(event, sel_registerName("input"));
        if (input) UKLog([NSString stringWithFormat:@"  input=%@", input]);
        id chars = SafeMsgObj(event, NSSelectorFromString(@"_characters"));
        if (chars) UKLog([NSString stringWithFormat:@"  _characters=%@", chars]);
        // 3) 完整描述（截400字符）
        @try {
            NSString *desc = [event description];
            if (desc.length > 400) desc = [desc substringToIndex:400];
            desc = [desc stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            UKLog([NSString stringWithFormat:@"  desc=%@", desc]);
        } @catch (NSException *e) { }
    } @catch (NSException *e) {
        UKLog(@"dump exception caught");
    }
}

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event.type == 4) { // 只记键盘事件
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
    UKLog(@"unikey 0.3 loaded (type-aware recon)");
}
