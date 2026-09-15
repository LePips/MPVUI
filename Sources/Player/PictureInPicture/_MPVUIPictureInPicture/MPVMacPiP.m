#import "MPVMacPiP.h"
#import <dlfcn.h>
#import <math.h>

// Declarations only; private implementation symbols are resolved at runtime.
@protocol MPVSystemPiPPlaybackState <NSObject>
@property (nonatomic) NSTimeInterval contentDuration;
@property (nonatomic) NSInteger contentType;
- (void)setPlaybackRate:(double)rate elapsedTime:(NSTimeInterval)elapsedTime timeControlStatus:(NSInteger)status;
@end

@protocol MPVSystemPiP <NSObject>
@property (nonatomic, weak) id delegate;
@property (nonatomic, weak, nullable) NSWindow *replacementWindow;
@property (nonatomic) NSRect replacementRect;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSSize aspectRatio;
- (void)presentViewControllerAsPictureInPicture:(NSViewController *)content;
- (void)dismissViewController:(NSViewController *)content;
- (void)updatePlaybackStateUsingBlock:(void (NS_NOESCAPE ^)(id<MPVSystemPiPPlaybackState>))update;
@end

static NSError *MPVMacPiPError(NSException *exception) {
    return [NSError errorWithDomain:@"MPVUI.MacPictureInPicture" code:1
                          userInfo:@{NSLocalizedDescriptionKey:
                              exception.reason ?: @"The macOS Picture in Picture framework rejected the request."}];
}

@implementation MPVMacPiP {
    NSViewController<MPVSystemPiP> *_controller;
}

+ (Class)controllerClass {
    static Class controllerClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Objective-C classes must remain loaded for the process lifetime.
        if (!dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_LAZY | RTLD_LOCAL)) return;
        Class candidate = NSClassFromString(@"PIPViewController");
        if (![candidate isSubclassOfClass:NSViewController.class]) return;
        for (NSString *name in @[
            @"setDelegate:", @"setReplacementWindow:", @"setReplacementRect:",
            @"setPlaying:", @"setAspectRatio:",
            @"presentViewControllerAsPictureInPicture:", @"dismissViewController:"
        ]) {
            if (![candidate instancesRespondToSelector:NSSelectorFromString(name)]) return;
        }
        controllerClass = candidate;
    });
    return controllerClass;
}

+ (BOOL)isSupported { return [self controllerClass] != Nil; }

- (nullable instancetype)initWithAvailabilityCheck:(BOOL)check {
    if ((self = [super init])) {
        Class controllerClass = [MPVMacPiP controllerClass];
        if (!controllerClass) return nil;
        @try {
            _controller = [[controllerClass alloc] init];
            if (!_controller) return nil;
            _controller.delegate = self;
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return self;
}

- (BOOL)present:(NSViewController *)content error:(NSError **)error {
    @try {
        [_controller presentViewControllerAsPictureInPicture:content];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MPVMacPiPError(exception);
        return NO;
    }
}

- (BOOL)dismiss:(NSViewController *)content error:(NSError **)error {
    @try {
        [_controller dismissViewController:content];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MPVMacPiPError(exception);
        return NO;
    }
}

- (void)setReplacementWindow:(NSWindow *)window rect:(NSRect)rect {
    @try {
        _controller.replacementWindow = window;
        _controller.replacementRect = rect;
    } @catch (NSException *exception) {
        // Animation hints are optional; their failure must not strand content.
    }
}

- (void)updatePlaying:(BOOL)playing aspectRatio:(NSSize)aspectRatio {
    @try {
        _controller.playing = playing;
        if (isfinite(aspectRatio.width) && isfinite(aspectRatio.height) &&
            aspectRatio.width > 0 && aspectRatio.height > 0) {
            _controller.aspectRatio = aspectRatio;
        }
    } @catch (NSException *exception) {
        // Runtime playback controls are advisory; mpv remains authoritative.
    }
}

- (void)updatePlaybackRate:(double)rate elapsedTime:(NSTimeInterval)elapsedTime duration:(NSTimeInterval)duration {
    if (![_controller respondsToSelector:@selector(updatePlaybackStateUsingBlock:)]) return;
    @try {
        [_controller updatePlaybackStateUsingBlock:^(id<MPVSystemPiPPlaybackState> state) {
            if (![state respondsToSelector:@selector(setContentDuration:)] ||
                ![state respondsToSelector:@selector(setContentType:)] ||
                ![state respondsToSelector:@selector(setPlaybackRate:elapsedTime:timeControlStatus:)]) return;
            // Never hand undocumented playback-state code NaN or infinity.
            state.contentDuration = isfinite(duration) && duration > 0 ? duration : 0;
            state.contentType = duration > 0 && isfinite(duration) ? 1 : 0;
            [state setPlaybackRate:isfinite(rate) && rate > 0 ? rate : 0
                       elapsedTime:isfinite(elapsedTime) && elapsedTime >= 0 ? elapsedTime : 0
                 timeControlStatus:rate > 0 ? 2 : 0];
        }];
    } @catch (NSException *exception) {
        // This optional selector is absent on some framework versions.
    }
}

- (BOOL)pipShouldClose:(id)pip {
    return self.delegate ? [self.delegate pictureInPictureShouldClose] : YES;
}
- (void)pipWillClose:(id)pip { [self.delegate pictureInPictureWillClose]; }
- (void)pipDidClose:(id)pip { [self.delegate pictureInPictureDidClose]; }
- (void)pipActionPlay:(id)pip { [self.delegate pictureInPictureSetPlaying:YES]; }
- (void)pipActionPause:(id)pip { [self.delegate pictureInPictureSetPlaying:NO]; }
- (void)pipActionStop:(id)pip { [self.delegate pictureInPictureSetPlaying:NO]; }
- (void)pipAction:(id)pip skipInterval:(NSTimeInterval)interval {
    [self.delegate pictureInPictureSkipBy:interval];
}
@end
