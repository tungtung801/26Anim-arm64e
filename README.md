# 26Anim 2.1 — iOS 26 app animation · roothide-ready

Tái tạo animation mở/đóng app của **iOS 26** cho SpringBoard. Bản viết lại toàn bộ từ
tweak gốc `26Anim 1.0.3` của **ngkhoi (@cakoi_.)** — cùng cơ chế (`CAMeshTransform` +
`CADisplayLink` 120 Hz), toán học genie mới bám sát hiệu ứng thật của iOS 26.

**Sẵn sàng build cho jailbreak roothide** qua GitHub Actions — không cần máy Mac.

---

## Nhanh nhất: build bằng GitHub Actions

1. Tạo repo GitHub mới, đẩy **toàn bộ nội dung thư mục này** (làm root repo):
   `Makefile, control, Tweak.x, 26Anim.plist, layout/, setup-theos.sh, .github/`
2. Action **"Build 26Anim"** tự chạy khi push → tạo 2 artifact:
   - `26anim-rootless-roothide` → `com.ngkhoi.26anim_2.1.0_iphoneos-arm64.deb`
     (**cài cho RootHide Bootstrap**, cũng chạy trên Dopamine/palera1n rootless)
   - `26anim-rootful` → `com.ngkhoi.26anim_2.1.0_iphoneos-arm.deb` (unc0ver / rootful)
3. Push tag `v*` (vd `v2.1.0`) → tự tạo GitHub Release kèm cả 2 deb.

Environment (Theos + clang-19 iOS toolchain + iPhoneOS16.5.sdk + ldid) được
`actions/cache` cache lại — các build sau chỉ mất ~10 giây.

## Build local

```bash
./setup-theos.sh                 # cài 1 lần: theos + toolchain + SDK + ldid
export THEOS=$HOME/theos

# roothide / rootless:
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# rootful:
make clean && make package FINALPACKAGE=1
```

## Cài trên roothide

1. Mở **RootHide Manager / Sileo / Zebra** → cài file
   `com.ngkhoi.26anim_2.1.0_iphoneos-arm64.deb` (đúng deb `iphoneos-arm64`).
2. SpringBoard tự respring.
3. Settings → **26Anim**: bật/tắt, đổi warp strength / speed — áp dụng ngay,
   không cần respring lại.

Tương thích: file plist filter chỉ inject vào `com.apple.springboard`; prefs được đọc
từ `CFPreferences` với fallback đọc trực tiếp plist ở
`/var/jb/var/mobile` → `/var/mobile` → `/var/root` (chống stale-cache của cfprefsd
trên rootless). `Depends: mobilesubstrate` — RootHide Bootstrap đã cung cấp sẵn qua
ElleKit.

## Tinh chỉnh (Settings → 26Anim)

| Key | Ý nghĩa | Mặc định |
|---|---|---|
| `enabled` | Bật/tắt toàn bộ | ON |
| `animSpeed` | `0` = animation native, `1` = iOS 26 | 1 |
| `warpStrength` | Cường độ biến dạng genie (0 – 2) | 1.0 |
| `speedFactor` | Nhân tốc độ spring (0.5 – 2, nhỏ hơn = nhanh hơn) | 1.0 |

## Nguyên lý (tóm tắt kỹ thuật)

1. **Anchor** — hook `SBIconView setHighlighted:` ghi tâm/kích thước/bo góc icon vừa chạm.
2. **Bắt transition** — `SBFullscreenZoomView didMoveToWindow`: có tap icon ≤1.2s trước →
   **mở**; view full màn hình không tap → **đóng**.
3. **Genie warp** — mỗi frame dựng `CAMeshTransform` 14×14 quad (đúng binary layout
   `CAMeshVertex{from,to}` + face QUAD): đỉnh gần icon đi trước
   `lp = p + W·sin(πp)·(w−½)`, bụng lồi vuông góc hướng icon, mở stronger hơn đóng
   (1.12×/0.92×). Bao `sin(πp)` = 0 ở 2 đầu → không gãy mép, không hở pixel.
4. **Spring** — tích hợp bán-ẩn `x″=−k(x−1)−cx′`, `k=(2π/response)²`, `c=2ζω`;
   đọc settings thật của SpringBoard (`homeGestureCenterRowZoomUpSettings`,
   `iconZoomDownSettings`, …), fallback 0.38s/ζ0.90 (mở) và 0.42s/ζ0.88 (đóng).
5. **Corner morph** liên tục icon↔màn hình + cross-fade 12% chống hard-snap.

## Cấu trúc project

```
.
├── .github/workflows/build.yml   ← CI: build rootless + rootful + release
├── setup-theos.sh                ← cài môi trường 1 lệnh (local/CI)
├── Tweak.x                       ← toàn bộ source
├── Makefile                      ← theos (arm64 + arm64e, iOS 15+)
├── control                       ← com.ngkhoi.26anim 2.1.0
├── 26Anim.plist                  ← filter: chỉ SpringBoard
└── layout/                       ← pref bundle + preferenceloader
```
