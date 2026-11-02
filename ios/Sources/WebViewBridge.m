#import "WebViewBridge.h"

void JPReaderEvaluate(WKWebView *view, NSString *script, void (^completion)(id, NSError *)) {
    [view evaluateJavaScript:script inFrame:nil
             inContentWorld:[WKContentWorld worldWithName:@"JapaneseReaderSelection"]
          completionHandler:completion];
}

void JPReaderEvaluateInWorld(WKWebView *view, NSString *script, WKContentWorld *world, void (^completion)(id, NSError *)) {
    [view evaluateJavaScript:script inFrame:nil inContentWorld:world completionHandler:completion];
}
