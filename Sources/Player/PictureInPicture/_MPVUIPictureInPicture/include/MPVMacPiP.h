#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@protocol MPVMacPiPDelegate <NSObject>
- (BOOL)pictureInPictureShouldClose;
- (void)pictureInPictureWillClose;
- (void)pictureInPictureDidClose;
- (void)pictureInPictureSetPlaying:(BOOL)playing NS_SWIFT_NAME(pictureInPictureSetPlaying(_:));
- (void)pictureInPictureSkipBy:(NSTimeInterval)interval NS_SWIFT_NAME(pictureInPictureSkip(by:));
@end

/// An optional adapter for the private macOS PIP.framework. No private
/// framework is linked, and a missing or changed runtime reports unavailable.
NS_SWIFT_UI_ACTOR
@interface MPVMacPiP : NSObject
@property (nonatomic, weak, nullable) id<MPVMacPiPDelegate> delegate;
+ (BOOL)isSupported;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithAvailabilityCheck:(BOOL)check NS_SWIFT_NAME(init(checkingAvailability:));
- (BOOL)present:(NSViewController *)content error:(NSError * _Nullable * _Nullable)error;
- (BOOL)dismiss:(NSViewController *)content error:(NSError * _Nullable * _Nullable)error;
- (void)setReplacementWindow:(nullable NSWindow *)window rect:(NSRect)rect;
- (void)updatePlaying:(BOOL)playing aspectRatio:(NSSize)aspectRatio;
- (void)updatePlaybackRate:(double)rate elapsedTime:(NSTimeInterval)elapsedTime duration:(NSTimeInterval)duration;
@end

NS_ASSUME_NONNULL_END
