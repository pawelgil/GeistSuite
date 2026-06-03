#import "BroadcastSheet.h"
#import "PickerCells.h"
#import "PickerControls.h"
#import "FakeIsCaptured.h"
#import "HostAppInfo.h"
#import "HostControl.h"
#import "ControlSocket.h"
#import "ShimLog.h"

#import <UIKit/UIKit.h>
#include <stdatomic.h>

static BOOL HostSupportsGlassEffect(void) {
    static BOOL cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"UIGlassEffect")) {
            cached = NO;
            return;
        }
        NSNumber *optOut = [[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"];
        cached = !(optOut && [optOut boolValue]);
    });
    return cached;
}

@interface GCPaddedLabel : UILabel
@property (nonatomic, assign) UIEdgeInsets textInsets;
@end
@implementation GCPaddedLabel
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, _textInsets)];
}
- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    size.width += _textInsets.left + _textInsets.right;
    size.height += _textInsets.top + _textInsets.bottom;
    return size;
}
@end

NSNotificationName const GCMacOSMicAuthorizationDidChangeNotification =
    @"GCMacOSMicAuthorizationDidChangeNotification";

@interface GCBroadcastSheet : UIViewController
    <UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *appDisplayName;
@property (nonatomic, strong) UIImage *appIcon;
@property (nonatomic, assign) BOOL initiallyRecording;
@property (nonatomic, copy) NSDate *recordingStartedAt;
@property (nonatomic, copy) void (^onStartConfirmed)(BOOL micEnabled);
@property (nonatomic, copy) void (^onStartCancelled)(void);
@property (nonatomic, copy) void (^onStopRequested)(void);
@property (nonatomic, copy) void (^onDismissRequested)(void);
@end

static UIWindow *gBroadcastSheetWindow = nil;

@implementation GCBroadcastSheet {
    UITableView *_tableView;
    UIView *_panelView;
    GCCircleGlassButton *_micButton;
    UIViewPropertyAnimator *_backdropBlurAnimator;
    GCRecordDotView *_statusDot;
    GCFooterButton *_actionButton;
    GCPaddedLabel *_micStateLabel;
    id _micAuthChangeObserver;
    BOOL _micEnabled;
    BOOL _recording;
    BOOL _isCountingDown;
    BOOL _isStarting;
    NSTimer *_countdownTimer;
    NSTimer *_startupTimeoutTimer;
    NSInteger _countdownValue;
    NSDate *_recordingStartTime;
    NSTimer *_durationTimer;
    BOOL _didStartFadeIn;
    id _captureChangeObserver;
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)dealloc {
    [_backdropBlurAnimator stopAnimation:YES];
    [_countdownTimer invalidate];
    [_durationTimer invalidate];
    if (_captureChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_captureChangeObserver];
    }
    if (_micAuthChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_micAuthChangeObserver];
    }
}

- (void)loadView {
    self.view = [[UIView alloc] init];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _recording = self.initiallyRecording;
    _micEnabled = GC_MicEnabled();
    _statusDot = [[GCRecordDotView alloc] init];
    _actionButton = [[GCFooterButton alloc] init];
    _micButton = [[GCCircleGlassButton alloc] initWithSize:56];
    _micStateLabel = [[GCPaddedLabel alloc] init];

    [self installBackdrop];
    [self installTopWarning];
    [self installPanel];
    [self installGeistCastChip];
    [self installMicToggle];
    [self applyRecordingState];

    if (_recording && self.recordingStartedAt) {
        _recordingStartTime = self.recordingStartedAt;
        [self startDurationTimer];
    }

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backdropTapped)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_didStartFadeIn) self.view.alpha = 0;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_didStartFadeIn) return;
    _didStartFadeIn = YES;
    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.view.alpha = 1.0; }
                     completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Intentionally do NOT invalidate _countdownTimer here. Real iOS keeps
    // the broadcast scheduled if the user dismisses the picker mid-
    // countdown; matching that means the timer must keep ticking even
    // after the window is hidden. NSTimer retains us until the final tick
    // invalidates it inside `tickCountdown`.
}

- (void)installBackdrop {
    UIVisualEffectView *backdropView = [[UIVisualEffectView alloc] initWithEffect:nil];
    backdropView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:backdropView];

    _backdropBlurAnimator = [[UIViewPropertyAnimator alloc] initWithDuration:1.0
                                                                       curve:UIViewAnimationCurveLinear
                                                                  animations:^{
        backdropView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    }];
    _backdropBlurAnimator.fractionComplete = 0.30;

    UIView *dimmingView = [[UIView alloc] init];
    dimmingView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.50];
    dimmingView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:dimmingView];

    [NSLayoutConstraint activateConstraints:@[
        [backdropView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdropView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [backdropView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdropView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [dimmingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimmingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimmingView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimmingView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)installTopWarning {
    UILabel *label = [[UILabel alloc] init];
    label.text = @"Everything on your screen, including notifications, will be recorded. Enable Do Not Disturb to prevent unexpected notifications.";
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    label.textColor = [UIColor whiteColor];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:120],
        [label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:48],
        [label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-48],
    ]];
}

- (void)installPanel {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.backgroundColor = [UIColor clearColor];
    tv.translatesAutoresizingMaskIntoConstraints = NO;

    UIVisualEffect *bgEffect;
    if (HostSupportsGlassEffect()) {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleClear];
        glass.tintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        bgEffect = glass;
    } else {
        bgEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    }
    UIVisualEffectView *glassBg = [[UIVisualEffectView alloc] initWithEffect:bgEffect];
    glassBg.contentView.backgroundColor = [UIColor clearColor];
    tv.backgroundView = glassBg;

    tv.layer.cornerRadius = 34;
    tv.layer.cornerCurve = kCACornerCurveContinuous;
    tv.layer.masksToBounds = YES;
    tv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.32].CGColor;
    tv.layer.borderWidth = 1;

    tv.delaysContentTouches = NO;
    tv.canCancelContentTouches = YES;
    tv.scrollEnabled = NO;

    tv.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    tv.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    tv.separatorInset = UIEdgeInsetsZero;
    tv.rowHeight = 52;

    tv.dataSource = self;
    tv.delegate = self;
    [tv registerClass:[GCBroadcastAppCell class] forCellReuseIdentifier:@"AppRow"];

    UIView *headerView = [self makeTableHeaderView];
    tv.tableHeaderView = headerView;
    UIView *footerView = [self makeTableFooterView];
    tv.tableFooterView = footerView;

    [self.view addSubview:tv];
    _tableView = tv;
    _panelView = tv;

    [NSLayoutConstraint activateConstraints:@[
        [tv.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [tv.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-10],
        [tv.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.84],
        [tv.heightAnchor constraintEqualToConstant:
            headerView.bounds.size.height + tv.rowHeight + footerView.bounds.size.height],
    ]];
}

- (UIView *)makeTableHeaderView {
    UIView *header = [[UIView alloc] init];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_statusDot];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Screen Recording";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_statusDot.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [_statusDot.topAnchor constraintEqualToAnchor:header.topAnchor constant:15],
        [_statusDot.widthAnchor constraintEqualToConstant:33],
        [_statusDot.heightAnchor constraintEqualToConstant:33],

        [titleLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:_statusDot.bottomAnchor constant:12],
        [titleLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-15],
    ]];
    header.frame = CGRectMake(0, 0, 320, 97);
    return header;
}

- (UIView *)makeTableFooterView {
    UIView *footer = [[UIView alloc] init];

    [_actionButton setTitle:@"Start Recording"];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_actionButton addTarget:self action:@selector(actionLabelTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:_actionButton];

    [NSLayoutConstraint activateConstraints:@[
        [_actionButton.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [_actionButton.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [_actionButton.topAnchor constraintEqualToAnchor:footer.topAnchor],
        [_actionButton.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor],
    ]];
    footer.frame = CGRectMake(0, 0, 320, 52);
    return footer;
}

- (void)installGeistCastChip {
    UIColor *fill = [UIColor colorWithRed:0.82 green:0.53 blue:0.30 alpha:1.0];
    UIColor *glow = [UIColor colorWithRed:0.93 green:0.46 blue:0.15 alpha:1.0];

    UIView *chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = fill;
    chip.layer.cornerRadius = 14;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.shadowColor = glow.CGColor;
    chip.layer.shadowOpacity = 0.35;
    chip.layer.shadowRadius = 8;
    chip.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *label = [[UILabel alloc] init];
    label.text = @"Channeled through GeistCast";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [chip addSubview:label];

    [self.view addSubview:chip];

    [NSLayoutConstraint activateConstraints:@[
        [chip.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [chip.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],

        [label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:14],
        [label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-14],
        [label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:7],
        [label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-7],
    ]];
}

- (void)installMicToggle {
    _micButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_micButton addTarget:self action:@selector(micTapped)
         forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_micButton];

    _micButton.iconView.tintColor = [UIColor colorWithWhite:0.5 alpha:1.0];

    UILabel *micTitle = [[UILabel alloc] init];
    micTitle.text = @"Microphone";
    micTitle.textColor = [UIColor whiteColor];
    micTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    micTitle.textAlignment = NSTextAlignmentCenter;
    micTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:micTitle];

    _micStateLabel.textAlignment = NSTextAlignmentCenter;
    _micStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _micStateLabel.clipsToBounds = YES;
    [self.view addSubview:_micStateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_micButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [micTitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [micTitle.topAnchor constraintEqualToAnchor:_micButton.bottomAnchor constant:8],

        [_micStateLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_micStateLabel.topAnchor constraintEqualToAnchor:micTitle.bottomAnchor constant:4],
        [_micStateLabel.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-80],
    ]];

    [self applyMicAuthState];

    __weak typeof(self) weakSelf = self;
    _micAuthChangeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:GCMacOSMicAuthorizationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        [weakSelf applyMicAuthState];
    }];
}

- (void)applyMicAuthState {
    BOOL micAuth = GC_MacOSMicAuthorized();
    UIImageSymbolConfiguration *symConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    _micButton.iconView.image = [UIImage systemImageNamed:(micAuth ? @"mic" : @"mic.slash")
                                       withConfiguration:symConfig];
    _micButton.enabled = micAuth;
    _micButton.alpha = micAuth ? 1.0 : 0.4;
    _micButton.isOn = micAuth && _micEnabled;

    if (micAuth) {
        _micStateLabel.text = _micEnabled ? @"On" : @"Off";
        _micStateLabel.textColor = [UIColor whiteColor];
        _micStateLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        _micStateLabel.backgroundColor = [UIColor clearColor];
        _micStateLabel.layer.cornerRadius = 0;
        _micStateLabel.textInsets = UIEdgeInsetsZero;
    } else {
        _micStateLabel.text = @"Allow mic in macOS — audio off";
        _micStateLabel.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.45 alpha:1.0];
        _micStateLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _micStateLabel.backgroundColor = [UIColor colorWithRed:0.30 green:0.20 blue:0.08 alpha:0.85];
        _micStateLabel.layer.cornerRadius = 10;
        _micStateLabel.textInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    }
    [_micStateLabel invalidateIntrinsicContentSize];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return 1; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    GCBroadcastAppCell *cell = [tv dequeueReusableCellWithIdentifier:@"AppRow" forIndexPath:indexPath];
    [cell configureWithTitle:[self resolvedTitle]
                   iconImage:self.appIcon
                  isSelected:YES
                 isRecording:_recording
                durationText:[self formattedDuration]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];
}

- (NSString *)resolvedTitle {
    return (self.appDisplayName.length > 0) ? self.appDisplayName : @"App";
}

- (NSString *)formattedDuration {
    if (!_recordingStartTime) return nil;
    NSInteger elapsed = (NSInteger)[[NSDate date] timeIntervalSinceDate:_recordingStartTime];
    NSInteger minutes = elapsed / 60;
    NSInteger seconds = elapsed % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
}

- (void)startDurationTimer {
    if (!_recordingStartTime) {
        _recordingStartTime = [NSDate date];
    }
    [self refreshAppCell];
    _durationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(tickDuration)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)stopDurationTimer {
    [_durationTimer invalidate];
    _durationTimer = nil;
    _recordingStartTime = nil;
}

- (void)tickDuration { [self refreshAppCell]; }

- (void)refreshAppCell {
    GCBroadcastAppCell *cell =
        (GCBroadcastAppCell *)[_tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    if (!cell) return;
    [cell configureWithTitle:[self resolvedTitle]
                   iconImage:self.appIcon
                  isSelected:YES
                 isRecording:_recording
                durationText:[self formattedDuration]];
}

- (void)applyRecordingState {
    _statusDot.isRecording = _recording;
    NSString *title;
    if (_isStarting) title = @"Starting…";
    else if (_recording) title = @"Stop Recording";
    else title = @"Start Recording";
    [_actionButton setTitle:title];
}

- (void)backdropTapped {
    if (_isStarting) return;
    if (self.onDismissRequested) self.onDismissRequested();
}

- (void)actionLabelTapped {
    if (_isStarting) return;
    if (_recording) {
        [self stopDurationTimer];
        _recording = NO;
        [self applyRecordingState];
        [self refreshAppCell];
        if (self.onStopRequested) self.onStopRequested();
    } else if (_isCountingDown) {
        [self cancelCountdown];
    } else {
        [self startCountdown];
    }
}

- (void)micTapped {
    if (_isStarting) return;
    _micEnabled = !_micEnabled;
    _micButton.isOn = _micEnabled;
    _micStateLabel.text = _micEnabled ? @"On" : @"Off";
    GC_SetMicEnabled(_micEnabled);
    // Mid-broadcast: the mic state ships separately. At start time it
    // rides on user_pressed_start instead.
    if (_recording && atomic_load(&gControlFD) >= 0) {
        GC_SendUserToggledMic(_micEnabled);
    }
}

- (void)startCountdown {
    _isCountingDown = YES;
    [_actionButton setTitle:@"Stop Recording"];
    _countdownValue = 3;
    [self tickCountdown];
    _countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(tickCountdown)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)cancelCountdown {
    [_countdownTimer invalidate];
    _countdownTimer = nil;
    _isCountingDown = NO;
    _statusDot.countdownText = nil;
    [self applyRecordingState];
    if (self.onStartCancelled) self.onStartCancelled();
}

- (void)tickCountdown {
    if (_countdownValue <= 0) {
        [_countdownTimer invalidate];
        _countdownTimer = nil;
        _statusDot.countdownText = nil;
        _isCountingDown = NO;
        [self enterStartingState];
        return;
    }
    _statusDot.countdownText = [NSString stringWithFormat:@"%ld", (long)_countdownValue];
    _countdownValue -= 1;
}

- (void)enterStartingState {
    _isStarting = YES;
    [self applyRecordingState];
    if (self.onStartConfirmed) self.onStartConfirmed(_micEnabled);

    __weak __typeof(self) weakSelf = self;
    _captureChangeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIScreenCapturedDidChangeNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!GC_FakeCaptured()) return;
        [strongSelf transitionStartingToRecording];
    }];

    _startupTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                            target:self
                                                          selector:@selector(startupTimedOut)
                                                          userInfo:nil
                                                           repeats:NO];
}

- (void)transitionStartingToRecording {
    if (!_isStarting) return;
    [_startupTimeoutTimer invalidate];
    _startupTimeoutTimer = nil;
    if (_captureChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_captureChangeObserver];
        _captureChangeObserver = nil;
    }
    _isStarting = NO;
    _recording = YES;
    [self applyRecordingState];
    [self startDurationTimer];
    [self refreshAppCell];
}

- (void)startupTimedOut {
    if (!_isStarting) return;
    if (_captureChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_captureChangeObserver];
        _captureChangeObserver = nil;
    }
    _startupTimeoutTimer = nil;
    _isStarting = NO;
    [self applyRecordingState];
    if (self.onStartCancelled) self.onStartCancelled();
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    if (!v) return YES;
    if (_panelView && [v isDescendantOfView:_panelView]) return NO;
    if ([v isDescendantOfView:_micButton]) return NO;
    return YES;
}
@end

static UIWindowScene *ActiveWindowScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive
            && [scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

// Real iOS presents the broadcast picker as an out-of-process overlay,
// which deactivates the host's scene and fires the standard lifecycle
// notifications. Our sheet is in-process, so the host's scene never
// actually changes activation state. Synthesize the notifications around
// the sheet's lifecycle so host code that observes UIApplication/UIScene
// activation transitions (e.g. HOST's audio remediation step) behaves
// the same way it does on real iOS.
//
// Gap: UIApplication.shared.applicationState / UIScene.activationState
// property reads and SwiftUI's @Environment(\.scenePhase) all key off the
// real scene state, which we don't change. UIKit hosts that observe via
// NotificationCenter (the dominant pattern) are covered.
static void GC_PostSceneInactive(UIWindowScene *scene) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    UIApplication *app = [UIApplication sharedApplication];
    [nc postNotificationName:UIApplicationWillResignActiveNotification object:app];
    if (scene) {
        [nc postNotificationName:UISceneWillDeactivateNotification object:scene];
    }
}

static void GC_PostSceneActive(UIWindowScene *scene) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    UIApplication *app = [UIApplication sharedApplication];
    if (scene) {
        [nc postNotificationName:UISceneDidActivateNotification object:scene];
    }
    [nc postNotificationName:UIApplicationDidBecomeActiveNotification object:app];
}

void GC_PresentBroadcastSheet(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBroadcastSheetWindow) return;
        UIWindowScene *scene = ActiveWindowScene();
        if (!scene) {
            GC_ERR("no foreground window scene to host broadcast sheet");
            return;
        }

        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.frame = scene.coordinateSpace.bounds;
        window.windowLevel = UIWindowLevelAlert + 1;
        window.backgroundColor = [UIColor clearColor];

        GCBroadcastSheet *sheet = [[GCBroadcastSheet alloc] init];
        sheet.appDisplayName = GC_HostAppDisplayName();
        sheet.appIcon = GC_HostAppIcon();
        sheet.initiallyRecording = GC_FakeCaptured();
        sheet.recordingStartedAt = GC_GetRecordingStartDate();

        sheet.onStartConfirmed = ^(BOOL micEnabled) {
            GC_SetMicEnabled(micEnabled);
            if (atomic_load(&gControlFD) >= 0) {
                GC_SendUserPressedStart(micEnabled);
            }
        };
        sheet.onStartCancelled = ^{
            if (atomic_load(&gControlFD) >= 0) {
                GC_SendUserCancelledStart();
            }
        };
        sheet.onStopRequested = ^{
            if (atomic_load(&gControlFD) >= 0) {
                GC_SendUserPressedStop();
            }
            GC_SetFakeCaptured(NO);
        };
        __weak GCBroadcastSheet *weakSheet = sheet;
        sheet.onDismissRequested = ^{
            UIWindow *w = gBroadcastSheetWindow;
            if (!w) return;
            gBroadcastSheetWindow = nil;
            GC_PostSceneActive(w.windowScene);
            GCBroadcastSheet *s = weakSheet;
            UIView *fadeTarget = s.view ?: w;
            [UIView animateWithDuration:0.25
                                  delay:0
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{ fadeTarget.alpha = 0; }
                             completion:^(BOOL finished) {
                w.hidden = YES;
            }];
        };

        window.rootViewController = sheet;
        GC_PostSceneInactive(scene);
        [window makeKeyAndVisible];
        gBroadcastSheetWindow = window;
        GC_LOG("presented broadcast sheet (initiallyRecording=%d)",
               (int)sheet.initiallyRecording);
    });
}
