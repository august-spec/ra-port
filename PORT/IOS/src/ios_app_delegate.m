#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <stdlib.h>

#import "SDL_uikitappdelegate.h"

@interface RedAlertIOSDelegate : SDLUIKitDelegate
@end

@interface SDLUIKitDelegate (RedAlertPrivate)
- (void)postFinishLaunch;
@end

static NSString *RedAlertGetAppDelegateClassName(id self, SEL selector)
{
	return @"RedAlertIOSDelegate";
}

static void RedAlertOrientationDebug(char const *message)
{
	if (getenv("RA_IOS_ORIENTATION_DEBUG")) {
		fprintf(stderr, "RA_IOS_ORIENTATION: %s\n", message);
		NSLog(@"RA_IOS_ORIENTATION: %s", message);
	}
}

@implementation RedAlertIOSDelegate

+ (void)load
{
	Class meta_class = object_getClass([SDLUIKitDelegate class]);
	Method method = class_getClassMethod([SDLUIKitDelegate class], @selector(getAppDelegateClassName));
	char const *types = method ? method_getTypeEncoding(method) : "@@:";
	class_replaceMethod(meta_class, @selector(getAppDelegateClassName), (IMP)RedAlertGetAppDelegateClassName, types);
	RedAlertOrientationDebug("installed delegate class override");
}

- (void)redAlert_requestLandscapeGeometry
{
	if (@available(iOS 16.0, *)) {
		UIWindowScene *window_scene = nil;
		UIWindow *window = [self window];
		if ([window respondsToSelector:@selector(windowScene)]) {
			window_scene = window.windowScene;
		}
		if (!window_scene) {
			for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
				if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState != UISceneActivationStateUnattached) {
					window_scene = (UIWindowScene *)scene;
					break;
				}
			}
		}
		if (!window_scene) {
			RedAlertOrientationDebug("no window scene for landscape request");
			return;
		}

		UIWindowSceneGeometryPreferencesIOS *preferences =
			[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
		[window_scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
			(void)error;
			RedAlertOrientationDebug("landscape geometry request failed");
		}];
		[preferences release];

		for (UIWindow *scene_window in window_scene.windows) {
			[scene_window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
		}
	} else {
		[UIViewController attemptRotationToDeviceOrientation];
	}
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
	return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	RedAlertOrientationDebug("RedAlertIOSDelegate didFinishLaunching");
	BOOL launched = [super application:application didFinishLaunchingWithOptions:launchOptions];
	[self redAlert_requestLandscapeGeometry];
	return launched;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	RedAlertOrientationDebug("RedAlertIOSDelegate didBecomeActive");
	[self redAlert_requestLandscapeGeometry];
}

- (void)postFinishLaunch
{
	RedAlertOrientationDebug("RedAlertIOSDelegate postFinishLaunch");
	[self redAlert_requestLandscapeGeometry];
	[super postFinishLaunch];
}

@end
