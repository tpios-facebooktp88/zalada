#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

@interface LFPanel : UIView
@end
@interface LFHandler : NSObject <WKScriptMessageHandler>
@end

static LFPanel     *gPanel    = nil;
static UILabel     *gTV       = nil;
static UITextField *gSearch   = nil;
static UIButton    *gCopyBtn  = nil;
static UILabel     *gCopyFeed = nil;
static NSString    *gFullLog  = @"";
static BOOL         gVisible  = YES;
static CGFloat      gScale    = 1.0;
static CGSize       gBaseSize;

static void snapToEdge(void) {
    UIView *parent = gPanel.superview;
    if (!parent) return;
    CGFloat sw = parent.bounds.size.width;
    CGFloat sh = parent.bounds.size.height;
    CGRect  fr = gPanel.frame;
    CGFloat cx = CGRectGetMidX(fr);
    CGFloat tx = (cx < sw / 2.0) ? 10 : sw - fr.size.width - 10;
    CGFloat ty = fr.origin.y;
    if (ty < 60)                       ty = 60;
    if (ty + fr.size.height > sh - 34) ty = sh - fr.size.height - 34;
    [UIView animateWithDuration:0.3 delay:0
         usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ gPanel.frame = CGRectMake(tx, ty, fr.size.width, fr.size.height); }
                     completion:nil];
}

static void applyFilter(void) {
    NSString *kw = gSearch.text ?: @"";
    if (kw.length == 0) { gTV.text = gFullLog; return; }
    NSMutableString *out = [NSMutableString string];
    for (NSString *line in [gFullLog componentsSeparatedByString:@"\n"]) {
        if ([line.lowercaseString containsString:kw.lowercaseString])
            [out appendFormat:@"%@\n", line];
    }
    gTV.text = out.length > 0 ? out : @"Không tìm thấy";
}

static void updatePanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gFullLog = text;
        if (gVisible) applyFilter();
        gPanel.hidden = NO;
        [gPanel setNeedsLayout];
        [gPanel layoutIfNeeded];
    });
}

@implementation LFPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor    = [UIColor colorWithWhite:0.05 alpha:0.90];
    self.layer.cornerRadius = 14;
    self.clipsToBounds      = YES;
    self.layer.borderColor  = [UIColor colorWithWhite:0.3 alpha:0.5].CGColor;
    self.layer.borderWidth  = 0.5;

    gSearch = [[UITextField alloc] init];
    gSearch.backgroundColor    = [UIColor colorWithWhite:0.18 alpha:1];
    gSearch.textColor          = UIColor.whiteColor;
    gSearch.font               = [UIFont systemFontOfSize:11];
    gSearch.placeholder        = @"🔍 Filter...";
    gSearch.layer.cornerRadius = 6;
    gSearch.clipsToBounds      = YES;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,0)];
    gSearch.leftView = pad; gSearch.leftViewMode = UITextFieldViewModeAlways;
    [gSearch addTarget:self action:@selector(searchChanged)
      forControlEvents:UIControlEventEditingChanged];
    [self addSubview:gSearch];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.tag = 99;
    [self addSubview:scroll];

    gTV = [[UILabel alloc] init];
    gTV.numberOfLines = 0;
    gTV.textColor     = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    gTV.font          = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    gTV.text          = @"[LazadaFarm] chờ WebView...";
    [scroll addSubview:gTV];

    gCopyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [gCopyBtn setTitle:@"📋 Copy Log" forState:UIControlStateNormal];
    [gCopyBtn setTitleColor:[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0]
                   forState:UIControlStateNormal];
    gCopyBtn.backgroundColor    = [UIColor colorWithWhite:0.15 alpha:1];
    gCopyBtn.layer.cornerRadius = 8;
    gCopyBtn.titleLabel.font    = [UIFont systemFontOfSize:12];
    [gCopyBtn addTarget:self action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:gCopyBtn];

    gCopyFeed = [[UILabel alloc] init];
    gCopyFeed.textAlignment = NSTextAlignmentCenter;
    gCopyFeed.textColor     = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    gCopyFeed.font          = [UIFont systemFontOfSize:12];
    gCopyFeed.hidden        = YES;
    gCopyFeed.text          = @"✓ Đã copy!";
    [self addSubview:gCopyFeed];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    pan.minimumNumberOfTouches = pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:pinch];

    UITapGestureRecognizer *dtap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    dtap.numberOfTapsRequired = 2;
    [self addGestureRecognizer:dtap];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!gVisible) return;
    CGRect b    = self.bounds;
    CGFloat sh  = 30, bh = 36, gap = 4;
    CGFloat top = sh + gap + 8;
    CGFloat tvH = b.size.height - top - bh - gap;
    gSearch.frame = CGRectMake(8, 8, b.size.width - 16, sh);
    UIScrollView *scroll = (UIScrollView *)[self viewWithTag:99];
    scroll.frame = CGRectMake(0, top, b.size.width, tvH);
    CGSize fit = [gTV sizeThatFits:CGSizeMake(b.size.width - 8, CGFLOAT_MAX)];
    gTV.frame  = CGRectMake(4, 0, b.size.width - 8, MAX(fit.height, tvH));
    scroll.contentSize = CGSizeMake(b.size.width, MAX(fit.height, tvH));
    CGFloat btnW = 110, btnY = b.size.height - bh + 4;
    gCopyBtn.frame  = CGRectMake(b.size.width/2 - btnW/2, btnY, btnW, bh - 8);
    gCopyFeed.frame = gCopyBtn.frame;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + d.x, self.center.y + d.y);
    [g setTranslation:CGPointZero inView:self.superview];
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) snapToEdge();
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (!gVisible || g.state != UIGestureRecognizerStateChanged) return;
    gScale = MAX(0.4, MIN(2.5, gScale * g.scale));
    CGFloat nw = gBaseSize.width * gScale, nh = gBaseSize.height * gScale;
    CGPoint c = self.center;
    self.frame = CGRectMake(c.x - nw/2, c.y - nh/2, nw, nh);
    g.scale = 1.0;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    gVisible = !gVisible;
    UIView *parent = self.superview;
    CGFloat sw = parent ? parent.bounds.size.width : 390;
    if (!gVisible) {
        [UIView animateWithDuration:0.25 animations:^{
            self.frame = CGRectMake(sw - 54, 80, 44, 44);
            self.layer.cornerRadius = 22;
            gSearch.alpha = 0;
            gCopyBtn.alpha = 0; gCopyFeed.alpha = 0;
            ((UIScrollView *)[self viewWithTag:99]).alpha = 0;
        }];
    } else {
        gSearch.alpha = gCopyBtn.alpha = gCopyFeed.alpha = 1;
        ((UIScrollView *)[self viewWithTag:99]).alpha = 1;
        applyFilter();
        [UIView animateWithDuration:0.3 animations:^{
            self.frame = CGRectMake(10, 60, gBaseSize.width * gScale, gBaseSize.height * gScale);
            self.layer.cornerRadius = 14;
        } completion:^(BOOL f) { [self setNeedsLayout]; [self layoutIfNeeded]; }];
    }
}

- (void)doCopy {
    [UIPasteboard generalPasteboard].string = gTV.text ?: @"";
    gCopyBtn.hidden = YES; gCopyFeed.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ gCopyBtn.hidden = NO; gCopyFeed.hidden = YES; });
}

- (void)searchChanged { applyFilter(); [self setNeedsLayout]; [self layoutIfNeeded]; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!gVisible) return hit;
    return (hit == self) ? nil : hit;
}

@end

// ─── Message handler ──────────────────────────────────────
@implementation LFHandler
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *type = body[@"type"] ?: @"log";

    if ([type isEqualToString:@"status"]) {
        updatePanel(body[@"text"] ?: @"");
        return;
    }

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

// ─── JS Phase 2: auto-farm ────────────────────────────────
static NSString *kScript = @""
"(function(){"

// ── Status display ──
"function status(msg){"
"  try{window.webkit.messageHandlers.lazadaFarm"
"    .postMessage({type:'status',text:'[Farm] '+msg});}catch(e){}}"

// ── Delay helper ──
"function wait(ms){return new Promise(r=>setTimeout(r,ms));}"

// ── Click helper ──
"function tap(el){"
"  if(!el)return false;"
"  el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}));"
"  return true;}"

// ── Farm một task: click rồi chờ 32s rồi back ──
"async function runTask(el,label){"
"  status('Đang làm: '+label);"
"  var btn=el.querySelector('.mission-item-btn-go');"
"  tap(btn||el);"
"  await wait(32000);"
"  history.back();"
"  await wait(3000);"
"  status('Xong: '+label);}"

// ── Main farm loop ──
"var farming=false;"
"async function farm(){"
"  if(farming)return;"
"  farming=true;"
"  status('Bắt đầu farm...');"

// 1. Điểm danh
"  var checkin=document.querySelector('[class*=\"lazcoins-checkin-card\"][class*=\"checkin-\"]');"
"  if(checkin){"
"    status('Điểm danh...');"
"    tap(checkin);"
"    await wait(2000);"
"  }else{"
"    status('Đã điểm danh rồi');}"

// 2. Làm từng task chưa hoàn thành
"  var tasks=document.querySelectorAll('.mission-item-center');"
"  var pending=[];"
"  for(var i=0;i<tasks.length;i++){"
"    var t=tasks[i].textContent||'';"
"    if(t.match(/0\\/\\d/))pending.push({el:tasks[i],label:t.substring(0,40)});}"

"  status('Tìm thấy '+pending.length+' task chưa làm');"
"  for(var j=0;j<pending.length;j++){"
"    await runTask(pending[j].el,pending[j].label);"
"    tasks=document.querySelectorAll('.mission-item-center');"// re-query sau back
"  }"

"  status('✓ Farm xong hôm nay!');"
"  farming=false;}"

// ── Trigger khi URL chứa laz-coins ──
"var lastURL='';"
"setInterval(function(){"
"  var url=location.href;"
"  if(url!==lastURL){"
"    lastURL=url;"
"    try{window.webkit.messageHandlers.lazadaFarm"
"      .postMessage({type:'log',url:url,elements:[]});}catch(e){}"
"    if(url.indexOf('laz-coins')>-1&&!farming){"
"      setTimeout(farm,2500);}}" // chờ 2.5s cho page load xong
"},800);"

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
    [cfg.userContentController addScriptMessageHandler:[[LFHandler alloc] init]
                                                  name:@"lazadaFarm"];
    return ((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOrigInit)
        (self, _cmd, frame, cfg);
}

// ─── Setup panel ──────────────────────────────────────────
static void setupPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows)
            if (w.isKeyWindow) { kw = w; break; }
        if (!kw) kw = UIApplication.sharedApplication.windows.firstObject;
        if (!kw) return;
        CGFloat sw = kw.bounds.size.width;
        gBaseSize  = CGSizeMake(sw - 20, 220);
        gPanel = [[LFPanel alloc] initWithFrame:
            CGRectMake(10, 60, gBaseSize.width, gBaseSize.height)];
        [kw addSubview:gPanel];
        [kw bringSubviewToFront:gPanel];
    });
}

// ─── Constructor ──────────────────────────────────────────
__attribute__((constructor))
static void Init(void) {
    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) return;
    Method m = class_getInstanceMethod(wk, @selector(initWithFrame:configuration:));
    if (!m) return;
    gOrigInit = method_setImplementation(m, (IMP)swizzled_init);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ setupPanel(); });
}