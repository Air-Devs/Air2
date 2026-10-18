#import <UIKit/UIKit.h>

@interface PLLogOutputView : UIView
- (void)actionStartStopLogOutput;
- (void)actionToggleLogOutput;
- (void)dismissAndReturnToLauncher;
+ (void)appendToLog:(NSString *)line;
+ (void)handleExitCode:(int)code;
@end
