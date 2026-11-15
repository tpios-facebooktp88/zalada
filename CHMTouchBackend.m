#import "CHMTouchBackend.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>

typedef struct __IOHIDEvent *CHMIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *CHMIOHIDEventSystemClientRef;

@interface UITouch (CHMPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setGestureView:(UIView *)view;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setPhase:(UITouchPhase)phase;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)_setLocationInWindow:(CGPoint)point resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)firstTouch;
- (void)setIsTap:(BOOL)isTap;
- (void)_setHidEvent:(CHMIOHIDEventRef)event;
@end

@interface UIEvent (CHMPrivate)
- (void)_clearTouches;
- (void)_setHIDEvent:(CHMIOHIDEventRef)event;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
@end

@interface UIApplication (CHMPrivate)
- (UIEvent *)_touchesEvent;
@end

@interface CHMTouchBackend ()
@property (nonatomic, strong) UITouch *activeTouch;
@property (nonatomic, strong) UIWindow *activeWindow;
@property (nonatomic, strong) UIView *activeView;
@property (nonatomic) uint32_t activeContextID;
@property (nonatomic) CGPoint activePoint;
@end

// REA's recovered call site passes coordinates/pressure first, then allocator/time
// and digitizer metadata. Keep this ABI order for the private constructor.
// Match the exported IOKit ABI: allocator/time and digitizer metadata
// precede the coordinate/pressure values.
typedef CHMIOHIDEventRef (*CHMCreateDigitizerEventFn)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint8_t, uint8_t, uint32_t);
typedef CHMIOHIDEventRef (*CHMCreateFingerEventFn)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, uint8_t, uint8_t, uint32_t);
typedef CHMIOHIDEventSystemClientRef (*CHMCreateClientFn)(CFAllocatorRef);
typedef void (*CHMSetSenderIDFn)(CHMIOHIDEventRef, uint64_t);
typedef void (*CHMSetIntegerValueFn)(CHMIOHIDEventRef, uint32_t, int);
typedef void (*CHMSetFloatValueFn)(CHMIOHIDEventRef, uint32_t, double);
typedef void (*CHMAppendEventFn)(CHMIOHIDEventRef, CHMIOHIDEventRef, uint32_t);
typedef void (*CHMDispatchEventFn)(CHMIOHIDEventSystemClientRef, CHMIOHIDEventRef);
// Recovered call order: (0, 0, event, windowContextID, 0, 0, 0).
typedef void (*CHMSetDigitizerInfoFn)(
    uint32_t, uint32_t, CHMIOHIDEventRef, uint32_t, uint32_t, uint32_t, uint32_t);

static void *CHMIOKitHandle;
static void *CHMBackBoardHandle;
static CHMIOHIDEventSystemClientRef CHMEventClient;
static CHMCreateDigitizerEventFn CHMCreateDigitizerEvent;
static CHMCreateFingerEventFn CHMCreateFingerEvent;
static CHMCreateClientFn CHMCreateClient;
static CHMSetSenderIDFn CHMSetSenderID;
static CHMSetIntegerValueFn CHMSetIntegerValue;
static CHMSetFloatValueFn CHMSetFloatValue;
static CHMAppendEventFn CHMAppendEvent;
static CHMDispatchEventFn CHMDispatchEvent;
static CHMSetDigitizerInfoFn CHMSetDigitizerInfo;

NSString * const CHMTouchBackendErrorDomain = @"com.tpios.autoclicker.touch";

static void CHMSetError(NSError **error, NSInteger code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:CHMTouchBackendErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

static BOOL CHMLoadHIDAPI(void) {
    static dispatch_once_t onceToken;
    static BOOL available = NO;
    dispatch_once(&onceToken, ^{
        CHMIOKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!CHMIOKitHandle) {
            CHMIOKitHandle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
        }
        CHMBackBoardHandle = dlopen(
            "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            RTLD_NOW);
        if (!CHMIOKitHandle) return;

        CHMCreateDigitizerEvent = (CHMCreateDigitizerEventFn)dlsym(CHMIOKitHandle, "IOHIDEventCreateDigitizerEvent");
        CHMCreateFingerEvent = (CHMCreateFingerEventFn)dlsym(CHMIOKitHandle, "IOHIDEventCreateDigitizerFingerEvent");
        CHMCreateClient = (CHMCreateClientFn)dlsym(CHMIOKitHandle, "IOHIDEventSystemClientCreate");
        CHMSetSenderID = (CHMSetSenderIDFn)dlsym(CHMIOKitHandle, "IOHIDEventSetSenderID");
        CHMSetIntegerValue = (CHMSetIntegerValueFn)dlsym(CHMIOKitHandle, "IOHIDEventSetIntegerValue");
        CHMSetFloatValue = (CHMSetFloatValueFn)dlsym(CHMIOKitHandle, "IOHIDEventSetFloatValue");
        CHMAppendEvent = (CHMAppendEventFn)dlsym(CHMIOKitHandle, "IOHIDEventAppendEvent");
        CHMDispatchEvent = (CHMDispatchEventFn)dlsym(CHMIOKitHandle, "IOHIDEventSystemClientDispatchEvent");
        if (CHMBackBoardHandle) {
            CHMSetDigitizerInfo = (CHMSetDigitizerInfoFn)dlsym(CHMBackBoardHandle, "BKSHIDEventSetDigitizerInfo");
        }

        // BackBoardServices is optional in the original implementation.
        // The core IOKit event path remains available without this enrichment call.
        if (!CHMCreateDigitizerEvent || !CHMCreateFingerEvent || !CHMCreateClient ||
            !CHMSetSenderID || !CHMSetIntegerValue || !CHMSetFloatValue ||
            !CHMAppendEvent || !CHMDispatchEvent) return;

        CHMEventClient = CHMCreateClient(kCFAllocatorDefault);
        available = CHMEventClient != NULL;
    });
    return available;
}

static BOOL CHMIsTPIOSOverlayWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) hasSuffix:@"TPIOSPassThroughWindow"];
}

static UIWindow *CHMActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;

        NSArray<UIWindow *> *appWindows = [((UIWindowScene *)scene).windows
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIWindow *window, NSDictionary *bindings) {
                return !window.hidden && window.alpha > 0.01 &&
                       !CHMIsTPIOSOverlayWindow(window) &&
                       window.windowLevel < UIWindowLevelAlert &&
                       window.rootViewController != nil;
            }]];

        for (UIWindow *window in appWindows) {
            if (window.keyWindow) return window;
        }
        if (appWindows.count > 0) return appWindows.firstObject;
    }
    return nil;
}

static BOOL CHMDispatchHIDTouch(CGPoint point, CHMTouchPhase phase, CHMTouchBackend *backend, NSError **error) {
    if (![NSThread isMainThread]) {
        CHMSetError(error, 4, @"HID touch events must be dispatched on the main thread.");
        return NO;
    }
    if (!CHMLoadHIDAPI()) {
        CHMSetError(error, 5, @"The required IOKit HID entry points are unavailable.");
        return NO;
    }

    BOOL isDown = phase == CHMTouchPhaseDown;
    UIWindow *window = nil;
    UIView *hitView = nil;
    uint32_t contextID = 0;

    if (isDown) {
        // Never begin a second contact while the previous UITouch is retained.
        if (backend.activeTouch) {
            CHMSetError(error, 15, @"A previous touch is still active; refusing a second DOWN.");
            return NO;
        }
        window = CHMActiveWindow();
        if (!window) {
            CHMSetError(error, 6, @"No active application window is available.");
            return NO;
        }
        SEL contextSelector = NSSelectorFromString(@"_contextId");
        if (CHMSetDigitizerInfo && [window respondsToSelector:contextSelector]) {
            contextID = ((uint32_t (*)(id, SEL))objc_msgSend)(window, contextSelector);
        }
    } else {
        // UP must close the same contact in the same window/view/context.
        // Do not select a new key window or re-hit-test a potentially different view.
        window = backend.activeWindow;
        hitView = backend.activeView;
        contextID = backend.activeContextID;
        point = backend.activePoint;
        if (!backend.activeTouch || !window || !hitView) {
            CHMSetError(error, 16, @"The original touch window or view is no longer valid; UP was not dispatched.");
            return NO;
        }
    }

    // The reference helper maps Began (0) and Ended (3) to HID mask 0x27.
    const uint32_t eventMask = 0x27;
    const uint64_t senderID = 0xDEFACEDBEEFFECE5ULL;
    const double force = 0.5;
    const double radius = 0.04;
    const uint32_t fingerIndex = 1; // The scheduler currently drives one active finger.
    const uint8_t inRange = isDown ? 1 : 0;
    const uint8_t inTouch = isDown ? 1 : 0;
    // Scheduler points are window-local; the original Cham path uses screen
    // coordinates for HID and window-local coordinates for UITouch.
    CGPoint hidPoint = [window convertPoint:point toWindow:nil];

    uint64_t timestamp = mach_absolute_time();
    CHMIOHIDEventRef parent = CHMCreateDigitizerEvent(
        kCFAllocatorDefault, timestamp, 3, 0, 0, eventMask, 0,
        hidPoint.x, hidPoint.y, 0.0, force, 0.0,
        inRange, inTouch, 0);
    if (!parent) {
        CHMSetError(error, 8, @"IOHIDEventCreateDigitizerEvent returned null.");
        return NO;
    }

    CHMIOHIDEventRef finger = CHMCreateFingerEvent(
        kCFAllocatorDefault, timestamp, fingerIndex, fingerIndex, eventMask,
        hidPoint.x, hidPoint.y, 0.0, force, 0.0,
        inRange, inTouch, 0);
    if (!finger) {
        CFRelease(parent);
        CHMSetError(error, 9, @"IOHIDEventCreateDigitizerFingerEvent returned null.");
        return NO;
    }

    CHMSetSenderID(parent, senderID);
    CHMSetSenderID(finger, senderID);

    // These field IDs and values are copied from the verified Cham HID call sites.
    CHMSetIntegerValue(parent, 0xB002F, 1);
    CHMSetIntegerValue(parent, 0xB0039, 3);
    CHMSetIntegerValue(parent, 0xB003A, 1);
    CHMSetIntegerValue(parent, 0xB003B, 1);
    CHMSetFloatValue(finger, 0xB0030, radius);
    CHMSetFloatValue(finger, 0xB0031, radius * 0.8);
    CHMAppendEvent(parent, finger, 0);

    UIApplication *application = UIApplication.sharedApplication;
    if (isDown) {
        // Cham's handle, panel, and point markers are overlays on this same
        // UIWindow. Temporarily hide all tagged overlay roots so the touch is
        // associated with the underlying application view, not Cham itself.
        NSMutableArray<UIView *> *hiddenOverlayViews = [NSMutableArray array];
        for (UIView *subview in window.subviews) {
            if (subview.tag == 0x5450494F && !subview.hidden) {
                subview.hidden = YES;
                [hiddenOverlayViews addObject:subview];
            }
        }
        hitView = [window hitTest:point withEvent:nil];
        for (UIView *overlayView in hiddenOverlayViews) {
            overlayView.hidden = NO;
        }
        hitView = hitView ?: window.rootViewController.view;
    }
    UITouch *touch = backend.activeTouch;
    if (!touch && phase == CHMTouchPhaseUp) {
        CFRelease(finger);
        CFRelease(parent);
        CHMSetError(error, 11, @"Cannot end a touch that has no active UITouch object.");
        return NO;
    }
    if (!hitView || ![application respondsToSelector:@selector(_touchesEvent)]) {
        CFRelease(finger);
        CFRelease(parent);
        CHMSetError(error, 12, @"UIKit could not provide a hit-tested view or touch event.");
        return NO;
    }
    if (!touch) touch = [[UITouch alloc] init];
    UIEvent *touchEvent = [application _touchesEvent];
    if (!touch || !touchEvent ||
        ![touch respondsToSelector:@selector(setWindow:)] ||
        ![touch respondsToSelector:@selector(setView:)] ||
        ![touch respondsToSelector:@selector(setTapCount:)] ||
        ![touch respondsToSelector:@selector(setPhase:)] ||
        ![touch respondsToSelector:@selector(setTimestamp:)] ||
        ![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(_setIsFirstTouchForView:)] ||
        ![touch respondsToSelector:@selector(_setHidEvent:)] ||
        ![touchEvent respondsToSelector:@selector(_clearTouches)] ||
        ![touchEvent respondsToSelector:@selector(_setHIDEvent:)] ||
        ![touchEvent respondsToSelector:@selector(_setTimestamp:)] ||
        ![touchEvent respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) {
        CFRelease(finger);
        CFRelease(parent);
        CHMSetError(error, 13, @"The required private UIKit touch selectors are unavailable.");
        return NO;
    }

    NSTimeInterval eventTime = NSProcessInfo.processInfo.systemUptime;
    [touch setWindow:window];
    [touch setView:hitView];
    if ([touch respondsToSelector:@selector(setGestureView:)]) [touch setGestureView:hitView];
    [touch setTapCount:1];
    [touch setPhase:isDown ? UITouchPhaseBegan : UITouchPhaseEnded];
    [touch setTimestamp:eventTime];
    [touch _setLocationInWindow:point resetPrevious:isDown];
    [touch _setIsFirstTouchForView:YES];
    if ([touch respondsToSelector:@selector(setIsTap:)]) [touch setIsTap:YES];
    [touch _setHidEvent:parent];

    [touchEvent _clearTouches];
    [touchEvent _setHIDEvent:parent];
    [touchEvent _setTimestamp:eventTime];
    [touchEvent _addTouch:touch forDelayedDelivery:NO];

    // The original Cham UIKit path explicitly delivers the populated UIEvent.
    [application sendEvent:touchEvent];

    if (CHMSetDigitizerInfo && contextID != 0) {
        CHMSetDigitizerInfo(0, 0, parent, contextID, 0, 0, 0);
    }

    SEL enqueueSelector = NSSelectorFromString(@"_enqueueHIDEvent:");
    if ([application respondsToSelector:enqueueSelector]) {
        ((void (*)(id, SEL, CHMIOHIDEventRef))objc_msgSend)(application, enqueueSelector, parent);
    }
    CHMDispatchEvent(CHMEventClient, parent);

    // Keep the original target context until the matching UP dispatch path.
    if (isDown) {
        backend.activeTouch = touch;
        backend.activeWindow = window;
        backend.activeView = hitView;
        backend.activeContextID = contextID;
        backend.activePoint = point;
    } else {
        backend.activeTouch = nil;
        backend.activeWindow = nil;
        backend.activeView = nil;
        backend.activeContextID = 0;
        backend.activePoint = CGPointZero;
    }

    CFRelease(finger);
    CFRelease(parent);
    return YES;
}

@implementation CHMTouchBackend

- (instancetype)init {
    self = [super init];
    if (self && CHMLoadHIDAPI()) {
        __weak typeof(self) weakSelf = self;
        self.dispatchHandler = ^BOOL(CGPoint point, CHMTouchPhase phase, NSError **error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                CHMSetError(error, 14, @"The touch backend is no longer available.");
                return NO;
            }
            return CHMDispatchHIDTouch(point, phase, self, error);
        };
    }
    return self;
}

- (BOOL)isAvailable {
    return self.dispatchHandler != nil && CHMLoadHIDAPI();
}

- (BOOL)dispatchPoint:(CGPoint)point phase:(CHMTouchPhase)phase error:(NSError **)error {
    CHMTouchDispatchHandler handler = self.dispatchHandler;
    if (!handler) {
        CHMSetError(error, 1, @"No usable iOS HID touch provider is available.");
        return NO;
    }
    if (!isfinite(point.x) || !isfinite(point.y)) {
        CHMSetError(error, 2, @"Touch coordinates must be finite.");
        return NO;
    }
    if (phase != CHMTouchPhaseDown && phase != CHMTouchPhaseUp) {
        CHMSetError(error, 3, @"Unsupported touch phase.");
        return NO;
    }

    NSError * __autoreleasing localError = nil;
    NSError * __autoreleasing *targetError = error ? error : &localError;
    BOOL sent = handler(point, phase, targetError);
    if (!sent && !*targetError) {
        CHMSetError(targetError, 10, @"The HID touch provider rejected the event.");
    }
    return sent;
}

@end


static CHMTouchBackend *TPIOSCHMBackend(void) {
    static CHMTouchBackend *backend;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ backend = [[CHMTouchBackend alloc] init]; });
    return backend;
}

BOOL TPIOSCHMTouchAvailable(void) { return TPIOSCHMBackend().available; }

BOOL TPIOSCHMTouchDispatch(double x, double y, int32_t phase) {
    if (![NSThread isMainThread]) return NO;
    NSError *error = nil;
    BOOL sent = [TPIOSCHMBackend() dispatchPoint:CGPointMake(x, y)
                                           phase:(CHMTouchPhase)phase
                                           error:&error];
    if (!sent) NSLog(@"[TPIOS Touch] %@", error.localizedDescription ?: @"HID dispatch failed");
    return sent;
}