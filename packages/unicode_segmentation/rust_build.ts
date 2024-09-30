import {$} from "bun";
await $`rustup component add rustfmt`;
await $`cargo fmt`;

const targets: {zig: string, rs: string, rsn: string}[] = [
    {zig: "aarch64-macos", rs: "aarch64-apple-darwin", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "x86_64-macos", rs: "x86_64-apple-darwin", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "aarch64-windows-msvc", rs: "aarch64-pc-windows-msvc", rsn: "unicode_segmentation_bindings.lib"},
    {zig: "x86_64-windows-gnu", rs: "x86_64-pc-windows-gnu", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "x86_64-windows-msvc", rs: "x86_64-pc-windows-msvc", rsn: "unicode_segmentation_bindings.lib"},
    {zig: "aarch64-linux-musl", rs: "aarch64-unknown-linux-musl", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "aarch64-linux-gnu", rs: "aarch64-unknown-linux-gnu", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "aarch64-linux-musl", rs: "aarch64-unknown-linux-musl", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "x86_64-linux-gnu", rs: "x86_64-unknown-linux-gnu", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "x86_64-linux-musl", rs: "x86_64-unknown-linux-musl", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "riscv32-unknown-none-elf", rs: "riscv32imac-unknown-none-elf", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "wasm32-freestanding", rs: "wasm32-unknown-unknown", rsn: "libunicode_segmentation_bindings.a"},

    {zig: "arm-linux-android", rs: "armv7-linux-androideabi", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "aarch64-linux-android", rs: "aarch64-linux-android", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "x86-linux-android", rs: "i686-linux-android", rsn: "libunicode_segmentation_bindings.a"},
    {zig: "x86_64-linux-android", rs: "x86_64-linux-android", rsn: "libunicode_segmentation_bindings.a"},
];
for(const {zig, rs, rsn} of targets) {
    await $`rustup target add ${rs}`;
    await $`cargo build --profile release_safe --target ${rs}`;
    await $`mkdir -p bin/${zig}`;
    await $`cp target/${rs}/release_safe/${rsn} bin/${zig}/${rsn}`;
}
