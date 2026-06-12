//! SporeVM library root.
//!
//! A spore is a sealed, content-addressed checkpoint of a VM: a manifest of
//! memory and disk chunks plus a small normalized machine-state blob. This
//! module exposes the building blocks; the `spore` CLI in `main.zig` is a
//! thin shell over them.

pub const chunk = @import("chunk.zig");

pub const version = "0.0.0";

test {
    // Ensure all referenced modules' tests are discovered.
    @import("std").testing.refAllDecls(@This());
}
