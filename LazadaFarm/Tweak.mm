#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

// ─── Forward declarations ─────────────────────────────────
@interface LFGestureHandler : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)handlePinch:(UIPinchGestureRecognizer *)g;
- (void)handleDoubleTap:(UITapGestureRecognizer *)g;
@end

@interface LFHandler : NSObject <WKScriptMessageHandler>
@end

// ─── Globals ──────────────────────────────────────────────
static UIWindow   *gWin     = nil;
static UITextView *gTV      = nil;
static BOOL        gVisible = YES;
static CGFloat     gScale   = 1.0;
static CGSize      gBaseSize;

// ─── Snap to edge ─────────────────────────────────────────
static void snapToEdge(void) {
    CGFloat sw    = UIScreen.mainScreen.bounds.size.width;
    CGFloat sh    = UIScreen.mainScreen.bounds.size.height;
    CGRect  fr    = gWin.frame;
    CGFloat cx    = fr.origin.x + fr.size.width / 2.0;
    CGFloat margin = 10;

    CGFloat tx = (cx < sw / 2.0)
        ? margin
        : sw - fr.size.width - margin;

    CGFloat ty = fr.origin.y;
    if (ty < 44)                        ty = 44;
    if (ty + fr.size.height > sh - 34)  ty = sh - fr.size.height - 34;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ gWin.frame = CGRectMake(tx, ty, fr.size.width, fr.size.height); }
                     completion:nil];
}

static void updatePanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gTV.text    = text;
        gWin.hidden = !gVisible;
    });
}

// ─── Gesture Handler ──────────────────────────────────────
@implementation LFGestureHandler

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint d  = [g translationInView:nil];
    gWin.center = CGPointMake(gWin.center.x + d.x, gWin.center.y + d.y);
    [g setTranslation:CGPointZero inView:nil];
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        snapToEdge();
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        gScale = MAX(0.4, MIN(2.5, gScale * g.scale));
        CGFloat nw = gBaseSize.width  * gScale;
        CGFloat nh = gBaseSize.height * gScale;
        CGPoint c  = gWin.center;
        gWin.frame = CGRectMake(c.x - nw/2, c.y - nh/2, nw, nh);
        gTV.frame  = CGRectInset(gWin.bounds, 8, 6);
        gTV.font   = [UIFont systemFontOfSize:MAX(8, 10 * gScale)];
        g.scale    = 1.0;
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    gVisible = !gVisible;
    [UIView animateWithDuration:0.2 animations:^{
        gWin.alpha = gVisible ? 1.0 : 0.0;
    } completion:^(BOOL done) {
        gWin.hidden = !gVisible;
        gWin.alpha  = 1.0;
    }];
}

@end

// ─── Setup panel ──────────────────────────────────────────
static void setupPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat sw = UIScreen.mainScreen.bounds.size.width;
        gBaseSize  = CGSizeMake(sw - 20, 180);

        gWin = [[UIWindow alloc] initWithFrame:
            CGRectMake(10, 60, gBaseSize.width, gBaseSize.height)];
        gWin.backgroundColor        = [UIColor colorWithWhite:0.05 alpha:0.88];
        gWin.layer.cornerRadius     = 14;
        gWin.clipsToBounds          = YES;
        gWin.windowLevel            = UIWindowLevelAlert + 100;
        gWin.userInteractionEnabled = YES;

        gTV = [[UITextView alloc] initWithFrame:CGRectInset(gWin.bounds, 8, 6)];
        gTV.backgroundColor            = UIColor.clearColor;
        gTV.textColor                  = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
        gTV.font                       = [UIFont fontWithName:@"Menlo" size:10]
                                         ?: [UIFont systemFontOfSize:10];
        gTV.editable                   = NO;
        gTV.selectable                 = NO;
        gTV.userInteractionEnabled     = NO;
        gTV.text                       = @"[LazadaFarm] chờ WebView...";
        [gWin addSubview:gTV];

        LFGestureHandler *gh = [[LFGestureHandler alloc] init];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:gh action:@selector(handlePan:)];
        [gWin addGestureRecognizer:pan];

        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
            initWithTarget:gh action:@selector(handlePinch:)];
        [gWin addGestureRecognizer:pinch];

        UITapGestureRecognizer *dtap = [[UITapGestureRecognizer alloc]
            initWithTarget:gh action:@selector(handleDoubleTap:)];
        dtap.numberOfTapsRequired = 2;
        [gWin addGestureRecognizer:dtap];

        UIViewController *vc    = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        gWin.rootViewController = vc;
        gWin.hidden             = NO;
    });
}

// ─── Message handler ──────────────────────────────────────
@implementation LFHandler
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;

    NSString *url      = body[@"url"]      ?: @"";
    NSArray  *elements = body[@"elements"] ?: @[];

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"[LazadaFarm]\n%@\n\n", url];
    if (elements.count > 0) {
        [text appendFormat:@"Elements (%lu):\n", (unsigned long)elements.count];
        for (NSString *el in elements)
            [text appendFormat:@"• %@\n", el];
    } else {
        [text appendString:@"Chưa thấy element xu/checkin"];
    }
    updatePanel(text);
}
@end

// ─── JS ───────────────────────────────────────────────────
static NSString *kScript = @""
"(function(){"
"var last='';"
"setInterval(function(){"
"var url=location.href;"
"var found=[];"
"var els=document.querySelectorAll('button,div,span,a');"
"for(var i=0;i<els.length;i++){"
"var e=els[i];"
"var t=(e.textContent||'').trim();"
"var c=(e.className||'').toString();"
"if((t.match(/điểm danh|checkin|check.in|xu|coins|nhiệm vụ|task|claim|nhận/i)"
"||c.match(/checkin|check-in|coin|task|reward|claim/i))"
"&&t.length>0&&t.length<80){"
"found.push(t.substring(0,60));}"
"}"
"if(url!==last||found.length>0){"
"last=url;"
"try{window.webkit.messageHandlers.lazadaFarm"
".postMessage({url:url,elements:found});}catch(e){}}"
"},1000);"
"})();";

// ─── Swizzle WKWebView ────────────────────────────────────
static IMP gOrigInit = NULL;

static id swizzled_init(id self, SEL _cmd,
                        CGRect frame,
                        WKWebViewConfiguration *cfg) {
    WKUserScript *s = [[WKUserScript alloc]
        initWithSource:kScript
         injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:NO];
    [cfg.userContentController addUserScript:s];
    [cfg.userContentController
        addScriptMessageHandler:[[LFHandler alloc] init]
                           name:@"lazadaFarm"];
    return ((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOrigInit)
        (self, _cmd, frame, cfg);
}

// ─── Constructor ──────────────────────────────────────────
__attribute__((constructor))
static void Init(void) {
    setupPanel();

    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) return;
    Method m = class_getInstanceMethod(wk,
        @selector(initWithFrame:configuration:));
    if (!m) return;
    gOrigInit = method_setImplementation(m, (IMP)swizzled_init);
}