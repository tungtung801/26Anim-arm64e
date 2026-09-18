# 26Anim 0.0.1 — iOS 26 app animation · build cho roothide

Tái tạo animation mở/đóng app của **iOS 26** cho SpringBoard (fat binary **arm64 + arm64e**
— slice arm64e chạy trên A12+, slice arm64 chạy trên A11 trở xuống). Bản viết lại từ
tweak gốc `26Anim 1.0.3` của **ngkhoi (@cakoi_.)** — cùng cơ chế (`CAMeshTransform` +
`CADisplayLink` 120 Hz), toán học genie mới bám sát hiệu ứng iOS 26.

Package: **`com.tungtung801.26anim`** · Version **0.0.1** · Deb arch `iphoneos-arm64e`

## Build bằng GitHub Actions

Repo đã có `.github/workflows/build.yml` → **push là tự build**, artifact
`26anim-roothide` chứa `com.tungtung801.26anim_0.0.1_iphoneos-arm64e.deb`.
Push tag `v*` → tự tạo GitHub Release.

Môi trường CI dùng đúng docs roothide/Developer:
- fork **roothide/theos** (auto-synced 100% với theos chính thức)
- clang 19 iOS toolchain (`L1ghtmann/llvm-project`) + `iPhoneOS16.5.sdk` + ldid
- `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide`
- Có bước verify sau build: arch `iphoneos-arm64e`, package `com.tungtung801.26anim`,
  layout jbroot (không `var/jb`)

## Build local

```bash
ROOTHIDE=1 ./setup-theos.sh       # cài fork roothide/theos + toolchain + SDK + ldid
export THEOS=$HOME/theos
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

## Cài

Cài deb qua RootHide Manager / Sileo (roothide fork) → SpringBoard respring.
Khuyến nghị RootHide Bootstrap **1.4+** (2.0 stable có SpringBoard injection ổn định nhất).

## Tinh chỉnh (Settings → 26Anim)

| Key | Ý nghĩa | Mặc định |
|---|---|---|
| `enabled` | Bật/tắt toàn bộ | ON |
| `animSpeed` | `0` = animation native, `1` = iOS 26 | 1 |
| `warpStrength` | Cường độ biến dạng genie (0 – 2) | 1.0 |
| `speedFactor` | Nhân tốc độ spring (0.5 – 2, nhỏ hơn = nhanh hơn) | 1.0 |

Đổi setting áp dụng ngay (Darwin notify), không cần respring.

## Nguyên lý (tóm tắt)

1. **Anchor** — hook `SBIconView setHighlighted:` ghi tâm/kích thước/bo góc icon vừa chạm.
2. **Bắt transition** — `SBFullscreenZoomView didMoveToWindow`: có tap icon ≤1.2s trước →
   **mở**; view full màn hình không tap → **đóng**.
3. **Genie warp** — mỗi frame dựng `CAMeshTransform` 14×14 quad: đỉnh gần icon đi trước
   `lp = p + W·sin(πp)·(w−½)`, bụng lồi vuông góc, mở 1.12× / đóng 0.92×.
4. **Spring** — tích phân bán-ẩn, đọc settings thật của SpringBoard
   (`homeGestureCenterRowZoomUpSettings`, `iconZoomDownSettings`, …), fallback
   0.38s/ζ0.90 (mở), 0.42s/ζ0.88 (đóng).
5. **Corner morph** liên tục icon↔màn hình + cross-fade 12% chống hard-snap.

## Credits

- ngkhoi (@cakoi_.) — tác giả 26Anim gốc (cơ chế + ý tưởng)
- tungtung801 — rebuild, genie warp mới, roothide/CI
