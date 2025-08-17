//! 'Magic' numbers for codegen sizing
//!
//! These need to be updated for each Unicode version.

// Whether to print the magic numbers
pub const print = false;

// Don't want to crash while printing magic...
const fudge = if (print) 1000 else 0;

// Number of codepoints in CanonData.zig
pub const canon_size: usize = 3127 + fudge;

// Number of codepoitns in CompatData.zig
pub const compat_size: usize = 5612 + fudge;
