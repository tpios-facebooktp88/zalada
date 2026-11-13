#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// ─── IOHIDEvent private API ───────────────────────────────
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint64_t, double, double, double, double, double, uint32_t, bool, bool, uint32_t);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, uint32_t, bool, bool, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t, int32_t);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t, double);

// kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0x000D0019
// kIOHIDEventFieldDigitizerType = 0x000D0001
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0x000D0019
#define kIOHIDDigitizerEventTouch   (1 << 0)
#define kIOHIDDigitizerEventRange   (1 << 1)
#define kIOHIDTransducerTypeHand    4
#define kIOHIDTransducerIndexFinger 1

// ─── IOHIDEvent tap ───────────────────────────────────────
static IOHIDEventSystemClientRef gHIDClient = NULL;

static void hidTap(CGPoint point) {
    if (!gHIDClient) {
        gHIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    if (!gHIDClient) return;

    uint64_t ts = (uint64_t)(CACurrentMediaTime() * 1e9);
    double x = point.x, y = point.y;

    // touchstart
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        kIOHIDTransducerTypeHand, 0, 1,
        0, x, y, 0, 1.0, 0,
        kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange,
        true, true, 0);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        kIOHIDTransducerIndexFinger, 2, 1,
        x, y, 0, 1.0, 0,
        kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange,
        true, true, 0);

    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventAppendEvent(parent, finger, 0);
    IOHIDEventSystemClientDispatchEvent(gHIDClient, parent);
    CFRelease(finger);
    CFRelease(parent);

    // touchend sau 80ms
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        uint64_t ts2 = (uint64_t)(CACurrentMediaTime() * 1e9);

        IOHIDEventRef parent2 = IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, ts2,
            kIOHIDTransducerTypeHand, 0, 1,
            0, x, y, 0, 0, 0,
            kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange,
            false, false, 0);

        IOHIDEventRef finger2 = IOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault, ts2,
            kIOHIDTransducerIndexFinger, 2, 1,
            x, y, 0, 0, 0,
            kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange,
            false, false, 0);

        IOHIDEventSetIntegerValue(parent2, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventSetIntegerValue(finger2, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventAppendEvent(parent2, finger2, 0);
        IOHIDEventSystemClientDispatchEvent(gHIDClient, parent2);
        CFRelease(finger2);
        CFRelease(parent2);
    });
}

// ─── Tap element trong WKWebView bằng IOHIDEvent ──────────
// Lấy CGPoint từ JS getBoundingClientRect rồi convert sang screen coords
static void tapElementInWebView(WKWebView *wv, NSString *jsSelector, void(^completion)(BOOL)) {
    NSString *js = [NSString stringWithFormat:
        @"(function(){"
         "var el=document.querySelector('%@');"
         "if(!el)return null;"
         "var r=el.getBoundingClientRect();"
         "return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});"
         "})()", jsSelector];

    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
        if (!result || [result isKindOfClass:[NSNull class]]) {
            if (completion) completion(NO);
            return;
        }
        NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *pt = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!pt) { if (completion) completion(NO); return; }

        // Convert WebView-relative coords → screen coords
        CGFloat wx = [pt[@"x"] doubleValue];
        CGFloat wy = [pt[@"y"] doubleValue];

        // WKWebView frame trên screen
        CGPoint webOrigin = [wv convertPoint:CGPointZero toView:nil];
        // Thêm status bar offset nếu cần
        CGFloat scale = UIScreen.mainScreen.scale;
        CGPoint screenPt = CGPointMake((webOrigin.x + wx), (webOrigin.y + wy));

        // HIDEvent dùng screen coords nhân scale
        CGPoint hidPt = CGPointMake(screenPt.x * scale, screenPt.y * scale);
        hidTap(hidPt);
        if (completion) completion(YES);
    }];
}

// ─── Panel ────────────────────────────────────────────────
@interface LFPanel : UIView
@end
@interface LFHandler : NSObject <WKScriptMessageHandler>
@end

static LFPanel      *gPanel    = nil;
static UILabel      *gTV       = nil;
static UITextField  *gSearch   = nil;
static UIButton     *gCopyBtn  = nil;
static UIButton     *gStartBtn = nil;
static UILabel      *gCopyFeed = nil;
static NSString     *gFullLog  = @"";
static BOOL          gVisible  = YES;
static CGFloat       gScale    = 1.0;
static CGSize        gBaseSize;
static WKWebView    *gActiveWebView = nil; // track webview đang farm
static BOOL          gFarmEnabled  = NO;

static void snapToEdge(void) {
    UIView *p=gPanel.superview;if(!p)return;
    CGRect fr=gPanel.frame;
    CGFloat tx=(CGRectGetMidX(fr)<p.bounds.size.width/2.0)?10:p.bounds.size.width-fr.size.width-10;
    CGFloat ty=MAX(60,MIN(fr.origin.y,p.bounds.size.height-fr.size.height-34));
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{gPanel.frame=CGRectMake(tx,ty,fr.size.width,fr.size.height);}completion:nil];
}

static void applyFilter(void){
    NSString *kw=gSearch.text?:@"";
    if(!kw.length){gTV.text=gFullLog;return;}
    NSMutableString *out=[NSMutableString string];
    for(NSString *l in [gFullLog componentsSeparatedByString:@"\n"])
        if([l.lowercaseString containsString:kw.lowercaseString])[out appendFormat:@"%@\n",l];
    gTV.text=out.length?out:@"Không tìm thấy";
}

static void updatePanel(NSString *text){
    dispatch_async(dispatch_get_main_queue(),^{
        gFullLog=text;if(gVisible)applyFilter();
        gPanel.hidden=NO;[gPanel setNeedsLayout];[gPanel layoutIfNeeded];
    });
}

static void updateStartBtn(BOOL running){
    dispatch_async(dispatch_get_main_queue(),^{
        NSString *title=running?@"⏹ Dừng":@"▶ Bắt đầu";
        UIColor *color=running?[UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0]
                              :[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
        [gStartBtn setTitle:title forState:UIControlStateNormal];
        [gStartBtn setTitleColor:color forState:UIControlStateNormal];
    });
}

@implementation LFPanel
-(instancetype)initWithFrame:(CGRect)frame{
    self=[super initWithFrame:frame];if(!self)return nil;
    self.backgroundColor=[UIColor colorWithWhite:0.05 alpha:0.90];
    self.layer.cornerRadius=14;self.clipsToBounds=YES;
    self.layer.borderColor=[UIColor colorWithWhite:0.3 alpha:0.5].CGColor;self.layer.borderWidth=0.5;

    gSearch=[[UITextField alloc]init];
    gSearch.backgroundColor=[UIColor colorWithWhite:0.18 alpha:1];
    gSearch.textColor=UIColor.whiteColor;gSearch.font=[UIFont systemFontOfSize:11];
    gSearch.placeholder=@"🔍 Filter...";gSearch.layer.cornerRadius=6;gSearch.clipsToBounds=YES;
    UIView *pad=[[UIView alloc]initWithFrame:CGRectMake(0,0,8,0)];
    gSearch.leftView=pad;gSearch.leftViewMode=UITextFieldViewModeAlways;
    [gSearch addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];
    [self addSubview:gSearch];

    UIScrollView *sc=[[UIScrollView alloc]init];sc.tag=99;[self addSubview:sc];
    gTV=[[UILabel alloc]init];gTV.numberOfLines=0;
    gTV.textColor=[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    gTV.font=[UIFont fontWithName:@"Menlo" size:10]?:[UIFont systemFontOfSize:10];
    gTV.text=@"[LazadaFarm] chờ WebView...";[sc addSubview:gTV];

    gStartBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    [gStartBtn setTitle:@"▶ Bắt đầu" forState:UIControlStateNormal];
    [gStartBtn setTitleColor:[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0] forState:UIControlStateNormal];
    gStartBtn.backgroundColor=[UIColor colorWithWhite:0.15 alpha:1];
    gStartBtn.layer.cornerRadius=8;gStartBtn.titleLabel.font=[UIFont boldSystemFontOfSize:12];
    [gStartBtn addTarget:self action:@selector(doStart) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:gStartBtn];

    gCopyBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    [gCopyBtn setTitle:@"📋 Copy" forState:UIControlStateNormal];
    [gCopyBtn setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    gCopyBtn.backgroundColor=[UIColor colorWithWhite:0.12 alpha:1];
    gCopyBtn.layer.cornerRadius=8;gCopyBtn.titleLabel.font=[UIFont systemFontOfSize:11];
    [gCopyBtn addTarget:self action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:gCopyBtn];

    gCopyFeed=[[UILabel alloc]init];
    gCopyFeed.textAlignment=NSTextAlignmentCenter;
    gCopyFeed.textColor=[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
    gCopyFeed.font=[UIFont systemFontOfSize:11];gCopyFeed.hidden=YES;gCopyFeed.text=@"✓ Copied!";
    [self addSubview:gCopyFeed];

    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(handlePan:)];
    pan.minimumNumberOfTouches=pan.maximumNumberOfTouches=1;[self addGestureRecognizer:pan];
    [[UIPinchGestureRecognizer alloc]initWithTarget:self action:@selector(handlePinch:)];
    UIPinchGestureRecognizer *pinch=[[UIPinchGestureRecognizer alloc]initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:pinch];
    UITapGestureRecognizer *dtap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(handleDoubleTap:)];
    dtap.numberOfTapsRequired=2;[self addGestureRecognizer:dtap];
    return self;
}

-(void)layoutSubviews{
    [super layoutSubviews];if(!gVisible)return;
    CGRect b=self.bounds;CGFloat top=46,bh=36,gap=4;
    gSearch.frame=CGRectMake(8,8,b.size.width-16,30);
    UIScrollView *sc=(UIScrollView*)[self viewWithTag:99];
    sc.frame=CGRectMake(0,top,b.size.width,b.size.height-top-bh-gap);
    CGSize fit=[gTV sizeThatFits:CGSizeMake(b.size.width-8,CGFLOAT_MAX)];
    gTV.frame=CGRectMake(4,0,b.size.width-8,MAX(fit.height,sc.frame.size.height));
    sc.contentSize=CGSizeMake(b.size.width,gTV.frame.size.height);
    CGFloat btnY=b.size.height-bh+4,bh2=bh-8;
    CGFloat startW=b.size.width*0.58,copyW=b.size.width*0.33;
    gStartBtn.frame=CGRectMake(6,btnY,startW,bh2);
    gCopyBtn.frame=CGRectMake(startW+10,btnY,copyW,bh2);
    gCopyFeed.frame=gCopyBtn.frame;
}

-(void)handlePan:(UIPanGestureRecognizer*)g{
    CGPoint d=[g translationInView:self.superview];
    self.center=CGPointMake(self.center.x+d.x,self.center.y+d.y);
    [g setTranslation:CGPointZero inView:self.superview];
    if(g.state==UIGestureRecognizerStateEnded||g.state==UIGestureRecognizerStateCancelled)snapToEdge();
}
-(void)handlePinch:(UIPinchGestureRecognizer*)g{
    if(!gVisible||g.state!=UIGestureRecognizerStateChanged)return;
    gScale=MAX(0.4,MIN(2.5,gScale*g.scale));
    CGPoint c=self.center;
    self.frame=CGRectMake(c.x-gBaseSize.width*gScale/2,c.y-gBaseSize.height*gScale/2,
                          gBaseSize.width*gScale,gBaseSize.height*gScale);
    g.scale=1.0;
}
-(void)handleDoubleTap:(UITapGestureRecognizer*)g{
    gVisible=!gVisible;
    CGFloat sw=self.superview?self.superview.bounds.size.width:390;
    if(!gVisible){
        [UIView animateWithDuration:0.25 animations:^{
            self.frame=CGRectMake(sw-54,80,44,44);self.layer.cornerRadius=22;
            gSearch.alpha=((UIScrollView*)[self viewWithTag:99]).alpha=gStartBtn.alpha=gCopyBtn.alpha=gCopyFeed.alpha=0;
        }];
    }else{
        gSearch.alpha=((UIScrollView*)[self viewWithTag:99]).alpha=gStartBtn.alpha=gCopyBtn.alpha=gCopyFeed.alpha=1;
        applyFilter();
        [UIView animateWithDuration:0.3 animations:^{
            self.frame=CGRectMake(10,60,gBaseSize.width*gScale,gBaseSize.height*gScale);
            self.layer.cornerRadius=14;
        }completion:^(BOOL f){[self setNeedsLayout];[self layoutIfNeeded];}];
    }
}
-(void)doStart{
    gFarmEnabled=!gFarmEnabled;
    updateStartBtn(gFarmEnabled);
    if(gFarmEnabled&&gActiveWebView){
        updatePanel(@"[Farm] Bắt đầu farm...");
        [self startFarmOnWebView:gActiveWebView];
    }else{
        updatePanel(@"[Farm] Đã dừng");
    }
}
-(void)doCopy{
    [UIPasteboard generalPasteboard].string=gTV.text?:@"";
    gCopyBtn.hidden=YES;gCopyFeed.hidden=NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        gCopyBtn.hidden=NO;gCopyFeed.hidden=YES;
    });
}
-(void)searchChanged{applyFilter();[self setNeedsLayout];[self layoutIfNeeded];}
-(UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e{
    UIView *h=[super hitTest:p withEvent:e];
    if(!gVisible)return h;
    return(h==self)?nil:h;
}

// ─── Farm logic dùng IOHIDEvent tap ───────────────────────
-(void)startFarmOnWebView:(WKWebView*)wv{
    if(!gFarmEnabled)return;
    updatePanel(@"[Farm] Scan tasks...");

    // Lấy tất cả pending tasks
    NSString *js=@"(function(){"
        "var all=document.querySelectorAll('.mission-item-center'),out=[];"
        "for(var i=0;i<all.length;i++){"
        "  var el=all[i],txt=el.textContent||'';"
        "  if(!txt.match(/0\\/\\d/))continue;"
        "  var btn=el.querySelector('.mission-item-btn-go');"
        "  if(btn&&(btn.textContent||'').trim()==='Tìm kiếm')continue;"
        "  var r=(btn||el).getBoundingClientRect();"
        "  out.push({x:r.left+r.width/2,y:r.top+r.height/2,label:txt.substring(0,40)});"
        "}"
        // Điểm danh
        "var c=document.querySelector('[class*=\"lazcoins-checkin-card\"][class*=\"checkin-\"]');"
        "if(c){var cr=c.getBoundingClientRect();out.unshift({x:cr.left+cr.width/2,y:cr.top+cr.height/2,label:'CHECKIN',isCheckin:true});}"
        "return JSON.stringify(out);"
        "})()";

    [wv evaluateJavaScript:js completionHandler:^(id result, NSError *err){
        if(!result||[result isKindOfClass:[NSNull class]]){
            updatePanel(@"[Farm] Không tìm thấy task");return;
        }
        NSData *data=[result dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *tasks=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(!tasks.count){updatePanel(@"[Farm] ✓ Hết task hôm nay!");return;}

        updatePanel([NSString stringWithFormat:@"[Farm] %lu tasks",(unsigned long)tasks.count]);
        [self runTasks:tasks index:0 webView:wv];
    }];
}

-(void)runTasks:(NSArray*)tasks index:(NSInteger)idx webView:(WKWebView*)wv{
    if(!gFarmEnabled){updatePanel(@"[Farm] Đã dừng");return;}
    if(idx>=(NSInteger)tasks.count){
        // Lưu progress ngày hôm nay
        NSString *today=[NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];
        [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lfDoneDate"];
        updatePanel(@"[Farm] ✓ Xong hôm nay!");
        updateStartBtn(NO);gFarmEnabled=NO;
        return;
    }

    NSDictionary *task=tasks[idx];
    NSString *label=task[@"label"]?:@"?";
    CGFloat wx=[task[@"x"] doubleValue];
    CGFloat wy=[task[@"y"] doubleValue];
    BOOL isCheckin=[task[@"isCheckin"] boolValue];

    updatePanel([NSString stringWithFormat:@"[Farm] (%ld/%lu) %@",
        (long)(idx+1),(unsigned long)tasks.count,label]);

    // Convert WKWebView coords → screen coords → HID coords
    CGPoint webOrigin=[wv convertPoint:CGPointZero toView:nil];
    CGFloat s=UIScreen.mainScreen.scale;
    CGPoint hidPt=CGPointMake((webOrigin.x+wx)*s,(webOrigin.y+wy)*s);

    hidTap(hidPt);

    NSTimeInterval delay = isCheckin ? 2.0 : 33.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{
        if(!gFarmEnabled)return;
        // back nếu không phải checkin
        if(!isCheckin){
            [wv evaluateJavaScript:@"history.back();" completionHandler:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3*NSEC_PER_SEC)),
                           dispatch_get_main_queue(),^{
                [self runTasks:tasks index:idx+1 webView:wv];
            });
        }else{
            [self runTasks:tasks index:idx+1 webView:wv];
        }
    });
}

@end

// ─── Message handler ──────────────────────────────────────
@implementation LFHandler
-(void)userContentController:(WKUserContentController*)ucc didReceiveScriptMessage:(WKScriptMessage*)msg{
    NSDictionary *body=msg.body;
    if(![body isKindOfClass:[NSDictionary class]])return;
    NSString *type=body[@"type"]?:@"log";
    if([@"status" isEqualToString:type]){updatePanel(body[@"text"]?:@"");return;}
    NSString *url=body[@"url"]?:@"";NSArray *els=body[@"elements"]?:@[];
    NSMutableString *t=[NSMutableString stringWithFormat:@"URL:\n%@\n\n",url];
    if(els.count){[t appendFormat:@"Elements (%lu):\n",(unsigned long)els.count];
        for(NSString*e in els)[t appendFormat:@"• %@\n",e];}
    else[t appendString:@"Chưa thấy element xu/checkin"];
    updatePanel(t);

    // Track webview đang ở trang laz-coins
    if([url containsString:@"laz-coins"]){
        dispatch_async(dispatch_get_main_queue(),^{
            gActiveWebView=(WKWebView*)msg.webView;
            // Auto-start nếu enabled
            if(gFarmEnabled&&gActiveWebView){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),
                               dispatch_get_main_queue(),^{
                    [(LFPanel*)gPanel startFarmOnWebView:gActiveWebView];
                });
            }
        });
    }
}
@end

// ─── JS: logger only (tap dùng IOHIDEvent từ ObjC) ────────
static NSString *kScript=@""
"(function(){"
"if(window._lfInit)return;window._lfInit=true;"
"var last='';"
"setInterval(function(){"
"  var u=location.href;"
"  if(u===last)return;last=u;"
"  var found=[];"
"  var els=document.querySelectorAll('.mission-item-center,.lazcoins-checkin-card');"
"  for(var i=0;i<els.length;i++){"
"    var t=(els[i].textContent||'').trim();"
"    if(t.length>0&&t.length<80)found.push(t.substring(0,60));}"
"  try{window.webkit.messageHandlers.lazadaFarm.postMessage({type:'log',url:u,elements:found});}catch(e){}"
"},800);"
"})();";

static IMP gOrigInit=NULL;
static id swizzled_init(id self,SEL _cmd,CGRect frame,WKWebViewConfiguration *cfg){
    WKUserScript *s=[[WKUserScript alloc]initWithSource:kScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [cfg.userContentController addUserScript:s];
    @try{[cfg.userContentController addScriptMessageHandler:[[LFHandler alloc]init]
                                                       name:@"lazadaFarm"];}@catch(NSException *e){}
    return((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOrigInit)(self,_cmd,frame,cfg);
}

static void setupPanel(void){
    dispatch_async(dispatch_get_main_queue(),^{
        UIWindow *kw=nil;
        for(UIWindow *w in UIApplication.sharedApplication.windows)if(w.isKeyWindow){kw=w;break;}
        if(!kw)kw=UIApplication.sharedApplication.windows.firstObject;
        if(!kw)return;
        gBaseSize=CGSizeMake(kw.bounds.size.width-20,220);
        gPanel=[[LFPanel alloc]initWithFrame:CGRectMake(10,60,gBaseSize.width,gBaseSize.height)];
        [kw addSubview:gPanel];[kw bringSubviewToFront:gPanel];
    });
}

__attribute__((constructor))
static void Init(void){
    Class wk=NSClassFromString(@"WKWebView");if(!wk)return;
    Method m=class_getInstanceMethod(wk,@selector(initWithFrame:configuration:));if(!m)return;
    gOrigInit=method_setImplementation(m,(IMP)swizzled_init);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{setupPanel();});
}