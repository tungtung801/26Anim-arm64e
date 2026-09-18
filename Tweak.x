/*****************************************************************************************
 *  26Anim (com.tungtung801.26anim) v0.0.3
 *  iOS 26 app open/close genie animation for SpringBoard (roothide build).
 *
 *  ARCHITECTURE — deliberately minimal, "piggyback" on the native transition:
 *
 *    · SpringBoard owns the zoom: it scales SBFullscreenZoomView icon→screen
 *      (or screen→icon) exactly as it always does. We NEVER touch frame,
 *      transform, opacity, animations or layout of that view.
 *    · Every frame we READ the native progress from the view's
 *      presentationLayer (scale ratio) — SpringBoard native timing, not ours.
 *    · We ONLY WRITE `layer.meshTransform` — a property the stock flow never
 *      uses — with an anchor-driven, edge-aware genie warp. Because we only
 *      ever add a deformation that is zero at both endpoints, the stock
 *      animation cannot break, and open/close are exact inverses of the
 *      same field (progress is "how open" in both directions).
 *    · The anchor (tapped icon) is converted to layer space ONCE, up front;
 *      nothing is ever re-read from the transformed layer → no feedback loop.
 *
 *  Mesh density matches the original 26Anim 1.0.3: 5×5 vertices / 16 faces
 *  (CreateBulgedMesh produced 0x19 vertices / 0x10 faces).
 *  Warp math follows the anchor-driven model: strong pull toward the icon
 *  with distance falloff + edge amplification, continuous opposite edge.
 ****************************************************************************************/

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

/* ------------------------------------------------------------------ */
/* Private API                                                         */
/* ------------------------------------------------------------------ */

/* CAMeshVertex = { CGPoint from; CAPoint3D to; } → 5 floats per vertex.
   Faces are quads: unsigned indices[4] + float weights[4] (w = 1.0). */
@interface CAMeshTransform : NSObject
+ (instancetype)meshTransformWithVertexCount:(NSUInteger)vertexCount
                                    vertices:(const float *)vertices
                                   faceCount:(NSUInteger)faceCount
                                       faces:(const unsigned int *)faces
                          depthNormalization:(NSString *)depthNormalization;
@end

@interface CALayer (Anim26)
@property (nonatomic, retain) CAMeshTransform *meshTransform;
@end

@interface SBIconView : UIView @end
@interface SBFullscreenZoomView : UIView @end

/* ------------------------------------------------------------------ */
/* Prefs                                                               */
/* ------------------------------------------------------------------ */

#define kPrefsID      @"com.tungtung801.26anim"
#define kDarwinNotify @"com.tungtung801.26anim/settingschanged"

static BOOL       prefEnabled      = YES;
static NSInteger  prefAnimSpeed    = 1;   /* 0 = native only, 1 = iOS 26 warp */
static double     prefWarpStrength = 1.0; /* 0..2 warp amplitude multiplier   */
static NSInteger  prefMeshMode     = 1;   /* 0 off, 1 normal, 2 swapped uv    */

static id Anim26PrefValue(NSString *key) {
    CFPreferencesAppSynchronize((CFStringRef)kPrefsID);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)key,
                                                       (CFStringRef)kPrefsID));
    if (v) return v;
    static NSArray *cands;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cands = @[
            @"/var/jb/var/mobile/Library/Preferences/com.tungtung801.26anim.plist",
            @"/var/mobile/Library/Preferences/com.tungtung801.26anim.plist",
            @"/var/jb/var/root/Library/Preferences/com.tungtung801.26anim.plist",
            @"/var/root/Library/Preferences/com.tungtung801.26anim.plist"
        ];
    });
    for (NSString *path in cands) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        id o = d[key];
        if (o) return o;
    }
    return nil;
}

static void LoadPrefs(void) {
    NSNumber *b = (NSNumber *)Anim26PrefValue(@"enabled");
    if ([b isKindOfClass:[NSNumber class]]) prefEnabled = [b boolValue];
    NSNumber *n = (NSNumber *)Anim26PrefValue(@"animSpeed");
    if ([n isKindOfClass:[NSNumber class]]) prefAnimSpeed = [n integerValue];
    NSNumber *w = (NSNumber *)Anim26PrefValue(@"warpStrength");
    if ([w isKindOfClass:[NSNumber class]]) prefWarpStrength = [w doubleValue];
    NSNumber *m = (NSNumber *)Anim26PrefValue(@"meshMode");
    if ([m isKindOfClass:[NSNumber class]]) prefMeshMode = [m integerValue];
    prefWarpStrength = fmax(0.0, fmin(2.0, prefWarpStrength));
}

/* ------------------------------------------------------------------ */
/* Icon anchor — captured once, in window coordinates, then normalized */
/* ------------------------------------------------------------------ */

typedef struct {
    BOOL    valid;
    CGPoint center;   /* window coords */
    CGSize  size;     /* window coords */
    CFTimeInterval tapTime;
} IconAnchor;

static IconAnchor gAnchor, gLastAnchor;

/* Native-transition timestamps (role of the original's
   _lastHomeTransitionTime): lets us tell a real close-to-home or app
   launch apart from App Switcher / unrelated snapshot views. */
static CFTimeInterval g_homeTransitionAt = -1e9;
static CFTimeInterval g_appActivateAt    = -1e9;

/* ------------------------------------------------------------------ */
/* Small math                                                          */
/* ------------------------------------------------------------------ */

#define kPi 3.14159265358979323846

static inline float clampf(float v, float lo, float hi) {
    return fminf(fmaxf(v, lo), hi);
}

static inline float smoothstepf(float e0, float e1, float x) {
    float t = clampf((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/* ------------------------------------------------------------------ */
/* Genie mesh builder — anchor-driven warp (5×5, like the original).   *
 *                                                                     *
 * Mesh lives in the layer's unit square. p = native progress          *
 * (0 = icon, 1 = fullscreen) — identical field for open & close.      *
 * warpAmp = sin(π p) → deformation is zero at both endpoints, so the  *
 * stock zoom is never distorted at hand-off.                          *
 *                                                                     *
 * Per vertex (user-space formula, normalized coords):                 *
 *   dx,dy  = anchor − vertex                                          *
 *   dist   = |d|                pull = smoothstep(0, 0.90, dist)      *
 *   strength = (1 − pull)² · warpAmp   ← strong near the icon         *
 *   edgeFactor amplifies the edge nearest the icon (dock/top),        *
 *   `opposite` keeps the far edge continuous (no broken top edge).    *
 * ------------------------------------------------------------------ */

#define kMeshN 5   /* 5×5 vertices → 36 verts, 25 faces (original: 25v/16f) */

static CAMeshTransform *BuildGenieMesh(CGPoint anchorN, double p, double warpAmp) {
    static float        verts[(kMeshN + 1) * (kMeshN + 1) * 5];
    static unsigned int faces[kMeshN * kMeshN * 8];
    static BOOL         facesBuilt = NO;

    const int N = kMeshN;
    const int V = (N + 1) * (N + 1);

    float ax = (float)anchorN.x;
    float ay = (float)anchorN.y;
    float amp = (float)warpAmp;

    int vi = 0;
    for (int j = 0; j <= N; j++) {
        for (int i = 0; i <= N; i++, vi++) {
            float u = (float)i / N;
            float v = (float)j / N;

            float dx = ax - u;
            float dy = ay - v;
            float dist = sqrtf(dx * dx + dy * dy);

            float pull = smoothstepf(0.0f, 0.90f, dist);
            float strength = powf(1.0f - pull, 2.0f) * amp;

            float len = fmaxf(dist, 0.0001f);
            float nx = dx / len;
            float ny = dy / len;

            /* edge amplification: the edge the icon sits on moves more */
            float top    = 1.0f - v;
            float bottom = v;
            float edgeFactor = (ay < 0.5f) ? (0.60f + top * 0.85f)
                                           : (0.60f + bottom * 0.85f);

            float pullX = nx * strength * edgeFactor * 0.42f;
            float pullY = ny * strength * edgeFactor * 0.70f;

            /* keep the opposite edge continuous */
            float opposite = smoothstepf(0.0f, 0.45f, (ay < 0.5f) ? v : 1.0f - v);
            pullY *= (0.35f + 0.65f * opposite);

            float tx = u + pullX;
            float ty = v + pullY;

            if (prefMeshMode == 2) {
                /* swapped from/to — escape hatch for iOS builds whose
                   CAMeshVertex semantics differ */
                verts[vi * 5 + 0] = tx;
                verts[vi * 5 + 1] = ty;
                verts[vi * 5 + 2] = u;
                verts[vi * 5 + 3] = v;
            } else {
                verts[vi * 5 + 0] = u;   /* from.x */
                verts[vi * 5 + 1] = v;   /* from.y */
                verts[vi * 5 + 2] = tx;  /* to.x   */
                verts[vi * 5 + 3] = ty;  /* to.y   */
            }
            verts[vi * 5 + 4] = 0.0f;    /* to.z   */
        }
    }

    if (!facesBuilt) {
        int fi = 0;
        for (int j = 0; j < N; j++) {
            for (int i = 0; i < N; i++) {
                unsigned int a = j * (N + 1) + i;
                unsigned int b = a + 1;
                unsigned int c = a + (N + 1);
                unsigned int d = c + 1;
                faces[fi++] = a; faces[fi++] = b; faces[fi++] = d; faces[fi++] = c;
                faces[fi++] = 0x3F800000; faces[fi++] = 0x3F800000;
                faces[fi++] = 0x3F800000; faces[fi++] = 0x3F800000; /* w = 1.0f */
            }
        }
        facesBuilt = YES;
    }

    Class meshClass = NSClassFromString(@"CAMeshTransform");
    if (!meshClass) return nil;
    return [meshClass meshTransformWithVertexCount:V
                                          vertices:verts
                                         faceCount:N * N
                                             faces:faces
                                depthNormalization:nil];
}

/* ------------------------------------------------------------------ */
/* Driver — reads native progress, writes ONLY meshTransform           */
/* ------------------------------------------------------------------ */

@interface AN26Driver : NSObject
- (instancetype)initWithView:(UIView *)view
                    iconRect:(CGRect)iconRect;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, weak)   UIView         *attachedView;
@end

static AN26Driver *gCurrentDriver = nil;

@implementation AN26Driver {
    CGPoint         _anchorN;    /* icon center normalized to the screen  */
    CGFloat         _iconRatio;  /* iconWidth / screenWidth (stock start) */
    CGSize          _screen;
    double          _lastP;
    CFTimeInterval  _lastMove;
    CFTimeInterval  _elapsed;
    BOOL            _hasStarted;
}

- (instancetype)initWithView:(UIView *)view
                    iconRect:(CGRect)iconRect {
    if ((self = [super init])) {
        self.attachedView = view;
        _screen  = [UIScreen mainScreen].bounds.size;
        if (_screen.width < 8 || _screen.height < 8)
            _screen = view.window.bounds.size;

        _anchorN = CGPointMake(clampf(iconRect.origin.x + iconRect.size.width  / 2.0, 0.03, 0.97) / _screen.width,
                               clampf(iconRect.origin.y + iconRect.size.height / 2.0, 0.03, 0.97) / _screen.height);
        _iconRatio = clampf(iconRect.size.width / fmaxf(1.0f, (float)_screen.width), 0.02f, 0.60f);

        _lastP = -1.0;
        _lastMove = CACurrentMediaTime();

        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        self.displayLink.preferredFramesPerSecond = 120;
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)tick:(CADisplayLink *)link {
    UIView *view = self.attachedView;
    CALayer *layer = view.layer;
    if (!view.window || !layer) { [self finish]; return; }

    CFTimeInterval now = CACurrentMediaTime();
    if (!_hasStarted) { _hasStarted = YES; _lastMove = now; }
    _elapsed = now - _lastMove;
    if (_elapsed > 2.5) { [self finish]; return; }

    /* ---- native progress: read the presentation, never the model ------- */
    CALayer *pres = [layer presentationLayer];
    if (!pres) return;
    CGRect pf = pres.frame;
    CGRect b  = layer.bounds;
    if (b.size.width < 8 || pf.size.width < 0.5) return;

    CGFloat s = pf.size.width / b.size.width;      /* current stock scale */
    s = clampf(s, 0.0f, 2.0f);
    double p = (_iconRatio >= 0.999) ? 1.0 : (double)((s - (float)_iconRatio) / (1.0f - (float)_iconRatio));
    p = fmax(0.0, fmin(1.0, p));

    /* ---- stall detection: stock flow finished → release everything ----- */
    if (fabs(p - _lastP) > 0.002) { _lastP = p; _lastMove = now; }
    else if (_elapsed > 0.5 && (now - _lastMove) > 0.35) { [self finish]; return; }

    /* ---- write ONLY meshTransform (never animated by stock) ------------ */
    double warpAmp = prefWarpStrength * sin(kPi * p);   /* 0 at both ends */

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (warpAmp > 0.004 && prefMeshMode != 0) {
        @try {
            CAMeshTransform *mesh = BuildGenieMesh(_anchorN, p, warpAmp);
            if (mesh) layer.meshTransform = mesh;
        }
        @catch (NSException *e) {
            layer.meshTransform = nil;
            prefMeshMode = 0;                    /* degrade to pure stock */
        }
    } else {
        layer.meshTransform = nil;
    }
    [CATransaction commit];
}

- (void)finish {
    [self.displayLink invalidate];
    self.displayLink = nil;

    UIView *view = self.attachedView;
    if (view.layer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        view.layer.meshTransform = nil;          /* hand back a clean layer */
        [CATransaction commit];
    }
    if (gCurrentDriver == self) gCurrentDriver = nil;
}

@end

/* ------------------------------------------------------------------ */
/* Hooks                                                               */
/* ------------------------------------------------------------------ */

%group Core

/* Record the tapped icon (window coords). This is our transition anchor. */
%hook SBIconView
- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    if (!highlighted) return;
    UIView *v = (UIView *)self;
    CGRect r = [v convertRect:v.bounds toView:nil];
    if (r.size.width < 8 || r.size.height < 8) return;
    gAnchor.valid    = YES;
    gAnchor.center   = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    gAnchor.size     = r.size;
    gAnchor.tapTime  = CACurrentMediaTime();
    gLastAnchor      = gAnchor;
}
%end

/* Attach the warp driver when SpringBoard creates the fullscreen zoom view.
   We only *add* a mesh on top of the native animation; any ambiguity here
   simply leaves the stock transition untouched. */
%hook SBFullscreenZoomView
- (void)didMoveToWindow {
    %orig;

    if (!prefEnabled || prefAnimSpeed != 1) return;
    if (gCurrentDriver) return;

    UIView *selfView = (UIView *)self;
    if (!selfView.window) return;

    CGRect bounds = selfView.bounds;
    CGSize ss = selfView.window.bounds.size;
    BOOL looksFullscreen = bounds.size.width >= ss.width * 0.90
                        && bounds.size.height >= ss.height * 0.90;

    /* Direction gating via native signals (mirrors the original's
       _hasTappedIcon + _lastHomeTransitionTime): */
    CFTimeInterval now = CACurrentMediaTime();
    BOOL recentTap = gAnchor.valid && (now - gAnchor.tapTime) < 0.9;
    BOOL freshOpen = (now - g_appActivateAt)    < 1.0;
    BOOL freshHome = (now - g_homeTransitionAt) < 2.0;

    if (!(recentTap || freshOpen || (freshHome && looksFullscreen)))
        return;                              /* ambiguous → stock wins */

    /* anchor for this transition (tap icon, else last icon, else dock) */
    IconAnchor a = gAnchor.valid ? gAnchor : gLastAnchor;
    if (!a.valid) {
        a.valid = YES;
        a.size = CGSizeMake(60, 60);
        a.center = CGPointMake(ss.width / 2.0, ss.height - 44 - 30);
    }
    a.center.x = fminf(fmaxf(a.center.x, 30), ss.width  - 30);
    a.center.y = fminf(fmaxf(a.center.y, 30), ss.height - 30);
    if (a.size.width < 8) a.size = CGSizeMake(60, 60);

    CGRect iconRect = CGRectMake(a.center.x - a.size.width / 2.0,
                                 a.center.y - a.size.height / 2.0,
                                 a.size.width, a.size.height);

    gCurrentDriver = [[AN26Driver alloc] initWithView:selfView
                                             iconRect:iconRect];
}
%end

%end /* group Core */

/* ------------------------------------------------------------------ */
/* Optional transition-signal hook — installed manually + nil-safe so a
   missing class on some iOS build is a clean no-op.                   */
/* ------------------------------------------------------------------ */

static void (*_orig_WSReq_setEventLabel)(id, SEL, NSString *);

static void _hook_WSReq_setEventLabel(id self, SEL _cmd, NSString *label) {
    if (_orig_WSReq_setEventLabel)
        _orig_WSReq_setEventLabel(self, _cmd, label);
    if (![label isKindOfClass:[NSString class]]) return;
    NSString *l = [label lowercaseString];
    CFTimeInterval now = CACurrentMediaTime();
    if ([l containsString:@"home"])        g_homeTransitionAt = now;
    if ([l containsString:@"activate"] || [l containsString:@"launch"])
                                           g_appActivateAt = now;
}

/* ------------------------------------------------------------------ */
/* Init                                                                */
/* ------------------------------------------------------------------ */

static void PrefsChangedCallback(CFNotificationCenterRef center,
                                 void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    LoadPrefs();
}

%ctor {
    LoadPrefs();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    &PrefsChangedCallback,
                                    (CFStringRef)kDarwinNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    %init(Core);

    Class wsReq = NSClassFromString(@"SBMainWorkspaceTransitionRequest");
    if (wsReq) {
        MSHookMessageEx(wsReq,
                        @selector(setEventLabel:),
                        (IMP)&_hook_WSReq_setEventLabel,
                        (IMP *)&_orig_WSReq_setEventLabel);
    }
}
