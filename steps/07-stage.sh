#!/bin/bash -eux

IS_DEBUG=${PDFium_IS_DEBUG:-false}
OS=${PDFium_TARGET_OS:?}
TARGET_CPU=${PDFium_TARGET_CPU:?}
TARGET_ENVIRONMENT=${PDFium_TARGET_ENVIRONMENT:-}
VERSION=${PDFium_VERSION:-}
PATCHES="$PWD/patches"
BUILD_TYPE=${PDFium_BUILD_TYPE:-shared}

SOURCE=${PDFium_SOURCE_DIR:-pdfium}
BUILD=${PDFium_BUILD_DIR:-pdfium/out}

STAGING="$PWD/staging"
STAGING_BIN="$STAGING/bin"
STAGING_LIB="$STAGING/lib"

mkdir -p "$STAGING"
rm -rf "$STAGING"/*
mkdir -p "$STAGING_LIB"

case "$BUILD_TYPE" in
  shared)
    CMAKE_CONFIG_FILE="PDFiumConfig.cmake"
    ;;
  static)
    CMAKE_CONFIG_FILE="PDFiumStaticConfig.cmake"
    ;;
esac
sed "s/#VERSION#/${VERSION:-0.0.0.0}/" <"$PATCHES/$CMAKE_CONFIG_FILE" >"$STAGING/PDFiumConfig.cmake"

cp LICENSE "$STAGING"
cat >>"$STAGING/LICENSE" <<END

This package also includes third-party software. See the licenses/ directory for their respective licenses.
END

cp "$BUILD/args.gn" "$STAGING"
cp -R "$SOURCE/public" "$STAGING/include"
rm -f "$STAGING/include/DEPS"
rm -f "$STAGING/include/README"
rm -f "$STAGING/include/PRESUBMIT.py"

# A static archive exposes every global symbol of PDFium's bundled
# dependencies (abseil, ICU, libjpeg, freetype, ...), which can collide with
# the consumer's own copies. Merge the archive into one relocatable object and
# keep global only the public API.
hide_internal_symbols() {
  local lib="$1"
  local tools="$SOURCE/third_party/llvm-build/Release+Asserts/bin"
  local work="$BUILD/hide_internal_symbols"
  rm -rf "$work"
  mkdir -p "$work"

  # One command per file, so a failing tool stops the step with its own error.
  # Every function in PDFium's public headers is named FPDF*, FORM_* or FSDK_*.
  "$tools/llvm-nm" --defined-only --extern-only --format=just-symbols "$lib" >"$work/defined.txt"
  grep -E '^(FPDF|FORM_|FSDK_)' "$work/defined.txt" | sort -u >"$work/public.txt"
  if ! grep -qx FPDF_InitLibrary "$work/public.txt"; then
    echo "ERROR: no public symbols found in $lib (FPDF_InitLibrary missing)" >&2
    exit 1
  fi

  # One merged object defeats the consumer's per-member archive extraction,
  # so drop here what no public function reaches.
  sed 's/^/--undefined=/' "$work/public.txt" >"$work/roots.rsp"
  "$tools/ld.lld" -r --gc-sections "@$work/roots.rsp" --whole-archive "$lib" -o "$work/pdfium.o"
  "$tools/llvm-objcopy" --keep-global-symbols="$work/public.txt" "$work/pdfium.o"

  "$tools/llvm-nm" --defined-only --extern-only --format=just-symbols "$work/pdfium.o" >"$work/exported_unsorted.txt"
  sort -u "$work/exported_unsorted.txt" >"$work/exported.txt"
  if ! diff -u "$work/public.txt" "$work/exported.txt" >&2; then
    echo "ERROR: the globals of the merged $lib differ from the public API" >&2
    exit 1
  fi
  "$tools/llvm-readelf" --section-headers "$work/pdfium.o" >"$work/sections.txt"
  if grep -q '\.crel\.' "$work/sections.txt"; then
    echo "ERROR: $lib contains CREL sections, which GNU ld cannot read" >&2
    exit 1
  fi
  "$tools/llvm-nm" --undefined-only "$work/pdfium.o" >"$work/undefined.txt"
  if grep -E '__arm_(get_current_vg|tpidr2_|sme_)' "$work/undefined.txt" >&2; then
    echo "ERROR: $lib needs SME runtime helpers; check libyuv_use_sme in 05-configure.sh" >&2
    exit 1
  fi

  rm "$lib"
  "$tools/llvm-ar" rcs "$lib" "$work/pdfium.o"
  rm -rf "$work"
}

case "$OS-$BUILD_TYPE" in
  android-shared|linux-shared)
    mv "$BUILD/libpdfium.so" "$STAGING_LIB"
    ;;

  android-static|linux-static|mac-static|ios-static)
    mv "$BUILD/obj/libpdfium.a" "$STAGING_LIB"
    # MIPS GOT offsets are 16 bits per input object: GNU ld splits the GOT
    # across archive members, but one merged object overflows it.
    case "$OS-$TARGET_CPU" in
      linux-mipsel|linux-mips64el) ;;
      linux-*) hide_internal_symbols "$STAGING_LIB/libpdfium.a" ;;
    esac
    ;;

  mac-shared|ios-shared)
    mv "$BUILD/libpdfium.dylib" "$STAGING_LIB"
    ;;

  emscripten-*)
    mv "$BUILD/pdfium.html" "$STAGING_LIB"
    mv "$BUILD/pdfium.js" "$STAGING_LIB"
    mv "$BUILD/pdfium.wasm" "$STAGING_LIB"
    rm -rf "$STAGING/include/cpp"
    rm "$STAGING/PDFiumConfig.cmake"
    ;;

  win-shared)
    mv "$BUILD/pdfium.dll.lib" "$STAGING_LIB"
    mkdir -p "$STAGING_BIN"
    mv "$BUILD/pdfium.dll" "$STAGING_BIN"
    [ "$IS_DEBUG" == "true" ] && mv "$BUILD/pdfium.dll.pdb" "$STAGING_BIN"
    ;;

  win-shared)
    mv "$BUILD/obj/pdfium.lib" "$STAGING_LIB"
    ;;
esac

# The App Store rejects standalone dylibs in iOS apps, they must be embedded as frameworks
if [ "$OS-$BUILD_TYPE" == "ios-shared" ]; then
  FRAMEWORK="$STAGING_LIB/pdfium.framework"
  FRAMEWORK_CONTENTS="$FRAMEWORK"
  RESOURCES="$FRAMEWORK"
  case "$TARGET_ENVIRONMENT" in
    catalyst)
      PLATFORM="MacOSX"
      FRAMEWORK_CONTENTS="$FRAMEWORK/Versions/A"
      RESOURCES="$FRAMEWORK_CONTENTS/Resources"
      mkdir -p "$FRAMEWORK_CONTENTS"
      ln -s A "$FRAMEWORK/Versions/Current"
      ln -s Versions/Current/pdfium "$FRAMEWORK/pdfium"
      ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
      ;;
    simulator)
      PLATFORM="iPhoneSimulator"
      ;;
    *)
      PLATFORM="iPhoneOS"
      ;;
  esac

  mkdir -p "$RESOURCES"
  cp "$STAGING_LIB/libpdfium.dylib" "$FRAMEWORK_CONTENTS/pdfium"
  install_name_tool -id @rpath/pdfium.framework/pdfium "$FRAMEWORK_CONTENTS/pdfium"

  # The App Store requires MinimumOSVersion to match the binary (ITMS-90208)
  MINIMUM_OS_VERSION=$(xcrun vtool -show-build "$FRAMEWORK/pdfium" | awk '$1 == "minos" { print $2; exit }')
  MINIMUM_OS_VERSION_KEY="MinimumOSVersion"
  if [ "$TARGET_ENVIRONMENT" == "catalyst" ]; then
    MINIMUM_OS_VERSION_KEY="LSMinimumSystemVersion"
    SDK_SETTINGS="$(xcrun --sdk macosx --show-sdk-path)/SDKSettings.plist"
    MINIMUM_OS_VERSION=$(/usr/libexec/PlistBuddy -c "Print :VersionMap:iOSMac_macOS:$MINIMUM_OS_VERSION" "$SDK_SETTINGS")
  fi
  BUNDLE_VERSION=$(echo "${VERSION:-0.0.0}" | cut -d. -f1-3)

  export PLATFORM MINIMUM_OS_VERSION MINIMUM_OS_VERSION_KEY BUNDLE_VERSION
  envsubst < "$PATCHES/ios/Info.plist" > "$RESOURCES/Info.plist"

  if [ "$TARGET_ENVIRONMENT" == "catalyst" ]; then
    # NuGet and GitHub artifacts do not preserve the symlinks in versioned frameworks.
    # The .NET SDK automatically extracts .framework.zip files before embedding them.
    (cd "$STAGING_LIB" && zip -qry --symlinks pdfium.framework.zip pdfium.framework)
    rm -rf "$FRAMEWORK"
  fi
fi

if [ -n "$VERSION" ]; then
  cat >"$STAGING/VERSION" <<END
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
BUILD=$(echo "$VERSION" | cut -d. -f3)
PATCH=$(echo "$VERSION" | cut -d. -f4)
END
fi
