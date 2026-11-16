//! The venomx version, shared by `--version`, the doctor header, the fangs
//! caption, XTVERSION and the wire hello. Set at build time with
//! `-Dversion=<semver>`; builds without it report a `-dev` version.

pub const version: []const u8 = @import("build_options").version;
