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
static UIWindow     *gWin      = nil;
static UITextView   *gTV       = nil;
static UITextField  *gSearch   = nil;
static UIButton     *gCopyBtn  = nil;
static UILabel      *gCopyFeed = nil;
static BOOL          gVisible  = YES;
static CGFloat       gScale    = 1.0;
static CGSize        gBaseSize;
static NSString     *gFullLog  = @"";

// ─── Snap to edge ─────────────────────────────────────────
static void snapToEdge(void) {
    CGFloat sw = UIScreen.mainScreen.bounds.size.width;
    CGFloat sh = UIScreen.mainScreen.bounds.size.height;
    CGRect  fr = gWin.frame;
    CGFloat cx = fr.origin.x + fr.size.width / 2.0;

    CGFloat tx = (cx < sw / 2.0) ? 10 : sw - fr.size.width - 10;
    CGFloat ty = fr.origin.y;
    if (ty < 44)                       ty = 44;
    if (ty + fr.size.height > sh - 34) ty = sh - fr.size.height - 34;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        gWin.frame = CGRectMake(tx, ty, fr.size.width, fr.size.height);
    } completion:nil];
}

// ─── Filter log by keyword ────────────────────────────────
static void applyFilter(void) {
    NSString *kw = gSearch.text ?: @"";
    if (kw.length == 0) {
        gTV.text = gFullLog;
        return;
    }
    NSMutableString *filtered = [NSMutableString string];
    for (NSString *line in [gFullLog componentsSeparatedByString:@"\n"]) {
        if ([line.lowercaseString containsString:kw.lowercaseString]) {
            [filtered appendFormat:@"%@\n", line];
        }
    }
    gTV.text = filtered.length > 0 ? filtered : @"Không tìm thấy";
}

static void updatePanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gFullLog   = text;
        gTV.text   = text;
        applyFilter();
        gWin.hidden = !gVisible;
    });
}

// ─── Gesture Handler ──────────────────────────────────────
@implementation LFGestureHandler

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint d   = [g translationInView:nil];
    gWin.center = CGPointMake(gWin.center.x + d.x, gWin.center.y + d.y);
    [g setTranslation:CGPointZero inView:nil];
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) snapToEdge();
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        gScale = MAX(0.4, MIN(2.5, gScale * g.scale));
        CGFloat nw = gBaseSize.width  * gScale;
        CGFloat nh = gBaseSize.height * gScale;
        CGPoint c  = gWin.center;
        gWin.frame  = CGRectMake(c.x - nw/2, c.y - nh/2, nw, nh);
        [self relayout];
        g.scale = 1.0;
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

- (void)relayout {
    CGRect b    = gWin.bounds;
    CGFloat bh  = 32; // bottom bar height
    CGFloat sh  = 28; // search height
    CGFloat gap = 4;

    gSearch.frame  = CGRectMake(8, 8, b.size.width - 16, sh);
    gTV.frame      = CGRectMake(0, sh + gap + 8,
                                b.size.width,
                                b.size.height - sh - gap - 8 - bh - gap);
    gTV.font       = [UIFont systemFontOfSize:MAX(8, 10 * gScale)];

    CGFloat btnW   = 80;
    gCopyBtn.frame = CGRectMake(b.size.width/2 - btnW/2,
                                b.size.height - bh,
                                btnW, bh - 4);
    gCopyFeed.frame = CGRectMake(0, b.size.height - bh,
                                 b.size.width, bh - 4);
}

- (void)handleCopy {
    NSString *text = gTV.text ?: @"";
    [UIPasteboard generalPasteboard].string = text;

    gCopyBtn.hidden  = YES;
    gCopyFeed.hidden = NO;
    gCopyFeed.text   = @"✓ Đã copy!";

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gCopyBtn.hidden  = NO;
        gCopyFeed.hidden = YES;
    });
}

- (void)handleSearchChange {
    applyFilter();
}

@end

// ─── Setup panel ──────────────────────────────────────────
static void setupPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat sw = UIScreen.mainScreen.bounds.size.width;
        gBaseSize  = CGSizeMake(sw - 20, 220);

        gWin = [[UIWindow alloc] initWithFrame:
            CGRectMake(10, 60, gBaseSize.width, gBaseSize.height)];
        gWin.backgroundColor        = [UIColor colorWithWhite:0.05 alpha:0.90];
        gWin.layer.cornerRadius     = 14;
        gWin.clipsToBounds          = YES;
        gWin.windowLevel            = UIWindowLevelAlert + 100;
        gWin.userInteractionEnabled = YES;

        // Search bar
        gSearch = [[UITextField alloc] init];
        gSearch.backgroundColor   = [UIColor colorWithWhite:0.15 alpha:1];
        gSearch.textColor         = [UIColor whiteColor];
        gSearch.font              = [UIFont systemFontOfSize:11];
        gSearch.placeholder       = @"🔍 Filter...";
        gSearch.layer.cornerRadius = 6;
        gSearch.clipsToBounds     = YES;
        gSearch.leftView          = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,0)];
        gSearch.leftViewMode      = UITextFieldViewModeAlways;
        [gWin addSubview:gSearch];

        // Log textview
        gTV = [[UITextView alloc] init];
        gTV.backgroundColor        = UIColor.clearColor;
        gTV.textColor              = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
        gTV.font                   = [UIFont fontWithName:@"Menlo" size:10]
                                     ?: [UIFont systemFontOfSize:10];
        gTV.editable               = NO;
        gTV.selectable             = NO;
        gTV.userInteractionEnabled = YES;
        gTV.text                   = @"[LazadaFarm] chờ WebView...";
        [gWin addSubview:gTV];

        // Copy button
        gCopyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [gCopyBtn setTitle:@"Copy Log" forState:UIControlStateNormal];
        [gCopyBtn setTitleColor:[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0]
                       forState:UIControlStateNormal];
        gCopyBtn.backgroundColor        = [UIColor colorWithWhite:0.15 alpha:1];
        gCopyBtn.layer.cornerRadius     = 8;
        gCopyBtn.titleLabel.font        = [UIFont systemFontOfSize:12];
        [gWin addSubview:gCopyBtn];

        // Copy feedback label
        gCopyFeed = [[UILabel alloc] init];
        gCopyFeed.textAlignment = NSTextAlignmentCenter;
        gCopyFeed.textColor     = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
        gCopyFeed.font          = [UIFont systemFontOfSize:12];
        gCopyFeed.hidden        = YES;
        [gWin addSubview:gCopyFeed];

        LFGestureHandler *gh = [[LFGestureHandler alloc] init];

        // Wire copy button
        [gCopyBtn addTarget:gh
                     action:@selector(handleCopy)
           forControlEvents:UIControlEventTouchUpInside];

        // Wire search
        [gSearch addTarget:gh
                    action:@selector(handleSearchChange)
          forControlEvents:UIControlEventEditingChanged];

        // Gestures on window
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:gh action:@selector(handlePan:)];
        pan.minimumNumberOfTouches = 2; // 2 finger drag - không conflict với scroll
        [gWin addGestureRecognizer:pan];

        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
            initWithTarget:gh action:@selector(handlePinch:)];
        [gWin addGestureRecognizer:pinch];

        UITapGestureRecognizer *dtap = [[UITapGestureRecognizer alloc]
            initWithTarget:gh action:@selector(handleDoubleTap:)];
        dtap.numberOfTapsRequired = 2;
        [gWin addGestureRecognizer:dtap];

        [gh relayout];

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
    [text appendFormat:@"URL:\n%@\n\n", url];
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
"if((t.match(/điểm danh|checkin|check.in|xu|coins|nhiệm vụ|task|claim|nhận|kiếm|land|egg|merge|reward/i)"
"||c.match(/checkin|check-in|coin|task|reward|claim|sign|daily/i))"
"&&t.length>0&&t.length<80){"
"found.push(t.substring(0,60)+'  cls=['+c.substring(0,30)+']');}"
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