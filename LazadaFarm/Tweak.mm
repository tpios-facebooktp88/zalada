#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

// ─── Panel ────────────────────────────────────────────────
static UIWindow *gWin   = nil;
static UILabel  *gLabel = nil;
static BOOL      gVisible = YES;

static void setupPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat w = UIScreen.mainScreen.bounds.size.width;

        gWin = [[UIWindow alloc] initWithFrame:CGRectMake(0, 44, w, 160)];
        gWin.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.75];
        gWin.layer.cornerRadius = 0;
        gWin.windowLevel        = UIWindowLevelAlert + 100;

        // QUAN TRỌNG: không block touch xuống Lazada
        gWin.userInteractionEnabled = NO;

        gLabel = [[UILabel alloc] initWithFrame:
            CGRectInset(gWin.bounds, 8, 6)];
        gLabel.numberOfLines        = 0;
        gLabel.font                 = [UIFont systemFontOfSize:10];
        gLabel.textColor            = [UIColor colorWithRed:0.2
                                                      green:1.0
                                                       blue:0.4
                                                      alpha:1.0];
        gLabel.userInteractionEnabled = NO;
        gLabel.text = @"[LazadaFarm] chờ WebView...";
        [gWin addSubview:gLabel];

        UIViewController *vc    = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        gWin.rootViewController = vc;
        gWin.hidden             = NO;
    });
}

static void updatePanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gLabel.text = text;
        gWin.hidden = !gVisible;
    });
}

// Lắc máy để ẩn/hiện panel
static void observeShake(void) {
    // Hook sendEvent trên UIApplication
    Class cls = [UIApplication class];
    SEL orig   = @selector(sendEvent:);
    SEL swz    = @selector(lf_sendEvent:);

    __block IMP origImp = NULL;
    IMP newImp = imp_implementationWithBlock(^(UIApplication *app, UIEvent *event) {
        if (event.type == UIEventTypeMotion) {
            for (UIEventSubtype sub = 0; sub < 10; sub++) {
                // subtype 1 = shake
            }
            gVisible = !gVisible;
            dispatch_async(dispatch_get_main_queue(), ^{
                gWin.hidden = !gVisible;
            });
        }
        ((void(*)(id,SEL,UIEvent*))origImp)(app, orig, event);
    });

    Method m = class_getInstanceMethod(cls, orig);
    origImp  = method_setImplementation(m, newImp);
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
    observeShake();

    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) return;
    Method m = class_getInstanceMethod(wk,
        @selector(initWithFrame:configuration:));
    if (!m) return;
    gOrigInit = method_setImplementation(m, (IMP)swizzled_init);
}