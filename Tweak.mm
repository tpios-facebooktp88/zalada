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
    UIView *p = gPanel.superview; if (!p) return;
    CGRect fr = gPanel.frame;
    CGFloat tx = (CGRectGetMidX(fr) < p.bounds.size.width/2.0) ? 10 : p.bounds.size.width - fr.size.width - 10;
    CGFloat ty = MAX(60, MIN(fr.origin.y, p.bounds.size.height - fr.size.height - 34));
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ gPanel.frame = CGRectMake(tx, ty, fr.size.width, fr.size.height); } completion:nil];
}

static void applyFilter(void) {
    NSString *kw = gSearch.text ?: @"";
    if (!kw.length) { gTV.text = gFullLog; return; }
    NSMutableString *out = [NSMutableString string];
    for (NSString *l in [gFullLog componentsSeparatedByString:@"\n"])
        if ([l.lowercaseString containsString:kw.lowercaseString]) [out appendFormat:@"%@\n", l];
    gTV.text = out.length ? out : @"Không tìm thấy";
}

static void updatePanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gFullLog = text;
        if (gVisible) applyFilter();
        gPanel.hidden = NO;
        [gPanel setNeedsLayout]; [gPanel layoutIfNeeded];
    });
}

@implementation LFPanel
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame]; if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.90];
    self.layer.cornerRadius = 14; self.clipsToBounds = YES;
    self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.5].CGColor;
    self.layer.borderWidth = 0.5;

    gSearch = [[UITextField alloc] init];
    gSearch.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    gSearch.textColor = UIColor.whiteColor; gSearch.font = [UIFont systemFontOfSize:11];
    gSearch.placeholder = @"🔍 Filter..."; gSearch.layer.cornerRadius = 6; gSearch.clipsToBounds = YES;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,0)];
    gSearch.leftView = pad; gSearch.leftViewMode = UITextFieldViewModeAlways;
    [gSearch addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];
    [self addSubview:gSearch];

    UIScrollView *sc = [[UIScrollView alloc] init]; sc.tag = 99; [self addSubview:sc];
    gTV = [[UILabel alloc] init]; gTV.numberOfLines = 0;
    gTV.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    gTV.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    gTV.text = @"[LazadaFarm] chờ WebView..."; [sc addSubview:gTV];

    gCopyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [gCopyBtn setTitle:@"📋 Copy Log" forState:UIControlStateNormal];
    [gCopyBtn setTitleColor:[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0] forState:UIControlStateNormal];
    gCopyBtn.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    gCopyBtn.layer.cornerRadius = 8; gCopyBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [gCopyBtn addTarget:self action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:gCopyBtn];

    gCopyFeed = [[UILabel alloc] init];
    gCopyFeed.textAlignment = NSTextAlignmentCenter;
    gCopyFeed.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    gCopyFeed.font = [UIFont systemFontOfSize:12]; gCopyFeed.hidden = YES; gCopyFeed.text = @"✓ Đã copy!";
    [self addSubview:gCopyFeed];

    for (UIGestureRecognizer *gr in @[
        ({ UIPanGestureRecognizer *g = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
           g.minimumNumberOfTouches = g.maximumNumberOfTouches = 1; g; }),
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)],
        ({ UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
           g.numberOfTapsRequired = 2; g; })
    ]) [self addGestureRecognizer:gr];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews]; if (!gVisible) return;
    CGRect b = self.bounds; CGFloat top = 46, bh = 36, gap = 4;
    gSearch.frame = CGRectMake(8, 8, b.size.width-16, 30);
    UIScrollView *sc = (UIScrollView *)[self viewWithTag:99];
    sc.frame = CGRectMake(0, top, b.size.width, b.size.height-top-bh-gap);
    CGSize fit = [gTV sizeThatFits:CGSizeMake(b.size.width-8, CGFLOAT_MAX)];
    gTV.frame = CGRectMake(4, 0, b.size.width-8, MAX(fit.height, sc.frame.size.height));
    sc.contentSize = CGSizeMake(b.size.width, gTV.frame.size.height);
    CGFloat btnW=110, btnY=b.size.height-bh+4;
    gCopyBtn.frame = gCopyFeed.frame = CGRectMake(b.size.width/2-btnW/2, btnY, btnW, bh-8);
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x+d.x, self.center.y+d.y);
    [g setTranslation:CGPointZero inView:self.superview];
    if (g.state==UIGestureRecognizerStateEnded||g.state==UIGestureRecognizerStateCancelled) snapToEdge();
}
- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (!gVisible||g.state!=UIGestureRecognizerStateChanged) return;
    gScale = MAX(0.4,MIN(2.5,gScale*g.scale));
    CGPoint c = self.center;
    self.frame = CGRectMake(c.x-gBaseSize.width*gScale/2, c.y-gBaseSize.height*gScale/2,
                            gBaseSize.width*gScale, gBaseSize.height*gScale);
    g.scale = 1.0;
}
- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    gVisible = !gVisible;
    CGFloat sw = self.superview ? self.superview.bounds.size.width : 390;
    if (!gVisible) {
        [UIView animateWithDuration:0.25 animations:^{
            self.frame = CGRectMake(sw-54, 80, 44, 44); self.layer.cornerRadius = 22;
            gSearch.alpha = ((UIScrollView *)[self viewWithTag:99]).alpha = gCopyBtn.alpha = gCopyFeed.alpha = 0;
        }];
    } else {
        gSearch.alpha = ((UIScrollView *)[self viewWithTag:99]).alpha = gCopyBtn.alpha = gCopyFeed.alpha = 1;
        applyFilter();
        [UIView animateWithDuration:0.3 animations:^{
            self.frame = CGRectMake(10,60,gBaseSize.width*gScale,gBaseSize.height*gScale);
            self.layer.cornerRadius = 14;
        } completion:^(BOOL f){ [self setNeedsLayout]; [self layoutIfNeeded]; }];
    }
}
- (void)doCopy {
    [UIPasteboard generalPasteboard].string = gTV.text ?: @"";
    gCopyBtn.hidden=YES; gCopyFeed.hidden=NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        gCopyBtn.hidden=NO; gCopyFeed.hidden=YES;
    });
}
- (void)searchChanged { applyFilter(); [self setNeedsLayout]; [self layoutIfNeeded]; }
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return (!gVisible||h==self) ? (gVisible?nil:h) : h;
}
@end

@implementation LFHandler
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    NSDictionary *body = msg.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    if ([@"status" isEqualToString:body[@"type"]]) { updatePanel(body[@"text"]?:@""); return; }
    NSString *url=body[@"url"]?:@""; NSArray *els=body[@"elements"]?:@[];
    NSMutableString *t=[NSMutableString stringWithFormat:@"URL:\n%@\n\n",url];
    if (els.count) { [t appendFormat:@"Elements (%lu):\n",(unsigned long)els.count]; for(NSString*e in els)[t appendFormat:@"• %@\n",e]; }
    else [t appendString:@"Chưa thấy element xu/checkin"];
    updatePanel(t);
}
@end

// ─── Farm JS ──────────────────────────────────────────────
static NSString *kScript = @""
"(function(){"
"function st(m){try{window.webkit.messageHandlers.lazadaFarm.postMessage({type:'status',text:'[Farm] '+m});}catch(e){}}"
"function wait(ms){return new Promise(r=>setTimeout(r,ms));}"
"function tap(el){"
"  if(!el)return false;"
"  var r=el.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;"
"  try{"
"    var t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y,screenX:x,screenY:y,pageX:x,pageY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});"
"    el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
"    el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));"
"  }catch(e){}"
"  el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:x,clientY:y}));"
"  return true;}"

"function getPending(){"
"  var all=document.querySelectorAll('.mission-item-center'),out=[];"
"  for(var i=0;i<all.length;i++)"
"    if((all[i].textContent||'').match(/0\\/\\d/))"
"      out.push({el:all[i],label:(all[i].textContent||'').substring(0,40)});"
"  return out;}"

"var farming=false;"
"async function farm(){"
"  if(farming)return; farming=true;"
"  st('Bắt đầu...'); await wait(2500);"

// điểm danh
"  var c=document.querySelector('[class*=\"lazcoins-checkin-card\"][class*=\"checkin-\"]');"
"  if(c){st('Điểm danh...');tap(c);await wait(2000);}else st('Đã điểm danh');"

// mở mission list
"  var mb=document.querySelector('.lazcoins-check-in-date');"
"  if(mb){tap(mb);await wait(2000);}"

"  var pending=getPending();"
"  st(''+pending.length+' task chưa làm');"

"  for(var j=0;j<pending.length;j++){"
"    var task=pending[j];"
"    st('Làm ('+( j+1)+'/'+pending.length+'): '+task.label);"
"    var btn=task.el.querySelector('.mission-item-btn-go');"
"    tap(btn||task.el);"
// luôn chờ 33s rồi back — bất kể navigate hay không
"    await wait(33000);"
"    history.back();"
"    await wait(3000);"
// re-query để lấy list mới sau khi back
"    var newP=getPending();"
"    if(newP.length>0){pending=newP;j=-1;}"
"  }"

"  st('✓ Xong hôm nay!');"
"  farming=false;}"

"var lastURL='';"
"setInterval(function(){"
"  var u=location.href;"
"  if(u!==lastURL){"
"    lastURL=u;"
"    try{window.webkit.messageHandlers.lazadaFarm.postMessage({type:'log',url:u,elements:[]});}catch(e){}"
"    if(u.indexOf('laz-coins')>-1&&!farming)setTimeout(farm,1000);"
"  }"
"},800);"
"})();";

static IMP gOrigInit=NULL;
static id swizzled_init(id self,SEL _cmd,CGRect frame,WKWebViewConfiguration *cfg){
    WKUserScript *s=[[WKUserScript alloc]initWithSource:kScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO];
    [cfg.userContentController addUserScript:s];
    [cfg.userContentController addScriptMessageHandler:[[LFHandler alloc]init] name:@"lazadaFarm"];
    return((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOrigInit)(self,_cmd,frame,cfg);
}

static void setupPanel(void){
    dispatch_async(dispatch_get_main_queue(),^{
        UIWindow *kw=nil;
        for(UIWindow *w in UIApplication.sharedApplication.windows) if(w.isKeyWindow){kw=w;break;}
        if(!kw)kw=UIApplication.sharedApplication.windows.firstObject;
        if(!kw)return;
        gBaseSize=CGSizeMake(kw.bounds.size.width-20,220);
        gPanel=[[LFPanel alloc]initWithFrame:CGRectMake(10,60,gBaseSize.width,gBaseSize.height)];
        [kw addSubview:gPanel];[kw bringSubviewToFront:gPanel];
    });
}

__attribute__((constructor))
static void Init(void){
    Class wk=NSClassFromString(@"WKWebView"); if(!wk)return;
    Method m=class_getInstanceMethod(wk,@selector(initWithFrame:configuration:)); if(!m)return;
    gOrigInit=method_setImplementation(m,(IMP)swizzled_init);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupPanel();});
}