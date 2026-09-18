/*****************************************************************************************
 *  26Anim 2 — iOS 26 app open/close animation for older iOS (SpringBoard tweak)
 *
 *  Rebuild & improvement of ngkhoi's original 26Anim (v1.0.3).
 *
 *  What the real iOS 26 (Beta 6+) transition does, and what we replicate here:
 *
 *   1. NON-UNIFORM "GENIE / APERTURE" WARP — the app surface does NOT scale uniformly.
 *      It expands from / contracts into the Home Screen icon with an edge warp whose
 *      strength is driven by the icon's position: the window edge nearest the icon moves
 *      ahead of the far edge, producing the characteristic "membrane pulled toward the
 *      icon" look. Implemented with the private CAMeshTransform API (same engine the
 *      original tweak used), rebuilt every frame on a 120 Hz CADisplayLink.
 *
 *   2. FAST SPRING WITH A VERY LIGHT BOUNCE — both directions settle quickly with a tiny
 *      overshoot. We read Apple's own transition spring parameters at runtime
 *      (homeGesture*Zoom*Settings / switcherToHomeSettings: -response, -dampingRatio)
 *      exactly like the original tweak did, and fall back to tuned constants.
 *
 *   3. CONTINUOUS CORNER MORPH — the window corners interpolate between the Home Screen
 *      icon corner radius and the display corner radius (kCACornerCurveContinuous), so
 *      the shrinking window visually "becomes" the icon.
 *
 *   4. NO HARD SNAP — the zoom view cross-fades over the first/last ~12 % of the
 *      transition so the surface hand-off to/from the real app snapshot is invisible.
 *
 *   5. HOME GRABBERS FADE — the page grabber views fade with the transition.
 *
 *  Prefs (com.tungtung801.26anim):
 *      enabled       BOOL   master switch (default YES)
 *      animSpeed     INT    0 = original iOS native animation, 1 = iOS 26 style
 *      warpStrength  DOUBLE 0.0 – 2.0, multiplier on the genie warp (default 1.0)
 *      speedFactor   DOUBLE 0.5 – 2.0, multiplies spring response (default 1.0)
 *
 *  Jailbreak compatibility:
 *      - RootHide Bootstrap (rootless /var/jb)  — build THEOS_PACKAGE_SCHEME=rootless
 *      - Dopamine / palera1n rootless           — same rootless deb
 *      - unc0ver / palera1n rootful             — rootful deb
 *      Prefs are read via CFPreferences with a direct-plist fallback across
 *      /var/jb/var/mobile, /var/mobile and /var/root so settings always load.
 *****************************************************************************************/

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

/* ------------------------------------------------------------------ */
/* Private API surface (resolved at runtime — never link directly)     */
/* ------------------------------------------------------------------ */

/* Private CoreAnimation mesh warp (exact layout per cleaned runtime headers):
     typedef struct { CGPoint from; CAPoint3D to; } CAMeshVertex;   // 5 floats
     typedef struct { unsigned int indices[4]; float w[4]; } CAMeshFace;  // quad
   `to` is normalized against layer bounds, `from` is texture UV in [0,1]. */
@interface CAMeshTransform : NSObject
+ (instancetype)meshTransformWithVertexCount:(NSUInteger)vertexCount
                                    vertices:(const float *)vertices
                                   faceCount:(NSUInteger)faceCount
                                       faces:(const unsigned int *)faces
                          depthNormalization:(NSString *)depthNormalization;
@end

@interface UIScreen (Anim26)
- (CGFloat)_displayCornerRadius;
@end

@interface CALayer (Anim26)
@property (nonatomic, retain) CAMeshTransform *meshTransform;
@end

/* SpringBoard classes we hook (declared so logos hooks compile cleanly) */
@interface SBIconView : UIView @end
@interface SBFullscreenZoomView : UIView @end
@interface SBHomeGrabberView : UIView @end

/* Apple's transition spring settings objects inside SpringBoard.
   They are only used as a *source of parameters*; absence is fine.
   (Accessed with objc_msgSend casts — no compile-time property.)   */

/* ------------------------------------------------------------------ */
/* Tunables / defaults                                                 */
/* ------------------------------------------------------------------ */

#define kPrefsID            @"com.tungtung801.26anim"
#define kDarwinNotify       @"com.tungtung801.26anim/settingschanged"

/* Fallback spring parameters when Apple's settings can't be read.
   Chosen to match the iOS 26 feel: fast, damping just under critical
   so there is a very small single overshoot ("bounce rất nhẹ"). */
static const double kFallbackOpenResponse  = 0.38;
static const double kFallbackOpenDamping   = 0.90;
static const double kFallbackCloseResponse = 0.42;
static const double kFallbackCloseDamping  = 0.88;

/* Warp shaping */
static const double kPi = 3.14159265358979323846;

/* Mesh resolution — 14×14 quads (225 vertices, 392 triangles).
   High enough for smooth edges, cheap enough to rebuild at 120 Hz. */
#define kMeshN 14

/* ------------------------------------------------------------------ */
/* Preferences                                                         */
/* ------------------------------------------------------------------ */

static BOOL   prefEnabled      = YES;
static NSInteger prefAnimSpeed = 1;      // 0 = native, 1 = iOS 26
static double prefWarpStrength = 1.0;
static double prefSpeedFactor  = 1.0;
static NSInteger prefMeshMode  = 1;      // 0 = mesh off (zoom fallback), 1 = mesh on, 2 = mesh swapped

/* Read one pref value — CFPreferences first, then manual plist read.
   The manual fallback mirrors the original tweak's approach and makes the
   tweak robust on every jailbreak scheme: RootHide /var/jb rootless,
   rootless Dopamine, rootful unc0ver/palera1n and /var/root defaults.
   (cfprefsd on jailbreaks occasionally serves stale values after a
   Darwin notification; reading the file directly avoids that.) */
static id Anim26PrefValue(NSString *key) {
    CFPreferencesAppSynchronize((CFStringRef)kPrefsID);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)key,
                                                       (CFStringRef)kPrefsID));
    if (v) return v;

    static NSArray *cands;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cands = @[
            @"/var/jb/var/mobile/Library/Preferences/com.tungtung801.26anim.plist", /* RootHide / rootless */
            @"/var/mobile/Library/Preferences/com.tungtung801.26anim.plist",        /* rootful             */
            @"/var/jb/var/root/Library/Preferences/com.tungtung801.26anim.plist",
            @"/var/root/Library/Preferences/com.tungtung801.26anim.plist"           /* root defaults       */
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

    NSNumber *num = (NSNumber *)Anim26PrefValue(@"warpStrength");
    if ([num isKindOfClass:[NSNumber class]]) prefWarpStrength = [num doubleValue];
    num = (NSNumber *)Anim26PrefValue(@"speedFactor");
    if ([num isKindOfClass:[NSNumber class]]) prefSpeedFactor = [num doubleValue];
    num = (NSNumber *)Anim26PrefValue(@"meshMode");
    if ([num isKindOfClass:[NSNumber class]]) prefMeshMode = [num integerValue];

    prefWarpStrength = fmax(0.0, fmin(2.0, prefWarpStrength));
    prefSpeedFactor  = fmax(0.4, fmin(2.5, prefSpeedFactor));
}

/* ------------------------------------------------------------------ */
/* Icon anchor — where the transition expands from / contracts into    */
/* ------------------------------------------------------------------ */

typedef struct {
    BOOL      valid;          /* we have a usable anchor                     */
    CGPoint   center;         /* icon center in window coordinates           */
    CGSize    size;           /* icon size in points                         */
    CGFloat   cornerRadius;   /* icon corner radius in points                */
    CFTimeInterval tapTime;   /* when the tap was recorded                   */
} IconAnchor;

static IconAnchor gAnchor = { NO, {0, 0}, {60, 60}, 13.0, 0 };
static IconAnchor gLastAnchor = { NO, {0, 0}, {60, 60}, 13.0, 0 };

/* ------------------------------------------------------------------ */
/* Geometry helpers                                                    */
/* ------------------------------------------------------------------ */

static CGFloat ScreenCornerRadius(void) {
    CGFloat r = 0;
    if ([[UIScreen mainScreen] respondsToSelector:@selector(_displayCornerRadius)])
        r = [[UIScreen mainScreen] _displayCornerRadius];
    if (r <= 0) {
        CGSize s = [UIScreen mainScreen].bounds.size;
        CGFloat m = fmin(s.width, s.height);
        r = m * 0.060;            // reasonable default across devices
        if (m > 420) r = 55;      // Pro Max class
        else if (m > 390) r = 55;
        else r = 47;
    }
    return r;
}

/* direction from a to b */
static CGPoint NormDir(CGPoint a, CGPoint b) {
    CGFloat dx = b.x - a.x, dy = b.y - a.y;
    CGFloat l = sqrt(dx * dx + dy * dy);
    if (l < 0.0001) return CGPointMake(0, 0);
    return CGPointMake(dx / l, dy / l);
}

/* ------------------------------------------------------------------ */
/* Spring — critically-damped-family semi-implicit integrator.
 * Equivalent to Apple's UISpringTimingParameters(response:damping:)
 * model:  x''(t) = -k (x(t) - target) - c x'(t)
 *   k = (2π / response)²        c = 2 * dampingRatio * sqrt(k)
 * Integrated at display-link rate → frame-accurate, gesture-independent.
 * ------------------------------------------------------------------ */

typedef struct {
    double value, velocity;
    double target;
    double omega;     /* 2π / response  */
    double zeta;      /* damping ratio  */
} Spring;

static void SpringInit(Spring *s, double value, double response, double damping) {
    s->value = value; s->velocity = 0; s->target = 1.0;
    s->omega = (2.0 * kPi) / fmax(0.05, response);
    s->zeta = fmax(0.1, fmin(1.2, damping));
}

static BOOL SpringStep(Spring *s, double dt) {
    /* semi-implicit Euler; clamp dt to survive hiccups / backgrounding */
    if (dt <= 0) dt = 1.0 / 120.0;
    if (dt > 0.05) dt = 0.05;
    double k = s->omega * s->omega;
    double c = 2.0 * s->zeta * s->omega;
    double a = -k * (s->value - s->target) - c * s->velocity;
    s->velocity += a * dt;
    s->value    += s->velocity * dt;
    double err = fabs(s->value - s->target);
    double spd = fabs(s->velocity);
    return (err < 0.0008 && spd < 0.0025);   /* settled */
}

/* ------------------------------------------------------------------ */
/* Read Apple's real transition springs (like the original tweak did)  */
/* ------------------------------------------------------------------ */

static double AppleResponse(BOOL opening) {
    double out = 0;
    Class c = NSClassFromString(@"_UIAnimationSettingsFactory");
    if (!c) return 0;
    SEL sel = opening ? NSSelectorFromString(@"homeGestureCenterRowZoomUpSettings")
                      : NSSelectorFromString(@"iconZoomDownSettings");
    if (![c respondsToSelector:sel]) {
        sel = opening ? NSSelectorFromString(@"homeGestureEdgeRowZoomUpSettings")
                      : NSSelectorFromString(@"switcherToHomeSettings");
        if (![c respondsToSelector:sel]) return 0;
    }
    id settings = ((id (*)(id, SEL))objc_msgSend)(c, sel);
    if (!settings || ![(NSObject *)settings respondsToSelector:@selector(response)]) return 0;
    out = ((double (*)(id, SEL))objc_msgSend)(settings, @selector(response));
    return out;
}

static double AppleDamping(BOOL opening) {
    double out = 0;
    Class c = NSClassFromString(@"_UIAnimationSettingsFactory");
    if (!c) return 0;
    SEL sel = opening ? NSSelectorFromString(@"homeGestureCenterRowZoomUpSettings")
                      : NSSelectorFromString(@"iconZoomDownSettings");
    if (![c respondsToSelector:sel]) {
        sel = opening ? NSSelectorFromString(@"homeGestureEdgeRowZoomUpSettings")
                      : NSSelectorFromString(@"switcherToHomeSettings");
        if (![c respondsToSelector:sel]) return 0;
    }
    id settings = ((id (*)(id, SEL))objc_msgSend)(c, sel);
    if (!settings || ![(NSObject *)settings respondsToSelector:@selector(dampingRatio)]) return 0;
    out = ((double (*)(id, SEL))objc_msgSend)(settings, @selector(dampingRatio));
    return out;
}

/* ------------------------------------------------------------------ *
 *  CAMeshTransform builder — the heart of the effect.                 *
 *                                                                     *
 *  Mesh lives in the layer's unit square (x,y,u,v in [0,1]).          *
 *  progress p in [0,1] : 0 = icon rect, 1 = fullscreen.               *
 *                                                                     *
 *  For every vertex:                                                  *
 *    - screen position of the vertex inside the *fully zoomed* window *
 *    - w = how close that vertex is to the anchor icon (0..1)         *
 *    - local progress  lp = p + warp * sin(pi*p) * (w - 0.5)          *
 *      -> near-the-icon vertices lead, far vertices lag.  The sine    *
 *        envelope guarantees the warp is 0 at both ends (continuity,  *
 *        no broken corners at start/end of the transition).           *
 *    - vertex position = lerp(iconRectPoint, fullRectPoint, lp)       *
 *    - plus a small perpendicular "belly" bulge:                      *
 *        b = bulge * sin(pi*p) * sin(pi*u) * sin(pi*v) * perp(dir)    *
 *      which gives the liquid/genie volume without breaking edges.    *
 * ------------------------------------------------------------------ */

static CAMeshTransform * MakeGenieMesh(CGRect iconRect, CGRect fullRect,
                                       CGPoint anchor, double p, BOOL opening) {
    static float        verts[(kMeshN + 1) * (kMeshN + 1) * 5];
    static unsigned int faces[kMeshN * kMeshN * 8];   /* quads: 4 idx + 4 w */
    static BOOL facesBuilt = NO;

    const int N = kMeshN;
    const int V = (N + 1) * (N + 1);

    /* warp amount for this frame.
       Opening leads a bit stronger than closing: on iOS 26 the open burst is
       snappier/more elastic, the close contract is slightly calmer. */
    double ws = prefWarpStrength * (opening ? 1.12 : 0.92);
    double warp  = 0.34 * ws * sin(kPi * p);
    double bulge = 0.058 * ws * sin(kPi * p);

    CGFloat fw = fullRect.size.width, fh = fullRect.size.height;
    if (fw < 1 || fh < 1) return nil;

    CGFloat diag = sqrt(fw * fw + fh * fh);
    CGFloat maxDist = diag * 1.05;

    CGPoint dir = NormDir(anchor, CGPointMake(CGRectGetMidX(fullRect), CGRectGetMidY(fullRect)));

    int vi = 0;
    for (int j = 0; j <= N; j++) {
        for (int i = 0; i <= N; i++, vi++) {
            float u = (float)i / N;
            float v = (float)j / N;

            /* where this vertex sits inside the fullscreen window */
            CGPoint fs = CGPointMake(fullRect.origin.x + u * fw,
                                     fullRect.origin.y + v * fh);

            /* distance-based leadership weight (1 near icon, 0 far away) */
            CGFloat dxs = fs.x - anchor.x, dys = fs.y - anchor.y;
            CGFloat dist = sqrt(dxs * dxs + dys * dys);
            double w = 1.0 - fmin(1.0, dist / maxDist);

            /* local progress: near side leads the far side */
            double lp = p + warp * (w - 0.5);
            lp = fmax(0.0, fmin(1.0, lp));

            /* base position: from icon rect → fullscreen rect */
            double x = iconRect.origin.x + u * iconRect.size.width
                     + lp * (fs.x - (iconRect.origin.x + u * iconRect.size.width));
            double y = iconRect.origin.y + v * iconRect.size.height
                     + lp * (fs.y - (iconRect.origin.y + v * iconRect.size.height));

            /* perpendicular genie belly, shaped by both texture axes so
               the border stays a smooth continuous curve */
            double px = -dir.y, py = dir.x;
            double bell = bulge * sin(kPi * u) * sin(kPi * v);
            /* bulge points toward the icon when closing, away when opening */
            double sign = opening ? -1.0 : 1.0;
            x += sign * bell * px * diag;
            y += sign * bell * py * diag;

            /* map screen position back into the layer's unit square.
               CAMeshVertex layout: { from(u,v), to(x,y,z) }
               meshMode 2 swaps from/to — escape hatch for iOS builds whose
               vertex semantics differ. */
            float mx = (float)((x - fullRect.origin.x) / fw);
            float my = (float)((y - fullRect.origin.y) / fh);

            if (prefMeshMode == 2) {
                verts[vi * 5 + 0] = mx;
                verts[vi * 5 + 1] = my;
                verts[vi * 5 + 2] = u;
                verts[vi * 5 + 3] = v;
            } else {
                verts[vi * 5 + 0] = u;
                verts[vi * 5 + 1] = v;
                verts[vi * 5 + 2] = mx;
                verts[vi * 5 + 3] = my;
            }
            verts[vi * 5 + 4] = 0.0f;
        }
    }

    if (!facesBuilt) {
        int fi = 0;
        for (int j = 0; j < N; j++) {
            for (int i = 0; i < N; i++) {
                unsigned int a = j * (N + 1) + i;   /* top-left     */
                unsigned int b = a + 1;             /* top-right    */
                unsigned int c = a + (N + 1);       /* bottom-left  */
                unsigned int d = c + 1;             /* bottom-right */
                faces[fi++] = a; faces[fi++] = b; faces[fi++] = d; faces[fi++] = c;
                faces[fi++] = 0x3F800000; faces[fi++] = 0x3F800000;
                faces[fi++] = 0x3F800000; faces[fi++] = 0x3F800000;  /* w = 1.0f */
            }
        }
        facesBuilt = YES;
    }

    Class meshClass = NSClassFromString(@"CAMeshTransform");
    if (!meshClass) return nil;
    return [meshClass meshTransformWithVertexCount:V
                                          vertices:verts
                                         faceCount:kMeshN * kMeshN
                                             faces:faces
                                depthNormalization:nil];  /* default: None */
}

/* ------------------------------------------------------------------ */
/* The driver — owns the display link and drives one transition        */
/* ------------------------------------------------------------------ */

@interface AN26Driver : NSObject
- (instancetype)initWithLayer:(CALayer *)layer
                     iconRect:(CGRect)iconRect
                       anchor:(CGPoint)anchor
                      opening:(BOOL)opening;
- (void)tick:(CADisplayLink *)link;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CALayer        *targetLayer;
@property (nonatomic, weak)   UIView         *attachedView;
@property (nonatomic, assign) CGRect          iconRect;
@property (nonatomic, assign) CGPoint         anchor;
@property (nonatomic, assign) BOOL            opening;
@property (nonatomic, assign) BOOL            hasStarted;
@property (nonatomic, assign) CGFloat         savedCornerRadius;
@property (nonatomic, assign) BOOL            savedMasksToBounds;
@property (nonatomic, strong) NSHashTable    *grabbers;   /* weak */
@end

static AN26Driver *gCurrentDriver = nil;

/* every SBHomeGrabberView ever seen (weak) — the driver fades them all */
static NSHashTable *gAllGrabbers = nil;

/* Transition signals — mirrors the original tweak's _lastHomeTransitionTime:
   the workspace transition request tells us WHY a zoom view just appeared,
   which is what separates a real close-to-home from App Switcher views
   (the original pre-baked separate switcher frames for the same reason). */
static CFTimeInterval g_homeTransitionAt = -1e9;
static CFTimeInterval g_appActivateAt    = -1e9;

@implementation AN26Driver {
    CGRect          _fullRect;     /* screen rect — reference space for the mesh  */
    CFTimeInterval  _last;
    CFTimeInterval  _elapsed;
    CATransform3D   _savedSublayerTransform;
    BOOL            _meshBroken;   /* private API threw — stay on zoom fallback   */
    Spring          _spring;
}

- (instancetype)initWithLayer:(CALayer *)layer
                     iconRect:(CGRect)iconRect
                       anchor:(CGPoint)anchor
                      opening:(BOOL)opening {
    if ((self = [super init])) {
        self.targetLayer = layer;
        self.attachedView = (UIView *)layer.delegate;
        self.iconRect    = iconRect;
        self.anchor      = anchor;
        self.opening     = opening;
        self.grabbers    = [NSHashTable weakObjectsHashTable];
        if (!gAllGrabbers) gAllGrabbers = [NSHashTable weakObjectsHashTable];
        for (id g in gAllGrabbers) [self.grabbers addObject:g];

        /* Save exactly what we touch — like the original tweak did
           (_savedCornerRadius / _savedMasksToBounds). We deliberately do NOT
           touch frame, transform or animations of the view itself. */
        self.savedCornerRadius    = layer.cornerRadius;
        self.savedMasksToBounds   = layer.masksToBounds;
        _savedSublayerTransform   = layer.sublayerTransform;

        CGSize ss = [UIScreen mainScreen].bounds.size;
        _fullRect = CGRectMake(0, 0, ss.width, ss.height);

        /* spring: Apple's real settings first, tuned fallbacks otherwise */
        double resp = AppleResponse(opening);
        double damp = AppleDamping(opening);
        if (resp <= 0.01 || resp > 1.5) resp = opening ? kFallbackOpenResponse : kFallbackCloseResponse;
        if (damp <= 0.05 || damp > 1.05) damp = opening ? kFallbackOpenDamping : kFallbackCloseDamping;
        resp /= fmax(0.4, prefSpeedFactor);

        SpringInit(&_spring, opening ? 0.0 : 1.0, resp, damp);
        _spring.target = opening ? 1.0 : 0.0;
        _spring.velocity = opening ? 0.4 / fmax(0.1, resp) : -0.4 / fmax(0.1, resp);

        /* start from a clean slate for THIS layer's custom props only */
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (self.opening) {
            layer.opacity = 0.0;
        } else {
            layer.opacity = 1.0;
        }
        [CATransaction commit];

        self.hasStarted = NO;

        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        self.displayLink.preferredFramesPerSecond = 120;
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)tick:(CADisplayLink *)link {
    CALayer *layer = self.targetLayer;
    UIView *view = self.attachedView;
    if ((!view || !view.window) && (layer.superlayer == nil)) { [self finish]; return; }

    CFTimeInterval now = CACurrentMediaTime();
    if (!self.hasStarted) { self.hasStarted = YES; self->_last = now; }

    double dt = now - self->_last;
    self->_last = now;

    self->_elapsed += dt;
    if (self->_elapsed > 1.4) { [self finish]; return; }

    /* The mesh maps geometry in normalized layer space — it is only valid
       once SpringBoard has sized the zoom view to the full screen (which it
       does immediately for the zoom transition). Until then: hold our fade
       state and wait; the elapsed cap aborts safely if it never happens. */
    CGSize ssz = _fullRect.size;
    BOOL sizedOK = layer.bounds.size.width >= ssz.width * 0.90
                && layer.bounds.size.height >= ssz.height * 0.90;
    if (!sizedOK) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.opacity = self.opening ? 0.0 : 1.0;
        [CATransaction commit];
        return;
    }

    BOOL settled = SpringStep(&_spring, dt);
    double p = fmax(0.0, fmin(1.0, _spring.value));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    /* ---- geometry -------------------------------------------------------
       The view's own frame/transform stay untouched (SpringBoard owns them).
       Preferred path: genie CAMeshTransform (like the original tweak).
       Fallback path (mesh unavailable / threw): plain zoom of the content
       via sublayerTransform — still snappier than nothing, never broken. */
    BOOL usedMesh = NO;
    if (!_meshBroken && prefMeshMode != 0 && p > 0.001 && p < 0.999) {
        @try {
            CAMeshTransform *mesh = MakeGenieMesh(self.iconRect, _fullRect,
                                                  self.anchor, p, self.opening);
            if (mesh) { layer.meshTransform = mesh; usedMesh = YES; }
        }
        @catch (NSException *e) {
            _meshBroken = YES;
            layer.meshTransform = nil;
        }
    } else if (!_meshBroken && prefMeshMode != 0) {
        layer.meshTransform = nil;          /* endpoints — clean state */
    }

    if (!usedMesh) {
        /* zoom fallback anchored on the icon (screen space == layer space:
           the layer is fullscreen and pinned at the window origin) */
        CGFloat s = (CGFloat)p;
        if (s < 0.015) s = 0.015;
        CATransform3D t = CATransform3DIdentity;
        t = CATransform3DTranslate(t, (1 - s) * self.anchor.x, (1 - s) * self.anchor.y, 0);
        t = CATransform3DScale(t, s, s, 1);
        layer.sublayerTransform = t;
        layer.masksToBounds = NO;          /* don't clip the zooming content */
    } else {
        layer.sublayerTransform = _savedSublayerTransform;
        layer.masksToBounds = YES;
    }

    /* ---- corner radius (only meaningful in mesh mode) ------------------- */
    if (usedMesh) {
        CGFloat screenR = ScreenCornerRadius();
        CGFloat iconR   = self.iconRect.size.width * 0.2237;
        CGFloat pe      = (CGFloat)(p * p * (3.0 - 2.0 * p));
        layer.cornerRadius = screenR + (iconR - screenR) * pe;
        layer.masksToBounds = YES;
    }

    /* ---- opacity: tiny guard fades only --------------------------------- */
    CGFloat a = 1.0;
    if (self.opening) {
        if (p < 0.10) a = p / 0.10;                    /* fade-in at start   */
    } else {
        if (p < 0.18) a = fmax(0.0, (p - 0.02) / 0.16); /* fade-out at end   */
    }
    layer.opacity = a;

    /* ---- grabbers ride along -------------------------------------------- */
    for (id g in self.grabbers) {
        if ([g respondsToSelector:@selector(setAlpha:)]) {
            CGFloat ga = self.opening ? (1.0 - 0.85 * sin(kPi * (CGFloat)p))
                                      : (0.15 + 0.85 * (CGFloat)p);
            [(UIView *)g setAlpha:ga];
        }
    }

    [CATransaction commit];

    if (settled) [self finish];
}

- (void)finish {
    [self.displayLink invalidate];
    self.displayLink = nil;

    CALayer *layer = self.targetLayer;
    if (layer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        /* restore everything we touched — the stock flow takes back over */
        layer.meshTransform     = nil;
        layer.sublayerTransform = _savedSublayerTransform;
        layer.opacity           = 1.0;
        layer.cornerRadius      = self.savedCornerRadius;
        layer.masksToBounds     = self.savedMasksToBounds;
        [CATransaction commit];
    }

    for (id g in self.grabbers) {
        if ([g respondsToSelector:@selector(setAlpha:)]) [(UIView *)g setAlpha:1.0];
    }

    if (gCurrentDriver == self) gCurrentDriver = nil;
}


@end

/* ------------------------------------------------------------------ */
/* Hooks                                                               */
/* ------------------------------------------------------------------ */

%group Core

/* Record the tapped icon so the transition can anchor to it.
   SBIconView covers app icons, folders and widgets. */
%hook SBIconView
- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    if (!highlighted) return;
    UIView *v = (UIView *)self;
    CGRect r = [v convertRect:v.bounds toView:nil];
    if (r.size.width < 8 || r.size.height < 8) return;
    CGFloat lr = v.layer.cornerRadius;
    gAnchor.valid = YES;
    gAnchor.center = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    gAnchor.size = r.size;
    gAnchor.cornerRadius = lr > 2 ? lr : r.size.width * 0.2237;
    gAnchor.tapTime = CACurrentMediaTime();
    gLastAnchor = gAnchor;
}
%end

/* The fullscreen zoom snapshot view — attach our driver here. */
%hook SBFullscreenZoomView
- (void)didMoveToWindow {
    %orig;

    if (!prefEnabled || prefAnimSpeed != 1) return;

    UIView *selfView = (UIView *)self;
    if (!selfView.window) return;

    /* never stack two drivers */
    if (gCurrentDriver) return;

    CGRect bounds = selfView.bounds;
    CGSize ss = selfView.window.bounds.size;
    BOOL looksFullscreen = bounds.size.width >= ss.width * 0.90
                        && bounds.size.height >= ss.height * 0.90;

    /* Direction decision — mirrors the original tweak's state machine
       (_hasTappedIcon + _lastHomeTransitionTime):
         OPEN : fresh icon tap, or a fresh workspace "activate/launch"
         CLOSE: fresh workspace "home" transition AND fullscreen view
         else : ABORT — stock animation plays untouched (safety first).
       App Switcher / other snapshot views get no fresh signals → never
       hijacked (the original served them separate pre-baked frames). */
    CFTimeInterval now = CACurrentMediaTime();
    BOOL recentTap   = gAnchor.valid && (now - gAnchor.tapTime) < 0.9;
    BOOL freshOpen   = (now - g_appActivateAt)   < 1.0;
    BOOL freshHome   = (now - g_homeTransitionAt) < 2.0;

    BOOL opening;
    if (recentTap || freshOpen) {
        opening = YES;
    } else if (freshHome && looksFullscreen) {
        opening = NO;
    } else {
        return;                              /* unknown context — stock wins */
    }

    /* anchor for closing: last known icon, else bottom-center fallback */
    IconAnchor a = gAnchor;
    if (!opening && !a.valid) a = gLastAnchor;
    if (!a.valid) {
        a.valid = YES;
        a.size = CGSizeMake(60, 60);
        a.center = CGPointMake(ss.width / 2.0, ss.height - 44 - 30);
        a.cornerRadius = 13;
    }
    /* keep the anchor inside the screen (folders can sit off-screen lists) */
    a.center.x = fminf(fmaxf(a.center.x, 30), ss.width - 30);
    a.center.y = fminf(fmaxf(a.center.y, 30), ss.height - 30);

    CGRect iconRect = CGRectMake(a.center.x - a.size.width / 2.0,
                                 a.center.y - a.size.height / 2.0,
                                 a.size.width, a.size.height);

    AN26Driver *driver = [[AN26Driver alloc] initWithLayer:selfView.layer
                                                  iconRect:iconRect
                                                    anchor:a.center
                                                   opening:opening];
    gCurrentDriver = driver;
}
%end

/* Workspace transition requests — timestamp home-gesture closes and app
   activations (same role as the original's _lastHomeTransitionTime).
   If this class/selector doesn't exist on the running iOS, the hook simply
   never fires and the close path stays on the stock animation (safe). */
/* Hooked manually (not %hook) so a missing class on some iOS build is a
   clean no-op instead of depending on the hooking engine's nil handling. */
static void (*_orig_SBMainWorkspaceTransitionRequest_setEventLabel)(id, SEL, NSString *);

static void _hook_SBMainWorkspaceTransitionRequest_setEventLabel(id self, SEL _cmd, NSString *label) {
    if (_orig_SBMainWorkspaceTransitionRequest_setEventLabel)
        _orig_SBMainWorkspaceTransitionRequest_setEventLabel(self, _cmd, label);
    if (![label isKindOfClass:[NSString class]]) return;
    NSString *l = [label lowercaseString];
    CFTimeInterval now = CACurrentMediaTime();
    if ([l containsString:@"home"])        g_homeTransitionAt = now;
    if ([l containsString:@"activate"] || [l containsString:@"launch"])
                                           g_appActivateAt = now;
}

/* Home grabbers (page dots) register themselves so the driver can fade them. */
%hook SBHomeGrabberView
- (void)didMoveToWindow {
    %orig;
    if (!gAllGrabbers) gAllGrabbers = [NSHashTable weakObjectsHashTable];
    if (self.window) {
        [gAllGrabbers addObject:self];
        if (gCurrentDriver) [gCurrentDriver.grabbers addObject:self];
    }
}
%end

%end /* group Core */

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

    /* optional signal hook — installed only if the class exists */
    Class wsReq = NSClassFromString(@"SBMainWorkspaceTransitionRequest");
    if (wsReq) {
        MSHookMessageEx(wsReq,
                        @selector(setEventLabel:),
                        (IMP)&_hook_SBMainWorkspaceTransitionRequest_setEventLabel,
                        (IMP *)&_orig_SBMainWorkspaceTransitionRequest_setEventLabel);
    }
}
