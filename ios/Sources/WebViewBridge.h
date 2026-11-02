#import <WebKit/WebKit.h>

// Use the Objective-C API to avoid a dependency on the Swift WebKit overlay.
void JPReaderEvaluate(WKWebView * _Nonnull view, NSString * _Nonnull script,
                      void (^ _Nonnull completion)(id _Nullable, NSError * _Nullable));

// The same in any content world: the story page's own (.page, for its key) or one of the app's.
void JPReaderEvaluateInWorld(WKWebView * _Nonnull view, NSString * _Nonnull script, WKContentWorld * _Nonnull world,
                             void (^ _Nonnull completion)(id _Nullable, NSError * _Nullable));
