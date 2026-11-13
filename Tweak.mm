#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

// ─── BackBoardServices + IOHIDEvent ──────────────────────
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint64_t,double,double,double,double,double,uint32_t,bool,bool,uint32_t);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,uint32_t,bool,bool,uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef,IOHIDEventRef,uint32_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef,uint32_t,int32_t);

#define kHIDDisplayIntegrated 0x000D0019
#define kHIDTouch  (1<<0)
#define kHIDRange  (1<<1)
#define kHIDHand   4
#define kHIDFinger 1

static IOHIDEventSystemClientRef sHIDClient = NULL;

static void hidTapAt(CGPoint screenPt, BOOL down) {
    if (!sHIDClient) return;
    uint64_t ts = mach_absolute_time();
    double x = screenPt.x, y = screenPt.y;
    uint32_t phase = down ? (kHIDTouch|kHIDRange) : (kHIDTouch|kHIDRange);
    bool touching = down;

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,ts,kHIDHand,0,1,0,x,y,0,touching?1.0:0,0,
        phase,touching,touching,0);
    if (!parent) return;

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,ts,kHIDFinger,2,1,x,y,0,touching?1.0:0,0,
        phase,touching,touching,0);
    if (!finger) { CFRelease(parent); return; }

    IOHIDEventSetIntegerValue(parent,kHIDDisplayIntegrated,1);
    IOHIDEventSetIntegerValue(finger,kHIDDisplayIntegrated,1);
    IOHIDEventAppendEvent(parent,finger,0);
    IOHIDEventSystemClientDispatchEvent(sHIDClient,parent);
    CFRelease(finger);
    CFRelease(parent);
}

// Tap tại screen point (HID coords = logical * scale)
static void hidTap(CGPoint logicalPt) {
    NSAssert([NSThread isMainThread], @"hidTap must run on main thread");
    CGFloat s = UIScreen.mainScreen.scale;
    CGPoint hp = CGPointMake(logicalPt.x * s, logicalPt.y * s);
    hidTapAt(hp, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80*NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ hidTapAt(hp, NO); });
}

// ─── Panel & globals ──────────────────────────────────────
@interface LFPanel : UIView
-(void)startFarmOnWebView:(WKWebView*)wv;
@end
@interface LFHandler : NSObject <WKScriptMessageHandler>
@end

static LFPanel     *gPanel      = nil;
static UILabel     *gTV         = nil;
static UITextField *gSearch     = nil;
static UIButton    *gCopyBtn    = nil;
static UIButton    *gStartBtn   = nil;
static UILabel     *gCopyFeed   = nil;
static NSString    *gFullLog    = @"";
static BOOL         gVisible    = YES;
static CGFloat      gScale      = 1.0;
static CGSize       gBaseSize;
static WKWebView   *gActiveWV   = nil;
static BOOL         gEnabled    = NO;
static BOOL         gFarming    = NO;

static void snap(void){
    UIView *p=gPanel.superview;if(!p)return;
    CGRect fr=gPanel.frame;
    CGFloat tx=(CGRectGetMidX(fr)<p.bounds.size.width/2)?10:p.bounds.size.width-fr.size.width-10;
    CGFloat ty=MAX(60,MIN(fr.origin.y,p.bounds.size.height-fr.size.height-34));
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:0 animations:^{gPanel.frame=CGRectMake(tx,ty,fr.size.width,fr.size.height);}completion:nil];
}
static void log_(NSString *s){
    dispatch_async(dispatch_get_main_queue(),^{
        gFullLog=s;
        NSString *kw=gSearch.text?:@"";
        if(!kw.length){gTV.text=s;return;}
        NSMutableString *out=[NSMutableString string];
        for(NSString *l in [s componentsSeparatedByString:@"\n"])
            if([l.lowercaseString containsString:kw.lowercaseString])[out appendFormat:@"%@\n",l];
        gTV.text=out.length?out:@"Không tìm thấy";
        gPanel.hidden=NO;[gPanel setNeedsLayout];[gPanel layoutIfNeeded];
    });
}
static void setBtn(BOOL on){
    dispatch_async(dispatch_get_main_queue(),^{
        [gStartBtn setTitle:on?@"⏹ Dừng":@"▶ Bắt đầu" forState:UIControlStateNormal];
        UIColor *c=on?[UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1]
                     :[UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
        [gStartBtn setTitleColor:c forState:UIControlStateNormal];
    });
}

@implementation LFPanel
-(instancetype)initWithFrame:(CGRect)f{
    self=[super initWithFrame:f];if(!self)return nil;
    self.backgroundColor=[UIColor colorWithWhite:0.05 alpha:0.9];
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
    gTV.textColor=[UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
    gTV.font=[UIFont fontWithName:@"Menlo" size:10]?:[UIFont systemFontOfSize:10];
    gTV.text=@"[LazadaFarm] chờ...";[sc addSubview:gTV];

    gStartBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    [gStartBtn setTitle:@"▶ Bắt đầu" forState:UIControlStateNormal];
    [gStartBtn setTitleColor:[UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1] forState:UIControlStateNormal];
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
    gCopyFeed.textColor=[UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
    gCopyFeed.font=[UIFont systemFontOfSize:11];gCopyFeed.hidden=YES;gCopyFeed.text=@"✓ OK!";
    [self addSubview:gCopyFeed];

    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(hp:)];
    pan.minimumNumberOfTouches=pan.maximumNumberOfTouches=1;[self addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pi=[[UIPinchGestureRecognizer alloc]initWithTarget:self action:@selector(hpi:)];
    [self addGestureRecognizer:pi];
    UITapGestureRecognizer *dt=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(hdt:)];
    dt.numberOfTapsRequired=2;[self addGestureRecognizer:dt];
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
    CGFloat btnY=b.size.height-bh+4,bh2=bh-8,sw=b.size.width;
    gStartBtn.frame=CGRectMake(6,btnY,sw*0.58,bh2);
    gCopyBtn.frame=CGRectMake(sw*0.58+10,btnY,sw*0.33,bh2);
    gCopyFeed.frame=gCopyBtn.frame;
}
-(void)hp:(UIPanGestureRecognizer*)g{
    CGPoint d=[g translationInView:self.superview];
    self.center=CGPointMake(self.center.x+d.x,self.center.y+d.y);
    [g setTranslation:CGPointZero inView:self.superview];
    if(g.state==UIGestureRecognizerStateEnded||g.state==UIGestureRecognizerStateCancelled)snap();
}
-(void)hpi:(UIPinchGestureRecognizer*)g{
    if(!gVisible||g.state!=UIGestureRecognizerStateChanged)return;
    gScale=MAX(0.4,MIN(2.5,gScale*g.scale));
    CGPoint c=self.center;
    self.frame=CGRectMake(c.x-gBaseSize.width*gScale/2,c.y-gBaseSize.height*gScale/2,
                          gBaseSize.width*gScale,gBaseSize.height*gScale);
    g.scale=1.0;
}
-(void)hdt:(UITapGestureRecognizer*)g{
    gVisible=!gVisible;CGFloat sw=self.superview?self.superview.bounds.size.width:390;
    if(!gVisible){
        [UIView animateWithDuration:0.25 animations:^{
            self.frame=CGRectMake(sw-54,80,44,44);self.layer.cornerRadius=22;
            gSearch.alpha=((UIScrollView*)[self viewWithTag:99]).alpha=gStartBtn.alpha=gCopyBtn.alpha=gCopyFeed.alpha=0;
        }];
    }else{
        gSearch.alpha=((UIScrollView*)[self viewWithTag:99]).alpha=gStartBtn.alpha=gCopyBtn.alpha=gCopyFeed.alpha=1;
        [UIView animateWithDuration:0.3 animations:^{
            self.frame=CGRectMake(10,60,gBaseSize.width*gScale,gBaseSize.height*gScale);
            self.layer.cornerRadius=14;
        }completion:^(BOOL x){[self setNeedsLayout];[self layoutIfNeeded];}];
    }
}
-(void)doStart{
    gEnabled=!gEnabled;setBtn(gEnabled);
    if(!gEnabled){gFarming=NO;log_(@"[Farm] Đã dừng");return;}
    if(!gActiveWV){log_(@"[Farm] Chưa vào trang Xu — mở trang Xu trước");return;}
    if(!gFarming)[self startFarmOnWebView:gActiveWV];
}
-(void)doCopy{
    [UIPasteboard generalPasteboard].string=gTV.text?:@"";
    gCopyBtn.hidden=YES;gCopyFeed.hidden=NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        gCopyBtn.hidden=NO;gCopyFeed.hidden=YES;
    });
}
-(void)searchChanged{
    NSString *kw=gSearch.text?:@"";
    if(!kw.length){gTV.text=gFullLog;return;}
    NSMutableString *out=[NSMutableString string];
    for(NSString *l in [gFullLog componentsSeparatedByString:@"\n"])
        if([l.lowercaseString containsString:kw.lowercaseString])[out appendFormat:@"%@\n",l];
    gTV.text=out.length?out:@"Không tìm thấy";
    [self setNeedsLayout];[self layoutIfNeeded];
}
-(UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e{
    UIView *h=[super hitTest:p withEvent:e];
    if(!gVisible)return h;return(h==self)?nil:h;
}

// ─── Farm ─────────────────────────────────────────────────
-(void)startFarmOnWebView:(WKWebView*)wv{
    if(!wv||!gEnabled||gFarming)return;
    gFarming=YES;log_(@"[Farm] Scan tasks...");

    NSString *js=@"(function(){"
    "var out=[];"
    // điểm danh
    "var c=document.querySelector('[class*=\"lazcoins-checkin-card\"][class*=\"checkin-\"]');"
    "if(c){var r=c.getBoundingClientRect();"
    "  out.push({x:r.left+r.width/2,y:r.top+r.height/2,label:'CHECKIN',checkin:true});}"
    // mission button "Kiếm thêm"
    "var mb=document.querySelector('.lazcoins-check-in-date');"
    "if(mb){var r=mb.getBoundingClientRect();"
    "  out.push({x:r.left+r.width/2,y:r.top+r.height/2,label:'OPEN_MISSIONS',open:true});}"
    // tasks
    "var all=document.querySelectorAll('.mission-item-center');"
    "for(var i=0;i<all.length;i++){"
    "  var el=all[i],txt=el.textContent||'';"
    "  if(!txt.match(/0\\/\\d/))continue;"
    "  var btn=el.querySelector('.mission-item-btn-go');"
    "  if(btn&&(btn.textContent||'').trim()==='Tìm kiếm')continue;"
    "  var target=btn||el;"
    "  var r=target.getBoundingClientRect();"
    "  out.push({x:r.left+r.width/2,y:r.top+r.height/2,label:txt.substring(0,40)});}"
    "return JSON.stringify(out);"
    "})()";

    [wv evaluateJavaScript:js completionHandler:^(id res, NSError *err){
        if(!res||[res isKindOfClass:[NSNull class]]||err){
            log_([NSString stringWithFormat:@"[Farm] JS error: %@",err.localizedDescription?:@"nil"]);
            gFarming=NO;return;
        }
        NSArray *tasks=[NSJSONSerialization JSONObjectWithData:
            [res dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if(!tasks){log_(@"[Farm] Parse error");gFarming=NO;return;}
        if(!tasks.count){log_(@"[Farm] ✓ Hết task!");gFarming=NO;setBtn(NO);gEnabled=NO;return;}
        log_([NSString stringWithFormat:@"[Farm] %lu steps",(unsigned long)tasks.count]);
        [self runStep:tasks idx:0 wv:wv];
    }];
}

-(void)runStep:(NSArray*)tasks idx:(NSInteger)i wv:(WKWebView*)wv{
    if(!gEnabled||i>=(NSInteger)tasks.count){
        log_(@"[Farm] ✓ Xong hôm nay!");gFarming=NO;setBtn(NO);gEnabled=NO;return;
    }
    NSDictionary *t=tasks[i];
    NSString *label=t[@"label"]?:@"?";
    BOOL isCheckin=[t[@"checkin"] boolValue];
    BOOL isOpen=[t[@"open"] boolValue];

    log_([NSString stringWithFormat:@"[Farm] %ld/%lu: %@",(long)(i+1),(unsigned long)tasks.count,label]);

    // Convert WKWebView local coords → screen logical coords
    CGFloat wx=[t[@"x"] doubleValue];
    CGFloat wy=[t[@"y"] doubleValue];
    CGPoint webOrigin=[wv convertPoint:CGPointZero toView:nil];
    CGPoint logPt=CGPointMake(webOrigin.x+wx, webOrigin.y+wy);

    hidTap(logPt);

    NSTimeInterval delay = isCheckin ? 1.5 : isOpen ? 1.5 : 33.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{
        if(!gEnabled)return;
        if(!isCheckin&&!isOpen){
            // back về trang missions
            [wv evaluateJavaScript:@"history.back();" completionHandler:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),
                           dispatch_get_main_queue(),^{
                [self runStep:tasks idx:i+1 wv:wv];
            });
        }else{
            [self runStep:tasks idx:i+1 wv:wv];
        }
    });
}
@end

// ─── Message handler ──────────────────────────────────────
@implementation LFHandler
-(void)userContentController:(WKUserContentController*)ucc didReceiveScriptMessage:(WKScriptMessage*)msg{
    NSDictionary *body=msg.body;
    if(![body isKindOfClass:[NSDictionary class]])return;
    if([@"status" isEqualToString:body[@"type"]]){log_(body[@"text"]?:@"");return;}
    NSString *url=body[@"url"]?:@"";NSArray *els=body[@"elements"]?:@[];
    NSMutableString *t=[NSMutableString stringWithFormat:@"URL:\n%@\n\n",url];
    if(els.count){[t appendFormat:@"Elements (%lu):\n",(unsigned long)els.count];
        for(NSString*e in els)[t appendFormat:@"• %@\n",e];}
    else[t appendString:@"Chưa thấy element"];
    log_(t);
    if([url containsString:@"laz-coins"]){
        dispatch_async(dispatch_get_main_queue(),^{
            gActiveWV=(WKWebView*)msg.webView;
            if(gEnabled&&!gFarming)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                               dispatch_get_main_queue(),^{
                    if(gEnabled&&!gFarming)[gPanel startFarmOnWebView:gActiveWV];
                });
        });
    }
}
@end

static NSString *kScript=@""
"(function(){"
"if(window._lfDone)return;window._lfDone=true;"
"var last='';"
"setInterval(function(){"
"  var u=location.href;if(u===last)return;last=u;"
"  var found=[];"
"  document.querySelectorAll('.mission-item-center,.lazcoins-checkin-card').forEach(function(e){"
"    var t=(e.textContent||'').trim();"
"    if(t.length&&t.length<80)found.push(t.substring(0,60));});"
"  try{window.webkit.messageHandlers.lazadaFarm"
"    .postMessage({type:'log',url:u,elements:found});}catch(e){}"
"},800);"
"})();";

static IMP gOrigInit=NULL;
static id swizzled_init(id self,SEL _cmd,CGRect fr,WKWebViewConfiguration *cfg){
    WKUserScript *s=[[WKUserScript alloc]initWithSource:kScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [cfg.userContentController addUserScript:s];
    @try{[cfg.userContentController addScriptMessageHandler:[[LFHandler alloc]init]
                                                       name:@"lazadaFarm"];}@catch(id e){}
    return((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOrigInit)(self,_cmd,fr,cfg);
}

static void setupPanel(void){
    dispatch_async(dispatch_get_main_queue(),^{
        // Init IOHIDEvent client
        sHIDClient=IOHIDEventSystemClientCreate(kCFAllocatorDefault);

        UIWindow *kw=nil;
        for(UIWindow *w in UIApplication.sharedApplication.windows)if(w.isKeyWindow){kw=w;break;}
        if(!kw)kw=UIApplication.sharedApplication.windows.firstObject;
        if(!kw)return;
        gBaseSize=CGSizeMake(kw.bounds.size.width-20,220);
        gPanel=[[LFPanel alloc]initWithFrame:CGRectMake(10,60,gBaseSize.width,gBaseSize.height)];
        [kw addSubview:gPanel];[kw bringSubviewToFront:gPanel];

        if(!sHIDClient) log_(@"[Farm] ⚠ HID client nil — tap có thể không hoạt động");
        else log_(@"[Farm] Ready. Mở trang Xu rồi bấm Bắt đầu.");
    });
}

__attribute__((constructor))
static void Init(void){
    Class wk=NSClassFromString(@"WKWebView");if(!wk)return;
    Method m=class_getInstanceMethod(wk,@selector(initWithFrame:configuration:));if(!m)return;
    gOrigInit=method_setImplementation(m,(IMP)swizzled_init);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                   dispatch_get_main_queue(),^{setupPanel();});
}