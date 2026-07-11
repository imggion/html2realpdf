//! Stacking-context boundary for the Web CSS profile.
//!
//! The document profile paints fragments in stable document order. z-index,
//! opacity groups, transforms, and nested stacking contexts remain unsupported.

pub const supports_stacking_contexts = false;
