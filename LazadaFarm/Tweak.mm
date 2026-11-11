#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>

// ─── Logger ───────────────────────────────────────────────
static void writeLog(NSString *msg) {
    NSString *docDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *logPath = [docDir stringByAppendingPathComponent:@"lazada_urls.log"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterShortStyle
            timeStyle:NSDateFormatterMediumStyle],
        msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [line writeToFile:logPath
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ─── Message handler ──────────────────────────────────────
@interface LFMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation LFMessageHandler
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (!([body isKindOfClass:[NSDictionary class]])) return;
    NSString *url   = body[@"url"]   ?: @"";
    NSString *title = body[@"title"] ?: @"";
    writeLog([NSString stringWithFormat:@"URL: %@ | Title: %@", url, title]);
}
@end

// ─── JS poll URL (SPA-safe) ───────────────────────────────
static NSString *kScript = @""
"(function(){"
"  var last='';"
"  setInterval(function(){"
"    var u=location.href;"
"    if(u!==last){"
"      last=u;"
"      try{"
"        window.webkit.messageHandlers.lazadaFarm.postMessage("
"          {url:u,title:document.title}"
"        );"
"      }catch(e){}"
"    }"
"  },800);"
"})();";

// ─── Swizzle IMP ──────────────────────────────────────────
static IMP gOriginalInit = NULL;

static id swizzled_init(id self, SEL _cmd,
                        CGRect frame,
                        WKWebViewConfiguration *config)
{
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
    writeLog(@"=== LazadaFarm loaded ===");

    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) { writeLog(@"WKWebView not found"); return; }

    SEL sel = @selector(initWithFrame:configuration:);
    Method m = class_getInstanceMethod(wk, sel);
    if (!m) { writeLog(@"method not found"); return; }

    gOriginalInit = method_setImplementation(m, (IMP)swizzled_init);
    writeLog(@"hook installed OK");
}
