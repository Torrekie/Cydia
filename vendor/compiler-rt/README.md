# iOS compiler-rt builtins

`libclang_rt.ios.a` is an Apple-distributed prebuilt compiler-rt archive.
The upstream source revision is not inferred from the archive version.

SHA-256: `71d9ab1c05a7abaa241e407b21df52f50c91d11728e82ae0cebe0945ac40f3a5`.

The universal archive contains armv7, armv7s, arm64 and arm64e slices. Cydia's
arm64 link selects the arm64 slice; its objects declare iOS 6.0 as the minimum
OS version. The availability object exports `__isOSVersionAtLeast` and
`__isPlatformVersionAtLeast`, and depends only on libSystem entry points.

Only Linux cross-builds explicitly link this archive. It supplies the runtime
for `@available` omitted by the pinned cross compiler. The linker selects
needed archive members normally. Native Apple builds use their own compiler
runtime. The CI runner, compiler archive and iPhoneOS SDK pins are unchanged.

The compiler-rt [license](https://github.com/llvm/llvm-project/blob/llvmorg-14.0.3/compiler-rt/LICENSE.TXT),
including the legacy University of Illinois/NCSA and MIT notices, is retained
as `LICENSE.TXT` and installed with Cydia's third-party notices.
