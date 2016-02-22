#import <objc/runtime.h>
#import "AppDelegate+WKWebViewPolyfill.h"
#import "MyMainViewController.h"
#import <GCDWebServer/GCDWebServer.h>
#import <GCDWebServer/GCDWebServerPrivate.h>
#import <GCDWebServer/GCDWebServerDataResponse.h>

// need to swap out a method, so swizzling it here
static void swizzleMethod(Class class, SEL destinationSelector, SEL sourceSelector);


@implementation AppDelegate (WKWebViewPolyfill)

NSString *const FileSchemaConstant = @"file://";
NSString *const ServerCreatedNotificationName = @"WKWebView.WebServer.Created";
GCDWebServer* _webServer;
NSMutableDictionary* _webServerOptions;
NSString* appDataFolder;
NSString *const SessionHeader = @"X-Session";
NSString *const SessionCookie = @"peerioxsession";
NSString* sessionKey = nil;

+ (void)load {
    // Swap in our own viewcontroller which loads the wkwebview, but only in case we're running iOS 8+
    if (IsAtLeastiOSVersion(@"8.0")) {
        swizzleMethod([AppDelegate class],
                      @selector(application:didFinishLaunchingWithOptions:),
                      @selector(my_application:didFinishLaunchingWithOptions:));
    }
}

- (BOOL)my_application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    [self createWindowAndStartWebServer:true];
    return YES;
}

- (NSString *const) getSessionHeader {
    return SessionHeader;
}

- (NSString *const) getSessionKey {
    return sessionKey;
}

- (NSString *)uuidString {
    // Returns a UUID

    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidString = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);

    return uuidString;
}

- (void) createWindowAndStartWebServer:(BOOL) startWebServer {
    /* generating a random session key */
    if(sessionKey == nil) {
      sessionKey = [self uuidString];
    }
    
    CGRect screenBounds = [[UIScreen mainScreen] bounds];

    self.window = [[UIWindow alloc] initWithFrame:screenBounds];
    self.window.autoresizesSubviews = YES;
    MyMainViewController *myMainViewController = [[MyMainViewController alloc] init];
    self.viewController = myMainViewController;
    self.window.rootViewController = myMainViewController;
    [self.window makeKeyAndVisible];
    appDataFolder = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByDeletingLastPathComponent];

    // Note: the embedded webserver is still needed for iOS 9. It's not needed to load index.html,
    //       but we need it to ajax-load files (file:// protocol has no origin, leading to CORS issues).
    NSString *directoryPath = myMainViewController.wwwFolderName;

    // don't restart the webserver if we don't have to (fi. after a crash, see #223)
    if (_webServer != nil && [_webServer isRunning]) {
        [myMainViewController setServerPort:_webServer.port];
        return;
    }

    _webServer = [[GCDWebServer alloc] init];
    _webServerOptions = [NSMutableDictionary dictionary];

    // Add GET handler for local "www/" directory
    /* [_webServer addGETHandlerForBasePath:@"/"
                           directoryPath:directoryPath
                           indexFilename:nil
                                cacheAge:30
                      allowRangeRequests:YES]; */
    [self addHandlerForBasePath:@"/"
                           directoryPath:directoryPath
                           indexFilename:@"index.html"];
    [self addHandlerForPath:@"/Library/"];
    [self addHandlerForPath:@"/Documents/"];
    [self addHandlerForPath:@"/tmp/"];

    // Initialize Server startup
    if (startWebServer) {
      [self startServer];
      [myMainViewController copyLS:_webServer.port];
    }

    // Update Swizzled ViewController with port currently used by local Server
    [myMainViewController setServerPort:_webServer.port];
}

- (GCDWebServerResponse*)accessForbidden {
  return [GCDWebServerDataResponse responseWithHTML:@"Access Forbidden"];
}

- (BOOL)checkSessionKey:(GCDWebServerRequest*) request {
  if([request.headers objectForKey:SessionHeader]) {
    NSString* userSessionKey = request.headers[SessionHeader];
    return [sessionKey isEqualToString:userSessionKey];
  }
  if([request.headers objectForKey:@"Cookie"]) {
    NSString* userCookie = request.headers[@"Cookie"];
    return [userCookie containsString:sessionKey];
  }
  return false;
}

- (NSString*)formatForeverCookieHeader:(NSString*) name
                  value:(NSString*) value {
  return [NSString stringWithFormat:@"%@=%@; expires=Fri, 31 Dec 9999 23:59:59 GMT", name, value];
}

- (void)addHandlerForBasePath:(NSString *) path
                directoryPath:(NSString *) directoryPath
                indexFilename:(NSString *) indexFilename {
  [_webServer addHandlerForMethod:@"GET"
                     pathRegex: [NSString stringWithFormat:@"^%@.*", path]
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
                       /* testing for our session key */
                       if(![self checkSessionKey:request]) return [self accessForbidden];
                       NSString *fileLocation = request.URL.path;
                       if ([request.URL.path isEqualToString: @"/"]) {
                         GCDWebServerResponse* redirectResponse = [GCDWebServerResponse
                                responseWithRedirect:[NSURL
                                                      URLWithString:indexFilename
                                                      relativeToURL:request.URL]
                                permanent:NO];
                         [redirectResponse setValue:[self formatForeverCookieHeader:SessionCookie value:sessionKey]
                         forAdditionalHeader: @"Set-Cookie"];
                         return redirectResponse;
                       }
                       
                       if ([fileLocation hasPrefix:path]) {
                         fileLocation = [directoryPath stringByAppendingString:request.URL.path];
                       }
                       
                       fileLocation = [fileLocation stringByReplacingOccurrencesOfString:FileSchemaConstant withString:@""];
                       if (![[NSFileManager defaultManager] fileExistsAtPath:fileLocation]) {
                           return nil;
                       }
                         
                       GCDWebServerResponse* response = [GCDWebServerFileResponse responseWithFile:fileLocation byteRange:request.byteRange];
                       [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                       [response setValue:[self formatForeverCookieHeader:SessionCookie value:sessionKey]
                         forAdditionalHeader: @"Set-Cookie"];
                       return response;
                     }
   ];
}

- (void)addHandlerForPath:(NSString *) path {
  [_webServer addHandlerForMethod:@"GET"
                     pathRegex: [NSString stringWithFormat:@"^%@.*", path]
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
                       /* testing for our session key */
                       if(![self checkSessionKey:request]) return [self accessForbidden];
                       
                       NSString *fileLocation = request.URL.path;
                       
                       if ([fileLocation hasPrefix:path]) {
                         fileLocation = [appDataFolder stringByAppendingString:request.URL.path];
                       }
                       
                       fileLocation = [fileLocation stringByReplacingOccurrencesOfString:FileSchemaConstant withString:@""];
                       if (![[NSFileManager defaultManager] fileExistsAtPath:fileLocation]) {
                           return nil;
                       }
                         
                       GCDWebServerResponse* response = [GCDWebServerFileResponse responseWithFile:fileLocation byteRange:request.byteRange];
                       [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                       [response setValue:[self formatForeverCookieHeader:SessionCookie value:sessionKey]
                         forAdditionalHeader: @"Set-Cookie"];                       
                       return response;
                     }
   ];
}

- (BOOL)identity_application: (UIApplication *)application
                     openURL: (NSURL *)url
           sourceApplication: (NSString *)sourceApplication
                  annotation: (id)annotation {

    // call super
    return [self identity_application:application openURL:url sourceApplication:sourceApplication annotation:annotation];
}

- (void)startServer
{
    NSError *error = nil;

    // Enable this option to force the Server also to run when suspended
    //[_webServerOptions setObject:[NSNumber numberWithBool:NO] forKey:GCDWebServerOption_AutomaticallySuspendInBackground];

    [_webServerOptions setObject:[NSNumber numberWithBool:YES]
                          forKey:GCDWebServerOption_BindToLocalhost];

    // If a fixed port is passed in, use that one, otherwise use 12344.
    // If the port is taken though, look for a free port by adding 1 to the port until we find one.
    int httpPort = 12344;

    // first we check any passed-in variable during plugin install (which is copied to plist, see plugin.xml)
    NSNumber *plistPort = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WKWebViewPluginEmbeddedServerPort"];
    if (plistPort != nil) {
      httpPort = [plistPort intValue];
    }

    // now check if it was set in config.xml - this one wins if set.
    // (note that the settings can be in any casing, but they are stored in lowercase)
    if ([self.viewController.settings objectForKey:@"wkwebviewpluginembeddedserverport"]) {
      httpPort = [[self.viewController.settings objectForKey:@"wkwebviewpluginembeddedserverport"] intValue];
    }

    _webServer.delegate = (id<GCDWebServerDelegate>)self;
    do {
        [_webServerOptions setObject:[NSNumber numberWithInteger:httpPort++]
                              forKey:GCDWebServerOption_Port];
    } while(![_webServer startWithOptions:_webServerOptions error:&error]);

    if (error) {
        NSLog(@"Error starting http daemon: %@", error);
    } else {
        [GCDWebServer setLogLevel:kGCDWebServerLoggingLevel_Warning];
        NSLog(@"Started http daemon: %@ ", _webServer.serverURL);
    }
}

//MARK:GCDWebServerDelegate
- (void)webServerDidStart:(GCDWebServer*)server {
    [NSNotificationCenter.defaultCenter postNotificationName:ServerCreatedNotificationName
                                                      object: @[self.viewController, _webServer]];
}

@end


#pragma mark Swizzling

static void swizzleMethod(Class class, SEL destinationSelector, SEL sourceSelector) {
    Method destinationMethod = class_getInstanceMethod(class, destinationSelector);
    Method sourceMethod = class_getInstanceMethod(class, sourceSelector);

    // If the method doesn't exist, add it.  If it does exist, replace it with the given implementation.
    if (class_addMethod(class, destinationSelector, method_getImplementation(sourceMethod), method_getTypeEncoding(sourceMethod))) {
        class_replaceMethod(class, destinationSelector, method_getImplementation(destinationMethod), method_getTypeEncoding(destinationMethod));
    } else {
        method_exchangeImplementations(destinationMethod, sourceMethod);
    }
}
