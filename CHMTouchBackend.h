#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, CHMTouchPhase) { CHMTouchPhaseDown = 0, CHMTouchPhaseUp = 3 };
typedef BOOL (^CHMTouchDispatchHandler)(CGPoint point, CHMTouchPhase phase, NSError * _Nullable * _Nullable error);
@interface CHMTouchBackend : NSObject
@property (nonatomic, copy, nullable) CHMTouchDispatchHandler dispatchHandler;
@property (nonatomic, readonly, getter=isAvailable) BOOL available;
- (BOOL)dispatchPoint:(CGPoint)point phase:(CHMTouchPhase)phase error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END