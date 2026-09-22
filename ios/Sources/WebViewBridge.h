#import <WebKit/WebKit.h>

// Use the Objective-C API to avoid a dependency on the Swift WebKit overlay.
void JPReaderEvaluate(WKWebView * _Nonnull view, NSString * _Nonnull script,
                      void (^ _Nonnull completion)(id _Nullable, NSError * _Nullable));
