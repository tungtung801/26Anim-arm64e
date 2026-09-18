/*
 * 26Anim v0.1.0 — iOS 26 style directional genie app open/close, for SpringBoard.
 *
 * Structure & workflow intentionally mirror the author's working tweak
 * (26Unlock / 26wave):
 *
 *   - NO CydiaSubstrate link.  Hooking is done with the Objective-C runtime
 *     (class_addMethod / method_setImplementation), so the dylib always loads
 *     even when the jailbreak does not ship a substrate the loader can resolve.
 *     ("installed but does nothing" is exactly the failure mode this avoids.)
 *   - NO Settings pane.  Tunables live in /var/mobile/26Anim.plist (optional
 *     file — absent = defaults).  Edit with Filza, next transition applies.
 *   - Diagnostics append to /var/mobile/26Anim.log (capped ~200 KB) so a
 *     "nothing happens" report comes with data.
 *
 * Animation (verbal spec of the iOS 26 transition):
 *   The app surface behaves like an elastic membrane PINNED at the icon
 *   coordinates.  Edges near the icon lead (stretch/suck first), far edges
 *   lag and stay flat; open = funnel flaring away from the icon toward the
 *   screen centre, close = the exact same warp field traversed backwards
 *   (funnel contraction into the icon "slot").  Open lands with a very light
 *   settle bounce.  We only ever write CAMeshTransform — a property the stock
 *   zoom flow never touches — on top of the native SpringBoard zoom, so the
 *   stock animation can never be structurally broken by us.
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdio.h>

/* ================================================================== */
#pragma mark - diagnostics
/* ================================================================== */

#define A26_LOGFILE "/var/mobile/26Anim.log"

static BOOL g_debug = YES;

static void a26_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void a26_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[26Anim] %@", msg);

    @autoreleasepool {
        NSString *path = @A26_LOGFILE;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        if (attrs && [attrs fileSize] > 200 * 1024) {
            [fm removeItemAtPath:path error:NULL];
        }
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        FILE *f = fopen(A26_LOGFILE, "a");
        if (f) {
            fputs([line UTF8String], f);
            fclose(f);
        }
    }
}

/* ================================================================== */
#pragma mark - tunables  (/var/mobile/26Anim.plist, all optional)
/* ================================================================== */

#define A26_SETTINGS "/var/mobile/26Anim.plist"

static BOOL   g_enabled     = YES;
static double g_warp        = 1.0;    /* 0..2  overall membrane strength   */
static double g_duration    = 0.45;   /* s, time-fallback transition span  */
static BOOL   g_meshSwapped = NO;     /* flip CAMeshVertex from/to if the  */
                                      /* warp renders inverted on a build  */
static double g_edgeGain    = 1.0;    /* 0.5..2 directional edge emphasis  */

static void a26_readSettings(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@A26_SETTINGS];
    if (!d) return;
    NSNumber *v;

    v = d[@"enabled"];     if ([v isKindOfClass:[NSNumber class]]) g_enabled     = [v boolValue];
    v = d[@"warp"];        if ([v isKindOfClass:[NSNumber class]]) g_warp        = [v doubleValue];
    v = d[@"duration"];    if ([v isKindOfClass:[NSNumber class]]) g_duration    = [v doubleValue];
    v = d[@"meshSwapped"]; if ([v isKindOfClass:[NSNumber class]]) g_meshSwapped = [v boolValue];
    v = d[@"debug"];       if ([v isKindOfClass:[NSNumber class]]) g_debug       = [v boolValue];
    v = d[@"edgeGain"];    if ([v isKindOfClass:[NSNumber class]]) g_edgeGain    = [v doubleValue];

    g_warp     = fmin(2.0, fmax(0.0, g_warp));
    g_duration = fmin(0.90, fmax(0.20, g_duration));
    g_edgeGain = fmin(2.0, fmax(0.3, g_edgeGain));
}

/* ================================================================== */
#pragma mark - small math
/* ================================================================== */

#define kPi 3.14159265358979323846

static inline float a26_clampf(float v, float lo, float hi) {
    return fminf(fmaxf(v, lo), hi);
}

static inline float a26_smoothstep(float e0, float e1, float x) {
    float t = a26_clampf((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/* ease-out-back: fast start, overshoots slightly past 1, settles on 1.
 * Used for the time-fallback open curve — the mesh envelope sin(pi*p)
 * turns the >1 overshoot into the light settle bounce of the spec. */
static double a26_easeOutBack(double t) {
    const double c1 = 0.9, c3 = c1 + 1.0;
    double u = fmin(1.0, fmax(0.0, t)) - 1.0;
    return 1.0 + c3 * u * u * u + c1 * u * u;
}

/* ================================================================== */
#pragma mark - genie mesh builder
/* ================================================================== */

/* CAMeshTransform (private).  Vertices are 5 floats:
 *   {from.x, from.y, to.x, to.y, to.z}
 * faces are QUAD {a,b,d,c} + 4 uints of bit-pattern 1.0f. */
@interface CAMeshTransform : NSObject
+ (instancetype)meshTransformWithVertexCount:(NSUInteger)vertexCount
                                    vertices:(const float *)vertices
                                   faceCount:(NSUInteger)faceCount
                                       faces:(const unsigned int *)faces
                          depthNormalization:(NSString *)depthNormalization;
@end

@interface CALayer (A26Mesh)
@property (nonatomic, retain) CAMeshTransform *meshTransform;
@end

/*
 * Anchor-driven membrane warp inside the layer's unit square.
 *   dx,dy   = anchor - vertex
 *   pull    = smoothstep(0, .90, |d|)          far vertices barely move
 *   strength= (1-pull)^2 * amp                 near-icon vertices lead
 *   edge    = edge nearest the icon gets extra travel (funnel lip)
 *   opposite edge is damped so the far rim stays continuous (no top-corner
 *   crease on close, per spec)
 * amp carries the whole timeline: 0 at both ends, >0 mid-flight, a small
 * negative dip on the open overshoot = settle bounce.
 */
#define kMeshN 5   /* 5x5 grid -> 36 verts / 25 faces (original's density) */

static CAMeshTransform *a26_buildMesh(CGPoint anchorN, float amp) {
    static float        verts[(kMeshN + 1) * (kMeshN + 1) * 5];
    static unsigned int faces[kMeshN * kMeshN * 8];
    static BOOL         facesBuilt = NO;

    const int N = kMeshN;
    const int V = (N + 1) * (N + 1);

    float ax = (float)anchorN.x;
    float ay = (float)anchorN.y;

    int vi = 0;
    for (int j = 0; j <= N; j++) {
        for (int i = 0; i <= N; i++, vi++) {
            float u = (float)i / N;
            float w = (float)j / N;

            float dx = ax - u;
            float dy = ay - w;
            float dist = sqrtf(dx * dx + dy * dy);

            float pull = a26_smoothstep(0.0f, 0.90f, dist);
            float strength = powf(1.0f - pull, 2.0f) * amp;

            float len = fmaxf(dist, 0.0001f);
            float nx = dx / len;
            float ny = dy / len;

            /* funnel lip: the screen edge the icon sits on travels hardest */
            float nearEdge = (ay < 0.5f) ? (1.0f - w) : w;
            float edgeFactor = (0.60f + nearEdge * 0.85f) * (float)g_edgeGain;

            float pullX = nx * strength * edgeFactor * 0.42f;
            float pullY = ny * strength * edgeFactor * 0.70f;

            /* opposite rim continuity */
            float opposite = a26_smoothstep(0.0f, 0.45f, (ay < 0.5f) ? w : 1.0f - w);
            pullY *= (0.35f + 0.65f * opposite);

            float tx = u + pullX;
            float tw = w + pullY;

            if (g_meshSwapped) {
                verts[vi * 5 + 0] = tx;
                verts[vi * 5 + 1] = tw;
                verts[vi * 5 + 2] = u;
                verts[vi * 5 + 3] = w;
            } else {
                verts[vi * 5 + 0] = u;
                verts[vi * 5 + 1] = w;
                verts[vi * 5 + 2] = tx;
                verts[vi * 5 + 3] = tw;
            }
            verts[vi * 5 + 4] = 0.0f;
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
                faces[fi++] = 0x3F800000; faces[fi++] = 0x3F800000;
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

/* ================================================================== */
#pragma mark - transition signals
/* ================================================================== */

typedef struct {
    BOOL    valid;
    CGPoint center;   /* window coords of the tapped icon */
    CGSize  size;
    CFTimeInterval tapTime;
} A26Anchor;

static A26Anchor g_anchor, g_lastAnchor;
static CFTimeInterval g_appActivateAt = -1e9;
static CFTimeInterval g_homeTransitionAt = -1e9;
static BOOL g_wsHookInstalled = NO;

/* ================================================================== */
#pragma mark - driver
/* ================================================================== */

@interface A26Driver : NSObject
- (instancetype)initWithView:(UIView *)view iconRect:(CGRect)iconRect open:(BOOL)isOpen;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, weak)   UIView         *view;
@end

static A26Driver *g_driver = nil;

@implementation A26Driver {
    CGPoint        _anchorWin;     /* window coords */
    CGFloat        _iconRatio;     /* iconW / screenW */
    CGSize         _screen;
    BOOL           _isOpen;
    double         _measuredP;     /* -1 = nothing measurable this frame */
    double         _lastApplied;
    CFTimeInterval _t0;
    CFTimeInterval _lastMove;
    NSMutableArray<CALayer *> *_touched;
}

- (instancetype)initWithView:(UIView *)view iconRect:(CGRect)iconRect open:(BOOL)isOpen {
    if ((self = [super init])) {
        self.view = view;
        _isOpen = isOpen;
        _touched = [NSMutableArray array];
        _measuredP = -1.0;
        _lastApplied = -1.0;

        _screen = [UIScreen mainScreen].bounds.size;
        if (_screen.width < 8 || _screen.height < 8)
            _screen = view.window.bounds.size;

        _anchorWin = CGPointMake(iconRect.origin.x + iconRect.size.width  / 2.0,
                                 iconRect.origin.y + iconRect.size.height / 2.0);
        _iconRatio = a26_clampf((float)(iconRect.size.width /
                                        fmax(1.0, _screen.width)), 0.02f, 0.60f);
        _t0 = CACurrentMediaTime();
        _lastMove = _t0;

        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        self.link.preferredFramesPerSecond = 120;
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        if (g_debug)
            a26_log(@"driver start open=%d anchor=(%.0f,%.0f) icon=%.0fx%.0f view=%@",
                    _isOpen, _anchorWin.x, _anchorWin.y,
                    iconRect.size.width, iconRect.size.height,
                    NSStringFromClass([view class]));
    }
    return self;
}

/* fullscreen-ish layers under the attached view, nearest-first by area */
static void a26_collect(CALayer *layer, CGSize screen, NSMutableArray *outL, int depth) {
    if (!layer || depth > 4 || outL.count >= 8) return;
    if (layer.bounds.size.width >= screen.width * 0.45 &&
        layer.bounds.size.height >= screen.height * 0.45) {
        [outL addObject:layer];
    }
    for (CALayer *sub in layer.sublayers)
        a26_collect(sub, screen, outL, depth + 1);
}

/* native fullscreen-ness: 1 = fullscreen, 0 = icon-size.  Read from the
 * presentation layers SpringBoard itself is animating. */
- (double)measureNativeProgress:(NSArray<CALayer *> *)cands {
    CGFloat bestDev = 0; BOOL any = NO;
    for (CALayer *l in cands) {
        CALayer *pres = [l presentationLayer];
        if (!pres) continue;
        CGRect pf = pres.frame;
        CGFloat bW = l.bounds.size.width;
        if (bW < 8 || pf.size.width < 0.5) continue;
        CGFloat s = (CGFloat)(pf.size.width / bW);
        if (s < 0.005 || s > 2.5) continue;
        CGFloat dev = (CGFloat)fabs(1.0 - s);
        if (dev > bestDev) { bestDev = dev; any = YES; }
    }
    if (!any) return -1.0;
    CGFloat fullDev = 1.0f - (float)_iconRatio;
    if (fullDev < 0.15f) fullDev = 0.15f;
    double p = 1.0 - (double)a26_clampf(bestDev / fullDev, 0.0f, 1.0f);
    return fmin(1.0, fmax(0.0, p));
}

- (void)tick:(CADisplayLink *)link {
    UIView *view = self.view;
    if (!view.window) { [self finish:@"window gone"]; return; }

    CFTimeInterval now = CACurrentMediaTime();
    double t = now - _t0;
    if (t > 2.5) { [self finish:@"timeout"]; return; }

    NSMutableArray<CALayer *> *cands = [NSMutableArray array];
    a26_collect(view.layer, _screen, cands, 0);
    if (!cands.count && view.layer.bounds.size.width >= _screen.width * 0.60)
        [cands addObject:view.layer];

    if (!cands.count) {
        if (t > 0.6) { [self finish:@"no layers"]; return; }
        return;
    }

    double p;
    double native = [self measureNativeProgress:cands];
    if (native >= 0.0) {
        p = native;                                   /* native timing wins */
        if (fabs(p - _lastApplied) > 0.002) _lastMove = now;
    } else {
        /* time fallback (26Unlock style: our own curve, stock keeps playing
         * underneath; mesh is additive so no conflict is possible) */
        if (_isOpen) p = a26_easeOutBack(t / g_duration);
        else         p = 1.0 - a26_smoothstep(0.0, 1.0, t / g_duration);
    }
    _measuredP = native;

    if ((now - _lastMove) > 0.45) { [self finish:@"stall"]; return; }

    /* envelope: 0 at endpoints, peak mid-flight; the ease-out-back
     * overshoot (p>1) dips negative = settle bounce on open. */
    float amp = (float)(g_warp * sin(kPi * fmin(1.15, fmax(-0.15, p))));
    if (fabsf(amp) < 0.004f) amp = 0.0f;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (amp != 0.0f) {
        int applied = 0;
        for (CALayer *l in cands) {
            if (applied >= 4) break;
            CALayer *pres = [l presentationLayer];
            CGRect pf = pres ? pres.frame : l.frame;
            if (pf.size.width < 8) continue;

            CGPoint aN;
            aN.x = a26_clampf((float)((_anchorWin.x - pf.origin.x) / pf.size.width), 0.02f, 0.98f);
            aN.y = a26_clampf((float)((_anchorWin.y - pf.origin.y) / pf.size.height), 0.02f, 0.98f);

            @try {
                CAMeshTransform *mesh = a26_buildMesh(aN, amp);
                if (mesh) {
                    l.meshTransform = mesh;
                    if (![_touched containsObject:l]) [_touched addObject:l];
                    applied++;
                }
            }
            @catch (NSException *e) {
                l.meshTransform = nil;
                a26_log(@"mesh exception: %@ — disabling warp", e.name);
                g_warp = 0.0;
            }
        }
        if (applied == 0 && t > 0.6) { [CATransaction commit]; [self finish:@"apply failed"]; return; }
    } else if (_touched.count) {
        for (CALayer *l in _touched) l.meshTransform = nil;
        [_touched removeAllObjects];
    }

    [CATransaction commit];

    /* one mid-flight sample is enough in the log */
    static CFTimeInterval lastLogged;
    if (g_debug && now - lastLogged > 0.1) {
        lastLogged = now;
        a26_log(@"t=%.2f p=%.3f native=%.3f amp=%.3f layers=%lu",
                t, p, native, amp, (unsigned long)cands.count);
    }
}

- (void)finish:(NSString *)why {
    [self.link invalidate];
    self.link = nil;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in _touched) l.meshTransform = nil;
    [_touched removeAllObjects];
    [CATransaction commit];

    if (g_debug) a26_log(@"driver end (%@) after %.2fs", why, CACurrentMediaTime() - _t0);
    if (g_driver == self) g_driver = nil;
}

@end

/* ================================================================== */
#pragma mark - attach gating
/* ================================================================== */

static NSMutableArray<UIView *> *g_seenViews;

static void a26_tryAttach(UIView *selfView) {
    if (!g_enabled || g_warp <= 0.0) return;
    if (g_driver) return;
    if (!selfView.window) return;

    /* keep a weak handle so taps can re-arm us when SpringBoard reuses the
     * view without another didMoveToWindow */
    if (![g_seenViews containsObject:selfView]) {
        if (g_seenViews.count > 6) [g_seenViews removeObjectAtIndex:0];
        [g_seenViews addObject:selfView];
        if (g_debug) a26_log(@"attach surface: %@", NSStringFromClass([selfView class]));
    }

    /* never touch App Switcher surfaces */
    for (Class c = object_getClass(selfView); c; c = class_getSuperclass(c)) {
        NSString *n = NSStringFromClass(c);
        if ([n containsString:@"Switcher"]) return;
    }

    CGSize ss = selfView.window.bounds.size;
    CGRect b = selfView.bounds;
    if (b.size.width < ss.width * 0.60 || b.size.height < ss.height * 0.60) return;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL recentTap = g_anchor.valid && (now - g_anchor.tapTime) < 0.9;
    BOOL freshOpen = (now - g_appActivateAt)    < 1.0;
    BOOL freshHome = (now - g_homeTransitionAt) < 2.0;

    BOOL isOpen = recentTap || freshOpen;
    BOOL attach = recentTap || freshOpen || freshHome || !g_wsHookInstalled;
    if (!attach) return;

    A26Anchor a = g_anchor.valid ? g_anchor : g_lastAnchor;
    if (!a.valid) {
        a.valid = YES;
        a.size = CGSizeMake(60, 60);
        a.center = CGPointMake(ss.width / 2.0, ss.height - 74);
    }
    a.center.x = fmin(fmax(a.center.x, 30), ss.width  - 30);
    a.center.y = fmin(fmax(a.center.y, 30), ss.height - 30);
    if (a.size.width < 8) a.size = CGSizeMake(60, 60);

    CGRect iconRect = CGRectMake(a.center.x - a.size.width  / 2.0,
                                 a.center.y - a.size.height / 2.0,
                                 a.size.width, a.size.height);

    g_driver = [[A26Driver alloc] initWithView:selfView iconRect:iconRect open:isOpen];
}

/* ================================================================== */
#pragma mark - hook implementations (plain IMPs, no substrate)
/* ================================================================== */

static IMP g_origIconSetHl    = NULL;
static IMP g_origZoomDidMove  = NULL;
static IMP g_origSnapDidMove  = NULL;
static IMP g_origCrossDidMove = NULL;
static IMP g_origWsSetEvent   = NULL;

/* IMP is declared void(*)(void) in this SDK — call originals through
 * explicitly typed function pointers instead. */
typedef void (*a26Fn2)(id, SEL);
typedef void (*a26FnHl)(id, SEL, BOOL);
typedef void (*a26FnLbl)(id, SEL, NSString *);

static void a26_iconSetHl(id self, SEL _cmd, BOOL hl) {
    if (g_origIconSetHl) ((a26FnHl)g_origIconSetHl)(self, _cmd, hl);
    if (!hl) return;
    UIView *v = (UIView *)self;
    CGRect r = [v convertRect:v.bounds toView:nil];
    if (r.size.width < 8 || r.size.height < 8) return;
    g_anchor.valid   = YES;
    g_anchor.center  = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    g_anchor.size    = r.size;
    g_anchor.tapTime = CACurrentMediaTime();
    g_lastAnchor     = g_anchor;

    /* re-arm: SpringBoard may reuse an existing zoom surface without a new
     * didMoveToWindow — poke the last-seen surfaces shortly after the tap */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (UIView *uv in g_seenViews)
            if (uv.window && !g_driver) a26_tryAttach(uv);
    });
}

static void a26_zoom_didMove(id self, SEL _cmd)  { if (g_origZoomDidMove)  ((a26Fn2)g_origZoomDidMove)(self, _cmd);  a26_tryAttach((UIView *)self); }
static void a26_snap_didMove(id self, SEL _cmd)  { if (g_origSnapDidMove)  ((a26Fn2)g_origSnapDidMove)(self, _cmd);  a26_tryAttach((UIView *)self); }
static void a26_cross_didMove(id self, SEL _cmd) { if (g_origCrossDidMove) ((a26Fn2)g_origCrossDidMove)(self, _cmd); a26_tryAttach((UIView *)self); }

static void a26_wsSetEvent(id self, SEL _cmd, NSString *label) {
    if (g_origWsSetEvent) ((a26FnLbl)g_origWsSetEvent)(self, _cmd, label);
    if (![label isKindOfClass:[NSString class]]) return;
    NSString *l = [label lowercaseString];
    CFTimeInterval now = CACurrentMediaTime();
    if ([l containsString:@"home"]) g_homeTransitionAt = now;
    if ([l containsString:@"activate"] || [l containsString:@"launch"]) g_appActivateAt = now;
    if (g_debug) a26_log(@"ws event: %@", label);
}

/* superclass-safe swizzle: if the method lives on a superclass we add a
 * fresh override on the subclass instead of replacing the superclass IMP
 * (which would hook every UIView on the phone). */
static IMP a26_swizzle(Class c, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    if (class_getMethodImplementation(c, sel) == orig) {
        const char *types = method_getTypeEncoding(m);
        if (!class_addMethod(c, sel, newImp, types)) return NULL;
    } else {
        method_setImplementation(m, newImp);
    }
    return orig;
}

/* ================================================================== */
#pragma mark - init
/* ================================================================== */

__attribute__((constructor))
static void a26_init(void) {
    @autoreleasepool {
        a26_readSettings();
        g_seenViews = [NSMutableArray array];

        a26_log(@"ctor pid=%d enabled=%d warp=%.2f",
                getpid(), g_enabled, g_warp);

        Class icon = NSClassFromString(@"SBIconView");
        if (icon) {
            g_origIconSetHl = a26_swizzle(icon, @selector(setHighlighted:),
                                          (IMP)&a26_iconSetHl);
            a26_log(@"SBIconView %@: %p", @"setHighlighted:", (void *)g_origIconSetHl);
        } else {
            a26_log(@"ERROR: SBIconView not found");
        }

        Class zoom  = NSClassFromString(@"SBFullscreenZoomView");
        Class snap  = NSClassFromString(@"SBReusableSnapshotItemContainer");
        Class cross = NSClassFromString(@"SBCrossfadeView");
        if (zoom)  g_origZoomDidMove  = a26_swizzle(zoom,  @selector(didMoveToWindow), (IMP)&a26_zoom_didMove);
        if (snap)  g_origSnapDidMove  = a26_swizzle(snap,  @selector(didMoveToWindow), (IMP)&a26_snap_didMove);
        if (cross) g_origCrossDidMove = a26_swizzle(cross, @selector(didMoveToWindow), (IMP)&a26_cross_didMove);
        a26_log(@"zoom=%p snap=%p cross=%p",
                (void *)g_origZoomDidMove, (void *)g_origSnapDidMove, (void *)g_origCrossDidMove);

        Class wsReq = NSClassFromString(@"SBMainWorkspaceTransitionRequest");
        if (wsReq) {
            g_origWsSetEvent = a26_swizzle(wsReq, @selector(setEventLabel:),
                                           (IMP)&a26_wsSetEvent);
            g_wsHookInstalled = (g_origWsSetEvent != NULL);
            a26_log(@"SBMainWorkspaceTransitionRequest hooked: %d", g_wsHookInstalled);
        } else {
            a26_log(@"SBMainWorkspaceTransitionRequest absent (heuristic mode)");
        }
    }
}
