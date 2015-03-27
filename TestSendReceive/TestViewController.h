#import <UIKit/UIKit.h>
#import "GStreamerBackendDelegate.h"

@interface TestViewController : UIViewController <GStreamerBackendDelegate>

/* From GStreamerBackendDelegate */
-(void) gstreamerInitialized;
-(void) gstreamerSetUIMessage:(NSString *)message;

@end
