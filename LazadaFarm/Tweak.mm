#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

// ─── Floating Panel ───────────────────────────────────────
@interface LFPanel : NSObject
+ (instancetype)shared;
- (void)updateURL:(NSString *)url elements:(NSArray<NSString *> *)elements;
@end

@implementation LFPanel {
    UIWindow   *_win;
    UITextView *_tv;
}

+ (instancetype)shared {
    static LFPanel *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [LFPanel new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                scene = (UIWindowScene *)s; break;
            }
        }
        self->_win = [[UIWindow alloc] initWithWindowScene:scene];
        self->_win.windowLevel = UIWindowLevelAlert + 100;
        self->_win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        self->_win.layer.cornerRadius = 12;
        self->_win.clipsToBounds = YES;
        self->_win.frame = CGRectMake(10, 60, UIScreen.mainScreen.bounds.size.width - 20, 220);

        self->_tv = [[UITextView alloc] initWithFrame:self->_win.bounds];
        self->_tv.backgroundColor = UIColor.clearColor;
        self->_tv.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.5 alpha:1];
        self->_tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        self->_tv.editable = NO;
        self->_tv.selectable = YES;
        self->_tv.text = @"[LazadaFarm] chờ WebView load...";
        [self->_win addSubview:self->_tv];

        // Drag gesture
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        [self->_win addGestureRecognizer:pan];

        // Tap để ẩn/hiện
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleTap:)];
        tap.numberOfTapsRequired = 2;
        [self->_win addGestureRecognizer:tap];

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        self->_win.rootViewController = vc;
        self->_win.hidden = NO;
    });
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint delta = [g translationInView:_win];
    _win.center = CGPointMake(_win.center.x + delta.x, _win.center.y + delta.y);
    [g setTranslation:CGPointZero inView:_win];
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    _win.hidden = !_win.hidden;
}

- (void)updateURL:(NSString *)url elements:(NSArray<NSString *> *)elements {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableString *text = [NSMutableString string];
        [text appendFormat:@"[LazadaFarm v2]\n"];
        [text appendFormat:@"URL:\n%@\n\n", url];
        if (elements.count > 0) {
            [text appendFormat:@"Elements tìm thấy (%lu):\n", (unsigned long)elements.count];
            for (NSString *el in elements) {
                [text appendFormat:@" • %@\n", el];
            }
        } else {
            [text appendString:@"Chưa tìm thấy element xu/checkin"];
        }
        self->_tv.text = text;
        self->_win.hidden = NO;
    });
}

@end

// ─── Message handler ──────────────────────────────────────
@interface LFMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation LFMessageHandler
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *url      = body[@"url"]      ?: @"";
    NSArray  *elements = body[@"elements"] ?: @[];
    [[LFPanel shared] updateURL:url elements:elements];
}
@end

// ─── JS inject ────────────────────────────────────────────
static NSString *kScript = @""
"(function(){"
"  var last='';"
"  function scan(){"
"    var url=location.href;"
"    var found=[];"
"    var all=document.querySelectorAll('button,div,span,a');"
"    for(var i=0;i<all.length;i++){"
"      var el=all[i];"
"      var txt=(el.textContent||'').trim();"
"      var cls=(el.className||'').toString();"
"      if(txt.match(/điểm danh|checkin|check.in|xu|coins|coin|nhiệm vụ|task|claim|nhận/i)"
"       ||cls.match(/checkin|check-in|coin|task|reward|claim/i)){"
"        if(txt.length>0&&txt.length<80){"
"          found.push(txt.substring(0,60)+'  ['+cls.substring(0,30)+']');"
"        }"
"      }"
"    }"
"    if(url!==last||found.length>0){"
"      last=url;"
"      try{"
"        window.webkit.messageHandlers.lazadaFarm.postMessage({url:url,elements:found});"
"      }catch(e){}"
"    }"
"  }"
"  setInterval(scan,1200);"
"})();";

// ─── Swizzle IMP ──────────────────────────────────────────
static IMP gOriginalInit = NULL;

static id swizzled_init(id self, SEL _cmd,
                        CGRect frame,
                        WKWebViewConfiguration *config) {
    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:kScript
         injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:NO];
    [config.userContentController addUserScript:script];

    LFMessageHandler *handler = [[LFMessageHandler alloc] init];
    [config.userContentController addScriptMessageHandler:handler
                                                     name:@"lazadaFarm"];

    return ((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOriginalInit)
                (self, _cmd, frame, config);
}

// ─── Constructor ──────────────────────────────────────────
__attribute__((constructor))
static void LazadaFarmInit(void) {
    [LFPanel shared]; // khởi tạo panel sớm

    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) return;

    SEL sel = @selector(initWithFrame:configuration:);
    Method m = class_getInstanceMethod(wk, sel);
    if (!m) return;

    gOriginalInit = method_setImplementation(m, (IMP)swizzled_init);
}