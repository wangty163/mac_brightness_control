# Bundled DDC command tool

Source: https://github.com/waydabber/m1ddc
Pinned upstream commit: `04d949794102eb8df01ad3681afff6464a3eede2`.
License: MIT, retained in LICENSE and copied into the application bundle.

This source builds as `BrightnessControlDDC`. Packaged Apple Silicon builds
prefer this sibling executable over a system-installed m1ddc. Intel builds
continue to use the existing external backends. Development with `swift run`
without an app bundle continues to use system-installed tools.

Local changes:

- Initialize display records and reject missing/wrongly typed metadata before
  calling CoreFoundation/IOKit. Exclude built-in and known unkn/virt displays,
  but retain unavailable external slots so later displays do not shift indices.
- Bound numeric display selection, handle iterator failures, and release the
  registry root and temporary property keys.
- Send a DPMS write once. The upstream repeated write can fail after the first
  write successfully removes the display's control service.
- Use protocol packet length, including zero checksum bytes. Validate VCP
  replies, checksums, and requested feature before reporting a value; empty
  replies must not appear as brightness/power 0. Decode 16-bit fields directly.
- Reject incomplete arguments and explain unavailable control channels.

The source retains upstream manual Objective-C reference counting. The tool
is short-lived; upstream display-info objects are retained until process exit.

Run `scripts/test_ddc.sh` for hardware-free regression tests. The fixture
replaces enumeration and write entry points, exercising production code without
turning a screen off. Actual wake support still depends on the monitor retaining
its DDC channel while powered off; the application cannot guarantee remote wake.
