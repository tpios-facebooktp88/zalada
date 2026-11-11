#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

// ─── Floating Panel ───────────────────────────────────────
static UILabel *gLabel = nil;
static UIWindow *gWin  = nil;

static void showPanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gWin) {
            gWin = [[UIWindow alloc] initWithFrame:
                CGRectMake(10, 60,
                    UIScreen.mainScreen.bounds.size.width - 20, 200)];
            gWin.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
            gWin.layer.cornerRadius = 12;
            gWin.clipsToBounds = YES;
            gWin.windowLevel = UIWindowLevelAlert + 100;

            gLabel = [[UILabel alloc] initWithFrame:
                CGRectInset(gWin.bounds, 10, 10)];
            gLabel.numberOfLines = 0;
            gLabel.font = [UIFont systemFontOfSize:11];
            gLabel.textColor = [UIColor colorWithRed:0.3
                                              green:1.0
                                               blue:0.5
                                              alpha:1.0];
            [gWin addSubview:gLabel];

            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = UIColor.clearColor;
            gWin.rootViewController = vc;
            gWin.hidden = NO;

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                initWithTarget:gWin
                        action:@selector(lf_handlePan:)];
            [gWin addGestureRecognizer:pan];
        }
        gLabel.text = text;
        gWin.hidden = NO;
    });
}

// ─── Message handler ──────────────────────────────────────
@interface LFHandler : NSObject <WKScriptMessageHandler>
@end

@implementation LFHandler
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *url      = body[@"url"]      ?: @"";
    NSArray  *elements = body[@"elements"] ?: @[];

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"[LazadaFarm]\nURL: %@\n\n", url];
    if (elements.count > 0) {
        [text appendFormat:@"Elements (%lu):\n",
            (unsigned long)elements.count];
        for (NSString *el in elements)
            [text appendFormat:@"• %@\n", el];
    } else {
        [text appendString:@"Chưa thấy element xu/checkin"];
    }
    showPanel(text);
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

// ─── Swizzle ──────────────────────────────────────────────
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
    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) return;
    Method m = class_getInstanceMethod(wk,
        @selector(initWithFrame:configuration:));
    if (!m) return;
    gOrigInit = method_setImplementation(m, (IMP)swizzled_init);
}