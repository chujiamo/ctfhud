#!/bin/sh
# CTF HUD v1.8.1: ARM64 Standard / Apple M1-M5 build profiles.
# Native macOS build only. Installs to /Applications, NEVER launches.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

usage() {
  cat <<'HELP'
CTF HUD v1.8.1 — native Apple Silicon build profiles

Usage:
  zsh build_app.sh [--profile auto|standard|m1|m2|m3|m4|m5]
                   [--build-only] [--fallback-standard] [--allow-newer]
  zsh build_app.sh --all --build-only
  zsh build_app.sh --list

Options:
  --profile PROFILE    Choose exact target; omitted = interactive menu on terminal,
                       otherwise auto-detect local Apple Silicon (or standard).
  --build-only         Compile/sign into build/PROFILE/CTFHUD.app; do not install.
  --all                Build standard and all M1-M5 profiles separately. Requires
                       --build-only. Unsupported CPU profiles fail individually.
  --fallback-standard  If chosen CPU profile compilation fails, retry as standard.
                       Actual result is labelled 'standard', not the requested CPU.
  --allow-newer        Allow installing a build targeting a newer M-series CPU
                       than the current Mac. This may make the app unlaunchable.
  --list               List available profiles and exit.
  --help               Show this help.

Profiles use: -O -whole-module-optimization -target arm64-apple-macosx13.0
CPU-specific profiles also pass: -Xllvm -mcpu=apple-mN
The installed version does not start automatically.
HELP
}

profile=""
requested_explicit=0
build_only=0
build_all=0
fallback_standard=0
allow_newer=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile 缺少参数" >&2; exit 2; }
      profile=$2; requested_explicit=1; shift 2 ;;
    --profile=*) profile=${1#--profile=}; requested_explicit=1; shift ;;
    --build-only) build_only=1; shift ;;
    --all) build_all=1; shift ;;
    --fallback-standard) fallback_standard=1; shift ;;
    --allow-newer) allow_newer=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --list)
      printf '%s\n' 'standard  Generic Apple Silicon ARM64 release' \
        'm1        Apple M1 / M1 Pro / M1 Max / M1 Ultra' \
        'm2        Apple M2 / M2 Pro / M2 Max / M2 Ultra' \
        'm3        Apple M3 / M3 Pro / M3 Max' \
        'm4        Apple M4 / M4 Pro / M4 Max' \
        'm5        Apple M5 family (toolchain support required)' \
        'auto      Detect local M-series generation'; exit 0 ;;
    *) echo "未知选项：$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$build_all" -eq 1 ]; then
  [ "$build_only" -eq 1 ] || { echo "--all 必须同时指定 --build-only（避免覆盖安装）。" >&2; exit 2; }
  [ "$requested_explicit" -eq 0 ] || { echo "--all 不能与 --profile 同时指定。" >&2; exit 2; }
  [ "$fallback_standard" -eq 0 ] || { echo "--all 不能与 --fallback-standard 同时指定。" >&2; exit 2; }
fi

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  echo "缺少 Xcode Command Line Tools。请先运行 xcode-select --install。" >&2
  exit 1
fi

# Keep the automatic detection conservative: an unknown chip becomes standard.
detect_host_profile() {
  cpu_info=$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
  if [ -z "$cpu_info" ]; then
    cpu_info=$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null || true)
  fi
  chip=$(printf '%s\n' "$cpu_info" | /usr/bin/sed -nE 's/.*Apple M([1-5])([^0-9]|$).*/m\1/p' | /usr/bin/head -n 1)
  if [ -n "$chip" ]; then printf '%s\n' "$chip"; else printf 'standard\n'; fi
}
HOST_PROFILE=$(detect_host_profile)

if [ "$requested_explicit" -eq 0 ] && [ "$build_all" -eq 0 ]; then
  if [ -t 0 ]; then
    printf '\nCTF HUD v1.8.1 — 选择优化目标（本机检测：%s）\n' "$HOST_PROFILE"
    printf '%s\n' '  0) 自动识别（推荐）' '  1) Standard — 通用 ARM64' \
      '  2) Apple M1' '  3) Apple M2' '  4) Apple M3' \
      '  5) Apple M4' '  6) Apple M5'
    printf '请选择 [0]: '
    choice=''
    IFS= read -r choice || true
    case "$choice" in
      ''|0) profile=auto ;;
      1) profile=standard ;;
      2) profile=m1 ;;
      3) profile=m2 ;;
      4) profile=m3 ;;
      5) profile=m4 ;;
      6) profile=m5 ;;
      *) echo "选择无效：$choice" >&2; exit 2 ;;
    esac
  else
    profile=auto
  fi
fi

if [ "$build_all" -eq 0 ]; then
  case "$profile" in
    auto) profile=$HOST_PROFILE ;;
    standard|m1|m2|m3|m4|m5) ;;
    *) echo "无效编译配置：$profile" >&2; exit 2 ;;
  esac
fi

# Build targeting newer CPUs is permitted with --build-only for distribution.
# Installing such a binary on the current older Mac is refused by default.
check_host_compatibility() {
  desired=$1
  [ "$build_only" -eq 1 ] && return 0
  [ "$allow_newer" -eq 1 ] && return 0
  case "$HOST_PROFILE:$desired" in
    m1:m2|m1:m3|m1:m4|m1:m5|m2:m3|m2:m4|m2:m5|m3:m4|m3:m5|m4:m5)
      echo "拒绝安装：本机为 $HOST_PROFILE，所选 $desired 可能生成不兼容指令。" >&2
      echo "可使用 --build-only 打包给其他 Mac，或明确指定 --allow-newer。" >&2
      return 1 ;;
  esac
  return 0
}

# Output is separately versioned by profile (build/m3/... does not overwrite build/m2/...).
compile_profile() {
  target_profile=$1
  requested_profile=$2
  APP="$ROOT/build/$target_profile/CTFHUD.app"
  EXE="$APP/Contents/MacOS/CTFHUD"
  /bin/rm -rf "$APP" || return 1
  /bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || return 1

  set -- -O -whole-module-optimization -target arm64-apple-macosx13.0
  if [ "$target_profile" != 'standard' ]; then
    set -- "$@" -Xllvm "-mcpu=apple-$target_profile"
  fi

  echo "🍎 编译 $target_profile：swiftc $*"
  if ! /usr/bin/xcrun swiftc "$@" \
      -framework AppKit -framework SwiftUI -framework UserNotifications \
      Core.swift Localization.swift main.swift -o "$EXE"; then
    /bin/rm -rf "$APP"
    return 1
  fi

  /bin/cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CTFHUD</string>
<key>CFBundleIdentifier</key><string>org.ctfhud.local</string>
<key>CFBundleName</key><string>CTF HUD</string>
<key>CFBundleDisplayName</key><string>CTF HUD</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ja</string></array>
<key>CFBundleShortVersionString</key><string>1.8.1</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  # A write failure must not be misreported as a successful build.
  [ -s "$APP/Contents/Info.plist" ] || return 1

  # Ship all locale resources inside the signed app. Missing files must fail
  # the build rather than silently producing a Chinese-only UI.
  /bin/mkdir -p "$APP/Contents/Resources/locales" || return 1
  for lang in en zh-Hant ja; do
    [ -s "$ROOT/locales/$lang.json" ] || { echo "Missing language pack: $lang" >&2; return 1; }
    /usr/bin/ditto "$ROOT/locales/$lang.json" "$APP/Contents/Resources/locales/$lang.json" || return 1
  done

  # The actual compiled profile is stamped into the app for inspection.
  # All values here are validated enumerations; no local personal data is embedded.
  {
    printf 'CTF HUD v1.8.1\n'
    printf 'Requested profile: %s\n' "$requested_profile"
    printf 'Compiled profile: %s\n' "$target_profile"
    printf 'Architecture: arm64\n'
    printf 'Compiler flags:'
    for flag in "$@"; do printf ' %s' "$flag"; done
    printf '\n'
    /usr/bin/xcrun swiftc --version | /usr/bin/head -n 1
  } > "$APP/Contents/Resources/BuildProfile.txt" || return 1

  /usr/bin/codesign --force --sign - "$APP" || {
    echo "❌ 签名失败：$target_profile" >&2
    return 1
  }
  echo "✅ 成功：$APP"
  return 0
}

install_app() {
  built_app=$1
  target_dir='/Applications'
  target_app="$target_dir/CTFHUD.app"
  if /usr/bin/pgrep -x CTFHUD >/dev/null 2>&1; then
    echo '检测到 CTFHUD 正在运行，请从菜单栏退出后再安装。' >&2
    return 1
  fi
  if [ -L "$target_app" ]; then
    echo "拒绝覆盖符号链接：$target_app" >&2
    return 1
  fi
  if [ -e "$target_app" ] && [ ! -d "$target_app" ]; then
    echo "拒绝覆盖非 App 目录：$target_app" >&2
    return 1
  fi
  if [ -d "$target_app" ]; then
    app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$target_app/Contents/Info.plist" 2>/dev/null || true)
    if [ "$app_id" != 'org.ctfhud.local' ]; then
      echo "拒绝覆盖其他开发者应用：$target_app" >&2
      return 1
    fi
  fi

  if [ -w "$target_dir" ]; then
    if [ -d "$target_app" ]; then /bin/rm -rf "$target_app"; fi
    /usr/bin/ditto "$built_app" "$target_app"
  else
    echo '需要管理员权限安装到 /Applications，不会自动启动。'
    if [ -d "$target_app" ]; then /usr/bin/sudo /bin/rm -rf "$target_app"; fi
    /usr/bin/sudo /usr/bin/ditto "$built_app" "$target_app"
  fi
  echo "✅ 安装：$target_app"
  echo "✅ 实际编译配置：$(/usr/bin/awk -F': ' '/^Compiled profile:/ {print $2}' "$built_app/Contents/Resources/BuildProfile.txt")"
  echo '✅ 未启动应用；可随时从「应用程序」手动打开。'
}

if [ "$build_all" -eq 1 ]; then
  failures=''
  successes=''
  for candidate in standard m1 m2 m3 m4 m5; do
    if compile_profile "$candidate" "$candidate"; then
      successes="$successes $candidate"
    else
      failures="$failures $candidate"
      echo "⚠️ $candidate 编译失败，可能是该 Xcode/LLVM 不支持该处理器。" >&2
    fi
  done
  printf '\n成功配置：%s\n' "${successes:-无}"
  printf '失败配置：%s\n' "${failures:-无}"
  [ -z "$failures" ] || exit 1
  exit 0
fi

check_host_compatibility "$profile"
requested=$profile
if ! compile_profile "$profile" "$requested"; then
  if [ "$fallback_standard" -eq 1 ] && [ "$profile" != standard ]; then
    echo "⚠️ $profile 编译失败；按要求回退至 standard。" >&2
    profile=standard
    compile_profile "$profile" "$requested" || exit 1
  else
    echo "❌ $profile 编译失败，未安装；使用 --fallback-standard 可允许回退。" >&2
    exit 1
  fi
fi

if [ "$build_only" -eq 1 ]; then
  echo "✅ 仅构建，没有改动 /Applications：$ROOT/build/$profile/CTFHUD.app"
else
  install_app "$ROOT/build/$profile/CTFHUD.app"
fi
