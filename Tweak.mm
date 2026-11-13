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
static UIButton    *gStartBtn = nil;
static UILabel     *gCopyFeed = nil;
static NSString    *gFullLog  = @"";
static BOOL         gVisible  = YES;
static CGFloat      gScale    = 1.0;
static CGSize       gBaseSize;

static void snapToEdge(void) {
    UIView *p = gPanel.superview; if (!p) return;
    CGRect fr = gPanel.frame;
    CGFloat tx = (CGRectGetMidX(fr)<p.bounds.size.width/2.0)?10:p.bounds.size.width-fr.size.width-10;
    CGFloat ty = MAX(60,MIN(fr.origin.y,p.bounds.size.height-fr.size.height-34));
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{gPanel.frame=CGRectMake(tx,ty,fr.size.width,fr.size.height);}completion:nil];
}

static void applyFilter(void) {
    NSString *kw=gSearch.text?:@"";
    if(!kw.length){gTV.text=gFullLog;return;}
    NSMutableString *out=[NSMutableString string];
    for(NSString *l in [gFullLog componentsSeparatedByString:@"\n"])
        if([l.lowercaseString containsString:kw.lowercaseString])[out appendFormat:@"%@\n",l];
    gTV.text=out.length?out:@"Không tìm thấy";
}

static void updatePanel(NSString *text) {
    dispatch_async(dispatch_get_main_queue(),^{
        gFullLog=text;
        if(gVisible)applyFilter();
        gPanel.hidden=NO;
        [gPanel setNeedsLayout];[gPanel layoutIfNeeded];
    });
}

static void updateStartBtn(BOOL running) {
    dispatch_async(dispatch_get_main_queue(),^{
        NSString *title = running ? @"⏹ Dừng" : @"▶ Bắt đầu";
        UIColor *color = running
            ? [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0]
            : [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0];
        [gStartBtn setTitle:title forState:UIControlStateNormal];
        [gStartBtn setTitleColor:color forState:UIControlStateNormal];
    });
}

@implementation LFPanel
- (instancetype)initWithFrame:(CGRect)frame {
    self=[super initWithFrame:frame];if(!self)return nil;
    self.backgroundColor=[UIColor colorWithWhite:0.05 alpha:0.90];
    self.layer.cornerRadius=14;self.clipsToBounds=YES;
    self.layer.borderColor=[UIColor colorWithWhite:0.3 alpha:0.5].CGColor;
    self.layer.borderWidth=0.5;

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

    // Bottom bar: Start + Copy
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
    UIPinchGestureRecognizer *pinch=[[UIPinchGestureRecognizer alloc]initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:pinch];
    UITapGestureRecognizer *dtap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(handleDoubleTap:)];
    dtap.numberOfTapsRequired=2;[self addGestureRecognizer:dtap];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];if(!gVisible)return;
    CGRect b=self.bounds;
    CGFloat top=46,bh=36,gap=4;
    gSearch.frame=CGRectMake(8,8,b.size.width-16,30);
    UIScrollView *sc=(UIScrollView*)[self viewWithTag:99];
    sc.frame=CGRectMake(0,top,b.size.width,b.size.height-top-bh-gap);
    CGSize fit=[gTV sizeThatFits:CGSizeMake(b.size.width-8,CGFLOAT_MAX)];
    gTV.frame=CGRectMake(4,0,b.size.width-8,MAX(fit.height,sc.frame.size.height));
    sc.contentSize=CGSizeMake(b.size.width,gTV.frame.size.height);
    // bottom: [Start 60%] [Copy 35%]
    CGFloat btnY=b.size.height-bh+4,bh2=bh-8;
    CGFloat startW=b.size.width*0.58,copyW=b.size.width*0.33;
    gStartBtn.frame=CGRectMake(6,btnY,startW,bh2);
    gCopyBtn.frame=CGRectMake(startW+10,btnY,copyW,bh2);
    gCopyFeed.frame=gCopyBtn.frame;
}

- (void)handlePan:(UIPanGestureRecognizer*)g {
    CGPoint d=[g translationInView:self.superview];
    self.center=CGPointMake(self.center.x+d.x,self.center.y+d.y);
    [g setTranslation:CGPointZero inView:self.superview];
    if(g.state==UIGestureRecognizerStateEnded||g.state==UIGestureRecognizerStateCancelled)snapToEdge();
}
- (void)handlePinch:(UIPinchGestureRecognizer*)g {
    if(!gVisible||g.state!=UIGestureRecognizerStateChanged)return;
    gScale=MAX(0.4,MIN(2.5,gScale*g.scale));
    CGPoint c=self.center;
    self.frame=CGRectMake(c.x-gBaseSize.width*gScale/2,c.y-gBaseSize.height*gScale/2,
                          gBaseSize.width*gScale,gBaseSize.height*gScale);
    g.scale=1.0;
}
- (void)handleDoubleTap:(UITapGestureRecognizer*)g {
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
- (void)doStart {
    // Toggle farm via JS postMessage vào WKWebView
    // Dùng NSNotification để gọi sang WKWebView evaluateJavaScript
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LFToggleFarm" object:nil];
}
- (void)doCopy {
    [UIPasteboard generalPasteboard].string=gTV.text?:@"";
    gCopyBtn.hidden=YES;gCopyFeed.hidden=NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        gCopyBtn.hidden=NO;gCopyFeed.hidden=YES;
    });
}
- (void)searchChanged{applyFilter();[self setNeedsLayout];[self layoutIfNeeded];}
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    UIView *h=[super hitTest:p withEvent:e];
    if(!gVisible)return h;
    return(h==self)?nil:h;
}
@end

@implementation LFHandler
- (void)userContentController:(WKUserContentController*)ucc didReceiveScriptMessage:(WKScriptMessage*)msg {
    NSDictionary *body=msg.body;
    if(![body isKindOfClass:[NSDictionary class]])return;
    NSString *type=body[@"type"]?:@"log";
    if([@"status" isEqualToString:type]){
        updatePanel(body[@"text"]?:@"");
        BOOL running=[body[@"running"] boolValue];
        updateStartBtn(running);
        return;
    }
    NSString *url=body[@"url"]?:@"";NSArray *els=body[@"elements"]?:@[];
    NSMutableString *t=[NSMutableString stringWithFormat:@"URL:\n%@\n\n",url];
    if(els.count){[t appendFormat:@"Elements (%lu):\n",(unsigned long)els.count];for(NSString*e in els)[t appendFormat:@"• %@\n",e];}
    else[t appendString:@"Chưa thấy element xu/checkin"];
    updatePanel(t);
}
@end

// ─── JS: 2 scripts ───────────────────────────────────────
// Script A: chạy trên trang đích (không phải laz-coins)
// Khi detect sessionStorage.lfActive=true → scroll simulation → back sau 33s
static NSString *kScriptTarget = @""
"(function(){"
"  if(location.href.indexOf('laz-coins')>-1)return;" // chỉ chạy trên trang đích
"  if(sessionStorage.getItem('lfActive')!=='1')return;"
"  function st(m){try{window.webkit.messageHandlers.lazadaFarm.postMessage({type:'status',text:'[Farm] '+m,running:true});}catch(e){}}"
"  st('Đang xem trang...');"
// simulate scroll để Lazada track visibility
"  var scrolled=0;"
"  var iv=setInterval(function(){"
"    window.scrollBy(0,80);"
"    scrolled+=80;"
"    if(scrolled>600){clearInterval(iv);}"
"  },500);"
"})();";

// Script B: farm loop trên laz-coins
static NSString *kScriptMain = @""
"(function(){"
"if(window._lfInit)return;"
"window._lfInit=true;"
"window._lfFarming=false;"
"window._lfEnabled=false;" // start/stop toggle

"function st(m,running){"
"  try{window.webkit.messageHandlers.lazadaFarm"
"    .postMessage({type:'status',text:'[Farm] '+m,running:running===undefined?window._lfFarming:running});"
"  }catch(e){}}"

"function wait(ms){return new Promise(r=>setTimeout(r,ms));}"

"function tap(el){"
"  if(!el)return false;"
"  var r=el.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;"
"  try{"
"    var t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y,"
"      screenX:x,screenY:y,pageX:x,pageY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});"
"    el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,"
"      touches:[t],targetTouches:[t],changedTouches:[t]}));"
"    el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,"
"      touches:[],targetTouches:[],changedTouches:[t]}));"
"  }catch(e){}"
"  el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:x,clientY:y}));"
"  return true;}"

// Lấy list task chưa làm, bỏ task "Tìm kiếm" (mở native UI)
"function getPending(){"
"  var all=document.querySelectorAll('.mission-item-center'),out=[];"
"  for(var i=0;i<all.length;i++){"
"    var el=all[i],txt=el.textContent||'';"
"    if(!txt.match(/0\\/\\d/))continue;"
"    var btn=el.querySelector('.mission-item-btn-go');"
"    if(btn&&(btn.textContent||'').trim()==='Tìm kiếm')continue;"
"    out.push({el:el,label:txt.substring(0,40)});}"
"  return out;}"

// Lưu progress vào localStorage để resume
"function saveProgress(idx,total){"
"  localStorage.setItem('lfIdx',''+idx);"
"  localStorage.setItem('lfTotal',''+total);"
"  localStorage.setItem('lfDate',new Date().toDateString());}"

"function loadProgress(){"
"  var d=localStorage.getItem('lfDate');"
"  if(d!==new Date().toDateString())return 0;" // reset mỗi ngày
"  return parseInt(localStorage.getItem('lfIdx')||'0');}"

"async function farm(){"
"  if(window._lfFarming)return;"
"  window._lfFarming=true;"
"  st('Bắt đầu...',true);"
"  await wait(2500);"

// Điểm danh
"  var c=document.querySelector('[class*=\"lazcoins-checkin-card\"][class*=\"checkin-\"]');"
"  if(c){st('Điểm danh...',true);tap(c);await wait(2000);}else st('Đã điểm danh',true);"

// Mở mission list
"  var mb=document.querySelector('.lazcoins-check-in-date');"
"  if(mb){tap(mb);await wait(2000);}"

"  var pending=getPending();"
"  var startIdx=loadProgress();"
"  st(''+pending.length+' task | tiếp từ #'+startIdx,true);"

"  for(var j=startIdx;j<pending.length;j++){"
"    if(!window._lfEnabled){st('Đã dừng',false);window._lfFarming=false;return;}"
"    var task=pending[j];"
"    st('('+(j+1)+'/'+pending.length+'): '+task.label,true);"
"    saveProgress(j,pending.length);"
"    var btn=task.el.querySelector('.mission-item-btn-go');"

// Set flag cho trang đích biết đang farm
"    sessionStorage.setItem('lfActive','1');"
"    tap(btn||task.el);"
"    await wait(33000);"
"    sessionStorage.removeItem('lfActive');"

"    if(location.href.indexOf('laz-coins')===-1){"
"      history.back();"
"      await wait(3000);"
"      if(location.href.indexOf('laz-coins')===-1){window._lfFarming=false;return;}"
"    }"
"    var newP=getPending();"
"    if(newP.length>0&&newP.length<=pending.length){pending=newP;}"
"  }"

"  saveProgress(0,0);" // reset progress khi xong
"  st('✓ Xong hôm nay!',false);"
"  window._lfFarming=false;}"

// Toggle start/stop từ native button
"window._lfToggle=function(){"
"  window._lfEnabled=!window._lfEnabled;"
"  if(window._lfEnabled){"
"    st('Bắt đầu farm...',true);"
"    if(location.href.indexOf('laz-coins')>-1)farm();"
"  }else{"
"    st('Đã dừng',false);"
"    window._lfFarming=false;"
"  }"
"};"

"var lastURL='';"
"setInterval(function(){"
"  var u=location.href;"
"  if(u!==lastURL){"
"    lastURL=u;"
"    try{window.webkit.messageHandlers.lazadaFarm.postMessage({type:'log',url:u,elements:[]});}catch(e){}"
"    if(u.indexOf('laz-coins')>-1&&window._lfEnabled&&!window._lfFarming)setTimeout(farm,1000);"
"  }"
"},800);"
"})();";

// ─── WKWebView hook ───────────────────────────────────────
static NSMutableArray *gWebViews = nil; // track active webviews để gọi toggle

static IMP gOrigInit=NULL;
static id swizzled_init(id self,SEL _cmd,CGRect frame,WKWebViewConfiguration *cfg){
    // Script target: chạy trên tất cả trang
    WKUserScript *sTarget=[[WKUserScript alloc]initWithSource:kScriptTarget
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    // Script main: chạy trên tất cả trang nhưng chỉ active khi URL = laz-coins
    WKUserScript *sMain=[[WKUserScript alloc]initWithSource:kScriptMain
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [cfg.userContentController addUserScript:sTarget];
    [cfg.userContentController addUserScript:sMain];
    @try{[cfg.userContentController addScriptMessageHandler:[[LFHandler alloc]init] name:@"lazadaFarm"];}@catch(NSException *e){}

    id result=((id(*)(id,SEL,CGRect,WKWebViewConfiguration*))gOrigInit)(self,_cmd,frame,cfg);

    // Track webview để gọi JS toggle
    dispatch_async(dispatch_get_main_queue(),^{
        if(!gWebViews)gWebViews=[NSMutableArray array];
        [gWebViews addObject:[NSValue valueWithNonretainedObject:result]];
    });

    return result;
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

        // Nhận toggle từ nút Start
        [[NSNotificationCenter defaultCenter] addObserverForName:@"LFToggleFarm"
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
            // Gọi _lfToggle() trên tất cả webview đang active
            for(NSValue *v in gWebViews){
                WKWebView *wv=(WKWebView*)v.nonretainedObjectValue;
                if([wv isKindOfClass:[WKWebView class]])
                    [wv evaluateJavaScript:@"if(window._lfToggle)window._lfToggle();" completionHandler:nil];
            }
        }];
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