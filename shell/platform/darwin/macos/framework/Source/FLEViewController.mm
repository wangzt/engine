// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/macos/framework/Headers/FLEViewController.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FLEViewController_Internal.h"

#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterChannels.h"
#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterCodecs.h"
#import "flutter/shell/platform/darwin/macos/framework/Headers/FLEReshapeListener.h"
#import "flutter/shell/platform/darwin/macos/framework/Headers/FLEView.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FLETextInputPlugin.h"
#import "flutter/shell/platform/embedder/embedder.h"

static NSString* const kICUBundlePath = @"icudtl.dat";

static const int kDefaultWindowFramebuffer = 0;

namespace {

/**
 * State tracking for mouse events, to adapt between the events coming from the system and the
 * events that the embedding API expects.
 */
struct MouseState {
  /**
   * Whether or not a kAdd event has been sent (or sent again since the last kRemove if tracking is
   * enabled). Used to determine whether to send a kAdd event before sending an incoming mouse
   * event, since Flutter expects pointers to be added before events are sent for them.
   */
  bool flutter_state_is_added = false;

  /**
   * Whether or not a kDown has been sent since the last kAdd/kUp.
   */
  bool flutter_state_is_down = false;

  /**
   * Whether or not mouseExited: was received while a button was down. Cocoa's behavior when
   * dragging out of a tracked area is to send an exit, then keep sending drag events until the last
   * button is released. If it was released inside the view, mouseEntered: is sent the next time the
   * mouse moves. Flutter doesn't expect to receive events after a kRemove, so the kRemove for the
   * exit needs to be delayed until after the last mouse button is released.
   */
  bool has_pending_exit = false;

  /**
   * The currently pressed buttons, as represented in FlutterPointerEvent.
   */
  int64_t buttons = 0;

  /**
   * Resets all state to default values.
   */
  void Reset() {
    flutter_state_is_added = false;
    flutter_state_is_down = false;
    has_pending_exit = false;
    buttons = 0;
  }
};

}  // namespace

#pragma mark - Private interface declaration.

/**
 * Private interface declaration for FLEViewController.
 */
@interface FLEViewController ()

/**
 * A list of additional responders to keyboard events. Keybord events are forwarded to all of them.
 */
@property(nonatomic) NSMutableOrderedSet<NSResponder*>* additionalKeyResponders;

/**
 * The tracking area used to generate hover events, if enabled.
 */
@property(nonatomic) NSTrackingArea* trackingArea;

/**
 * The current state of the mouse and the sent mouse events.
 */
@property(nonatomic) MouseState mouseState;

/**
 * Updates |trackingArea| for the current tracking settings, creating it with
 * the correct mode if tracking is enabled, or removing it if not.
 */
- (void)configureTrackingArea;

/**
 * Creates and registers plugins used by this view controller.
 */
- (void)addInternalPlugins;

/**
 * Shared implementation of the regular and headless public APIs.
 */
- (BOOL)launchEngineInternalWithAssetsPath:(nonnull NSURL*)assets
                                  headless:(BOOL)headless
                      commandLineArguments:(nullable NSArray<NSString*>*)arguments;

/**
 * Creates a render config with callbacks based on whether the embedder is being run as a headless
 * server.
 */
+ (FlutterRendererConfig)createRenderConfigHeadless:(BOOL)headless;

/**
 * Creates the OpenGL context used as the resource context by the engine.
 */
- (void)createResourceContext;

/**
 * Makes the OpenGL context used by the engine for rendering optimization the
 * current context.
 */
- (void)makeResourceContextCurrent;

/**
 * Responds to system messages sent to this controller from the Flutter engine.
 */
- (void)handlePlatformMessage:(const FlutterPlatformMessage*)message;

/**
 * Calls dispatchMouseEvent:phase: with a phase determined by self.mouseState.
 *
 * mouseState.buttons should be updated before calling this method.
 */
- (void)dispatchMouseEvent:(nonnull NSEvent*)event;

/**
 * Converts |event| to a FlutterPointerEvent with the given phase, and sends it to the engine.
 */
- (void)dispatchMouseEvent:(nonnull NSEvent*)event phase:(FlutterPointerPhase)phase;

/**
 * Converts |event| to a key event channel message, and sends it to the engine.
 */
- (void)dispatchKeyEvent:(NSEvent*)event ofType:(NSString*)type;

/**
 * Initializes the KVO for user settings and passes the initial user settings to the engine.
 */
- (void)sendInitialSettings;

/**
 * Responsds to updates in the user settings and passes this data to the engine.
 */
- (void)onSettingsChanged:(NSNotification*)notification;

/**
 * Handles messages received from the Flutter engine on the _*Channel channels.
 */
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result;

@end

#pragma mark - Static methods provided to engine configuration

/**
 * Makes the owned FlutterView the current context.
 */
static bool OnMakeCurrent(FLEViewController* controller) {
  [controller.view makeCurrentContext];
  return true;
}

/**
 * Clears the current context.
 */
static bool OnClearCurrent(FLEViewController* controller) {
  [NSOpenGLContext clearCurrentContext];
  return true;
}

/**
 * Flushes the GL context as part of the Flutter rendering pipeline.
 */
static bool OnPresent(FLEViewController* controller) {
  [controller.view onPresent];
  return true;
}

/**
 * Returns the framebuffer object whose color attachment the engine should render into.
 */
static uint32_t OnFBO(FLEViewController* controller) {
  return kDefaultWindowFramebuffer;
}

/**
 * Handles the given platform message by dispatching to the controller.
 */
static void OnPlatformMessage(const FlutterPlatformMessage* message,
                              FLEViewController* controller) {
  [controller handlePlatformMessage:message];
}

/**
 * Makes the resource context the current context.
 */
static bool OnMakeResourceCurrent(FLEViewController* controller) {
  [controller makeResourceContextCurrent];
  return true;
}

#pragma mark Static methods provided for headless engine configuration

static bool HeadlessOnMakeCurrent(FLEViewController* controller) {
  return false;
}

static bool HeadlessOnClearCurrent(FLEViewController* controller) {
  return false;
}

static bool HeadlessOnPresent(FLEViewController* controller) {
  return false;
}

static uint32_t HeadlessOnFBO(FLEViewController* controller) {
  return kDefaultWindowFramebuffer;
}

static bool HeadlessOnMakeResourceCurrent(FLEViewController* controller) {
  return false;
}

#pragma mark - FLEViewController implementation.

@implementation FLEViewController {
  FlutterEngine _engine;

  // The additional context provided to the Flutter engine for resource loading.
  NSOpenGLContext* _resourceContext;

  // A mapping of channel names to the registered handlers for those channels.
  NSMutableDictionary<NSString*, FlutterBinaryMessageHandler>* _messageHandlers;

  // The plugin used to handle text input. This is not an FlutterPlugin, so must be owned
  // separately.
  FLETextInputPlugin* _textInputPlugin;

  // A message channel for passing key events to the Flutter engine. This should be replaced with
  // an embedding API; see Issue #47.
  FlutterBasicMessageChannel* _keyEventChannel;

  // A message channel for sending user settings to the flutter engine.
  FlutterBasicMessageChannel* _settingsChannel;

  // A method channel for miscellaneous platform functionality.
  FlutterMethodChannel* _platformChannel;
}

@dynamic view;

/**
 * Performs initialization that's common between the different init paths.
 */
static void CommonInit(FLEViewController* controller) {
  controller->_messageHandlers = [[NSMutableDictionary alloc] init];
  controller->_additionalKeyResponders = [[NSMutableOrderedSet alloc] init];
  controller->_mouseTrackingMode = FlutterMouseTrackingModeInKeyWindow;
}

- (instancetype)initWithCoder:(NSCoder*)coder {
  self = [super initWithCoder:coder];
  if (self != nil) {
    CommonInit(self);
  }
  return self;
}

- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil {
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if (self != nil) {
    CommonInit(self);
  }
  return self;
}

- (void)dealloc {
  if (FlutterEngineShutdown(_engine) == kSuccess) {
    _engine = NULL;
  }
}

- (void)setView:(NSView*)view {
  if (_trackingArea) {
    [self.view removeTrackingArea:_trackingArea];
  }
  [super setView:view];
  [self configureTrackingArea];
}

- (void)loadView {
  self.view = [[FLEView alloc] init];
}

#pragma mark - Public methods

- (void)setMouseTrackingMode:(FlutterMouseTrackingMode)mode {
  if (_mouseTrackingMode == mode) {
    return;
  }
  _mouseTrackingMode = mode;
  [self configureTrackingArea];
}

- (BOOL)launchEngineWithAssetsPath:(NSURL*)assets
              commandLineArguments:(NSArray<NSString*>*)arguments {
  return [self launchEngineInternalWithAssetsPath:assets
                                         headless:NO
                             commandLineArguments:arguments];
}

- (BOOL)launchHeadlessEngineWithAssetsPath:(NSURL*)assets
                      commandLineArguments:(NSArray<NSString*>*)arguments {
  return [self launchEngineInternalWithAssetsPath:assets
                                         headless:YES
                             commandLineArguments:arguments];
}

#pragma mark - Framework-internal methods

- (void)addKeyResponder:(NSResponder*)responder {
  [self.additionalKeyResponders addObject:responder];
}

- (void)removeKeyResponder:(NSResponder*)responder {
  [self.additionalKeyResponders removeObject:responder];
}

#pragma mark - Private methods

- (void)configureTrackingArea {
  if (_mouseTrackingMode != FlutterMouseTrackingModeNone && self.view) {
    NSTrackingAreaOptions options =
        NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingInVisibleRect;
    switch (_mouseTrackingMode) {
      case FlutterMouseTrackingModeInKeyWindow:
        options |= NSTrackingActiveInKeyWindow;
        break;
      case FlutterMouseTrackingModeInActiveApp:
        options |= NSTrackingActiveInActiveApp;
        break;
      case FlutterMouseTrackingModeAlways:
        options |= NSTrackingActiveAlways;
        break;
      default:
        NSLog(@"Error: Unrecognized mouse tracking mode: %ld", _mouseTrackingMode);
        return;
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                 options:options
                                                   owner:self
                                                userInfo:nil];
    [self.view addTrackingArea:_trackingArea];
  } else if (_trackingArea) {
    [self.view removeTrackingArea:_trackingArea];
    _trackingArea = nil;
  }
}

- (void)addInternalPlugins {
  _textInputPlugin = [[FLETextInputPlugin alloc] initWithViewController:self];
  _keyEventChannel =
      [FlutterBasicMessageChannel messageChannelWithName:@"flutter/keyevent"
                                         binaryMessenger:self
                                                   codec:[FlutterJSONMessageCodec sharedInstance]];
  _settingsChannel =
      [FlutterBasicMessageChannel messageChannelWithName:@"flutter/settings"
                                         binaryMessenger:self
                                                   codec:[FlutterJSONMessageCodec sharedInstance]];
  _platformChannel =
      [FlutterMethodChannel methodChannelWithName:@"flutter/platform"
                                  binaryMessenger:self
                                            codec:[FlutterJSONMethodCodec sharedInstance]];
  __weak FLEViewController* weakSelf = self;
  [_platformChannel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [weakSelf handleMethodCall:call result:result];
  }];
}

- (BOOL)launchEngineInternalWithAssetsPath:(NSURL*)assets
                                  headless:(BOOL)headless
                      commandLineArguments:(NSArray<NSString*>*)arguments {
  if (_engine != NULL) {
    return NO;
  }

  // Set up the resource context. This is done here rather than in viewDidLoad as there's no
  // guarantee that viewDidLoad will be called before the engine is started, and the context must
  // be valid by that point.
  [self createResourceContext];

  const FlutterRendererConfig config = [FLEViewController createRenderConfigHeadless:headless];

  // Register internal plugins before starting the engine.
  [self addInternalPlugins];

  // FlutterProjectArgs is expecting a full argv, so when processing it for flags the first
  // item is treated as the executable and ignored. Add a dummy value so that all provided arguments
  // are used.
  const unsigned long argc = arguments.count + 1;
  const char** argv = (const char**)malloc(argc * sizeof(const char*));
  argv[0] = "placeholder";
  for (NSUInteger i = 0; i < arguments.count; ++i) {
    argv[i + 1] = [arguments[i] UTF8String];
  }

  NSString* icuData = [[NSBundle bundleForClass:[self class]] pathForResource:kICUBundlePath
                                                                       ofType:nil];

  FlutterProjectArgs flutterArguments = {};
  flutterArguments.struct_size = sizeof(FlutterProjectArgs);
  flutterArguments.assets_path = assets.fileSystemRepresentation;
  flutterArguments.icu_data_path = icuData.UTF8String;
  flutterArguments.command_line_argc = (int)(argc);
  flutterArguments.command_line_argv = argv;
  flutterArguments.platform_message_callback = (FlutterPlatformMessageCallback)OnPlatformMessage;

  FlutterEngineResult result = FlutterEngineRun(FLUTTER_ENGINE_VERSION, &config, &flutterArguments,
                                                (__bridge void*)(self), &_engine);
  free(argv);
  if (result != kSuccess) {
    NSLog(@"Failed to start Flutter engine: error %d", result);
    return NO;
  }
  // Send the initial user settings such as brightness and text scale factor
  // to the engine.
  [self sendInitialSettings];
  return YES;
}

+ (FlutterRendererConfig)createRenderConfigHeadless:(BOOL)headless {
  if (headless) {
    const FlutterRendererConfig config = {
        .type = kOpenGL,
        .open_gl.struct_size = sizeof(FlutterOpenGLRendererConfig),
        .open_gl.make_current = (BoolCallback)HeadlessOnMakeCurrent,
        .open_gl.clear_current = (BoolCallback)HeadlessOnClearCurrent,
        .open_gl.present = (BoolCallback)HeadlessOnPresent,
        .open_gl.fbo_callback = (UIntCallback)HeadlessOnFBO,
        .open_gl.make_resource_current = (BoolCallback)HeadlessOnMakeResourceCurrent};
    return config;
  } else {
    const FlutterRendererConfig config = {
        .type = kOpenGL,
        .open_gl.struct_size = sizeof(FlutterOpenGLRendererConfig),
        .open_gl.make_current = (BoolCallback)OnMakeCurrent,
        .open_gl.clear_current = (BoolCallback)OnClearCurrent,
        .open_gl.present = (BoolCallback)OnPresent,
        .open_gl.fbo_callback = (UIntCallback)OnFBO,
        .open_gl.make_resource_current = (BoolCallback)OnMakeResourceCurrent};
    return config;
  }
}

- (void)createResourceContext {
  NSOpenGLContext* viewContext = ((NSOpenGLView*)self.view).openGLContext;
  _resourceContext = [[NSOpenGLContext alloc] initWithFormat:viewContext.pixelFormat
                                                shareContext:viewContext];
}

- (void)makeResourceContextCurrent {
  [_resourceContext makeCurrentContext];
}

- (void)handlePlatformMessage:(const FlutterPlatformMessage*)message {
  NSData* messageData = [NSData dataWithBytesNoCopy:(void*)message->message
                                             length:message->message_size
                                       freeWhenDone:NO];
  NSString* channel = @(message->channel);
  __block const FlutterPlatformMessageResponseHandle* responseHandle = message->response_handle;

  FlutterBinaryReply binaryResponseHandler = ^(NSData* response) {
    if (responseHandle) {
      FlutterEngineSendPlatformMessageResponse(self->_engine, responseHandle,
                                               static_cast<const uint8_t*>(response.bytes),
                                               response.length);
      responseHandle = NULL;
    } else {
      NSLog(@"Error: Message responses can be sent only once. Ignoring duplicate response "
             "on channel '%@'.",
            channel);
    }
  };

  FlutterBinaryMessageHandler channelHandler = _messageHandlers[channel];
  if (channelHandler) {
    channelHandler(messageData, binaryResponseHandler);
  } else {
    binaryResponseHandler(nil);
  }
}

- (void)dispatchMouseEvent:(nonnull NSEvent*)event {
  FlutterPointerPhase phase = _mouseState.buttons == 0
                                  ? (_mouseState.flutter_state_is_down ? kUp : kHover)
                                  : (_mouseState.flutter_state_is_down ? kMove : kDown);
  [self dispatchMouseEvent:event phase:phase];
}

- (void)dispatchMouseEvent:(NSEvent*)event phase:(FlutterPointerPhase)phase {
  // There are edge cases where the system will deliver enter out of order relative to other
  // events (e.g., drag out and back in, release, then click; mouseDown: will be called before
  // mouseEntered:). Discard those events, since the add will already have been synthesized.
  if (_mouseState.flutter_state_is_added && phase == kAdd) {
    return;
  }

  // If a pointer added event hasn't been sent, synthesize one using this event for the basic
  // information.
  if (!_mouseState.flutter_state_is_added && phase != kAdd) {
    // Only the values extracted for use in flutterEvent below matter, the rest are dummy values.
    NSEvent* addEvent = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered
                                               location:event.locationInWindow
                                          modifierFlags:0
                                              timestamp:event.timestamp
                                           windowNumber:event.windowNumber
                                                context:nil
                                            eventNumber:0
                                         trackingNumber:0
                                               userData:NULL];
    [self dispatchMouseEvent:addEvent phase:kAdd];
  }

  NSPoint locationInView = [self.view convertPoint:event.locationInWindow fromView:nil];
  NSPoint locationInBackingCoordinates = [self.view convertPointToBacking:locationInView];
  FlutterPointerEvent flutterEvent = {
      .struct_size = sizeof(flutterEvent),
      .device_kind = kFlutterPointerDeviceKindMouse,
      .phase = phase,
      .x = locationInBackingCoordinates.x,
      .y = -locationInBackingCoordinates.y,  // convertPointToBacking makes this negative.
      .timestamp = static_cast<size_t>(event.timestamp * NSEC_PER_MSEC),
      // If a click triggered a synthesized kAdd, don't pass the buttons in that event.
      .buttons = phase == kAdd ? 0 : _mouseState.buttons,
  };

  if (event.type == NSEventTypeScrollWheel) {
    flutterEvent.signal_kind = kFlutterPointerSignalKindScroll;

    double pixelsPerLine = 1.0;
    if (!event.hasPreciseScrollingDeltas) {
      CGEventSourceRef source = CGEventCreateSourceFromEvent(event.CGEvent);
      pixelsPerLine = CGEventSourceGetPixelsPerLine(source);
      if (source) {
        CFRelease(source);
      }
    }
    double scaleFactor = self.view.layer.contentsScale;
    flutterEvent.scroll_delta_x = -event.scrollingDeltaX * pixelsPerLine * scaleFactor;
    flutterEvent.scroll_delta_y = -event.scrollingDeltaY * pixelsPerLine * scaleFactor;
  }
  FlutterEngineSendPointerEvent(_engine, &flutterEvent, 1);

  // Update tracking of state as reported to Flutter.
  if (phase == kDown) {
    _mouseState.flutter_state_is_down = true;
  } else if (phase == kUp) {
    _mouseState.flutter_state_is_down = false;
    if (_mouseState.has_pending_exit) {
      [self dispatchMouseEvent:event phase:kRemove];
      _mouseState.has_pending_exit = false;
    }
  } else if (phase == kAdd) {
    _mouseState.flutter_state_is_added = true;
  } else if (phase == kRemove) {
    _mouseState.Reset();
  }
}

- (void)dispatchKeyEvent:(NSEvent*)event ofType:(NSString*)type {
  [_keyEventChannel sendMessage:@{
    @"keymap" : @"macos",
    @"type" : type,
    @"keyCode" : @(event.keyCode),
    @"modifiers" : @(event.modifierFlags),
    @"characters" : event.characters,
    @"charactersIgnoringModifiers" : event.charactersIgnoringModifiers,
  }];
}

- (void)onSettingsChanged:(NSNotification*)notification {
  // TODO(jonahwilliams): https://github.com/flutter/flutter/issues/32015.
  NSString* brightness =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
  [_settingsChannel sendMessage:@{
    @"platformBrightness" : [brightness isEqualToString:@"Dark"] ? @"dark" : @"light",
    // TODO(jonahwilliams): https://github.com/flutter/flutter/issues/32006.
    @"textScaleFactor" : @1.0,
    @"alwaysUse24HourFormat" : @false
  }];
}

- (void)sendInitialSettings {
  // TODO(jonahwilliams): https://github.com/flutter/flutter/issues/32015.
  [[NSDistributedNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(onSettingsChanged:)
             name:@"AppleInterfaceThemeChangedNotification"
           object:nil];
  [self onSettingsChanged:nil];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"SystemNavigator.pop"]) {
    [NSApp terminate:self];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - FLEReshapeListener

/**
 * Responds to view reshape by notifying the engine of the change in dimensions.
 */
- (void)viewDidReshape:(NSOpenGLView*)view {
  CGRect scaledBounds = [view convertRectToBacking:view.bounds];
  const FlutterWindowMetricsEvent event = {
      .struct_size = sizeof(event),
      .width = static_cast<size_t>(scaledBounds.size.width),
      .height = static_cast<size_t>(scaledBounds.size.height),
      .pixel_ratio = scaledBounds.size.width / view.bounds.size.width,
  };
  FlutterEngineSendWindowMetricsEvent(_engine, &event);
}

#pragma mark - FlutterBinaryMessenger

- (void)sendOnChannel:(nonnull NSString*)channel message:(nullable NSData*)message {
  FlutterPlatformMessage platformMessage = {
      .struct_size = sizeof(FlutterPlatformMessage),
      .channel = [channel UTF8String],
      .message = static_cast<const uint8_t*>(message.bytes),
      .message_size = message.length,
  };

  FlutterEngineResult result = FlutterEngineSendPlatformMessage(_engine, &platformMessage);
  if (result != kSuccess) {
    NSLog(@"Failed to send message to Flutter engine on channel '%@' (%d).", channel, result);
  }
}

- (void)setMessageHandlerOnChannel:(nonnull NSString*)channel
              binaryMessageHandler:(nullable FlutterBinaryMessageHandler)handler {
  _messageHandlers[channel] = [handler copy];
}

#pragma mark - FlutterPluginRegistrar

- (id<FlutterBinaryMessenger>)messenger {
  return self;
}

- (void)addMethodCallDelegate:(nonnull id<FlutterPlugin>)delegate
                      channel:(nonnull FlutterMethodChannel*)channel {
  [channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [delegate handleMethodCall:call result:result];
  }];
}

#pragma mark - FlutterPluginRegistry

- (id<FlutterPluginRegistrar>)registrarForPlugin:(NSString*)pluginName {
  // Currently, the view controller acts as the registrar for all plugins, so the
  // name is ignored.
  return self;
}

#pragma mark - NSResponder

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)keyDown:(NSEvent*)event {
  [self dispatchKeyEvent:event ofType:@"keydown"];
  for (NSResponder* responder in self.additionalKeyResponders) {
    if ([responder respondsToSelector:@selector(keyDown:)]) {
      [responder keyDown:event];
    }
  }
}

- (void)keyUp:(NSEvent*)event {
  [self dispatchKeyEvent:event ofType:@"keyup"];
  for (NSResponder* responder in self.additionalKeyResponders) {
    if ([responder respondsToSelector:@selector(keyUp:)]) {
      [responder keyUp:event];
    }
  }
}

- (void)mouseEntered:(NSEvent*)event {
  [self dispatchMouseEvent:event phase:kAdd];
}

- (void)mouseExited:(NSEvent*)event {
  if (_mouseState.buttons != 0) {
    _mouseState.has_pending_exit = true;
    return;
  }
  [self dispatchMouseEvent:event phase:kRemove];
}

- (void)mouseDown:(NSEvent*)event {
  _mouseState.buttons |= kFlutterPointerButtonMousePrimary;
  [self dispatchMouseEvent:event];
}

- (void)mouseUp:(NSEvent*)event {
  _mouseState.buttons &= ~static_cast<uint64_t>(kFlutterPointerButtonMousePrimary);
  [self dispatchMouseEvent:event];
}

- (void)mouseDragged:(NSEvent*)event {
  [self dispatchMouseEvent:event];
}

- (void)rightMouseDown:(NSEvent*)event {
  _mouseState.buttons |= kFlutterPointerButtonMouseSecondary;
  [self dispatchMouseEvent:event];
}

- (void)rightMouseUp:(NSEvent*)event {
  _mouseState.buttons &= ~static_cast<uint64_t>(kFlutterPointerButtonMouseSecondary);
  [self dispatchMouseEvent:event];
}

- (void)rightMouseDragged:(NSEvent*)event {
  [self dispatchMouseEvent:event];
}

- (void)otherMouseDown:(NSEvent*)event {
  _mouseState.buttons |= (1 << event.buttonNumber);
  [self dispatchMouseEvent:event];
}

- (void)otherMouseUp:(NSEvent*)event {
  _mouseState.buttons &= ~static_cast<uint64_t>(1 << event.buttonNumber);
  [self dispatchMouseEvent:event];
}

- (void)otherMouseDragged:(NSEvent*)event {
  [self dispatchMouseEvent:event];
}

- (void)mouseMoved:(NSEvent*)event {
  [self dispatchMouseEvent:event];
}

- (void)scrollWheel:(NSEvent*)event {
  // TODO: Add gesture-based (trackpad) scroll support once it's supported by the engine rather
  // than always using kHover.
  [self dispatchMouseEvent:event phase:kHover];
}

@end
