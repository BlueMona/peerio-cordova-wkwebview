//
//  AppDelegate+WKWebViewPolyfill.h
//
//  Created by Hein Rutjes on X-mas eve
//
//

#import "AppDelegate.h"

@interface AppDelegate (WKWebViewPolyfill)


- (void) createWindowAndStartWebServer:(BOOL) startWebServer;

- (NSString *const) getSessionHeader;
- (NSString *const) getSessionKey;

@end
